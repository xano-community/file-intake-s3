// POST /files/{file_id}/send-to-review — move a validated file into the approval queue. Creates a
// file_reviews row (review_status = pending) and sets status `needs_review`. Allowed only from
// status `validated`.
query "files/{file_id}/send-to-review" verb=POST {
  api_group = "S3FileIntake"
  description = "Send a validated file to review: status -> `needs_review`, plus a pending file_reviews row. Allowed only from `validated`. Requires the API secret."

  input {
    int file_id? { description = "The file to send to review" }
    text uploaded_by? { description = "Identity of the caller, for the audit trail" }
    text api_secret? { description = "Shared API secret (or send X-API-Secret header)" }
    text request_id? { description = "Optional client correlation id for the request log" }
  }

  stack {
    var $endpoint { value = "POST /files/{file_id}/send-to-review" }
    var $hdr_secret { value = "" }
    conditional {
      if (($env.$http_headers != null) && ($env.$http_headers|has:"x-api-secret")) {
        var.update $hdr_secret { value = (($env.$http_headers|get:"x-api-secret") ?? "") }
      }
    }
    var $secret { value = (($input.api_secret ?? "") || $hdr_secret) }

    // 1. Auth.
    function.run "s3_file_intake_check_auth" {
      input = {provided_secret: $secret}
    } as $auth_res
    conditional {
      if ($auth_res.ok == false) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "unauthorized", requester_id: $input.uploaded_by, error_message: $auth_res.error, request_id: $input.request_id}
        } as $log_unauth
      }
    }
    precondition ($auth_res.ok == true) {
      error_type = "accessdenied"
      error = $auth_res.error
    }

    // 2. Load the file.
    db.get "files" {
      field_name = "id"
      field_value = ($input.file_id ?? 0)
    } as $file
    conditional {
      if ($file == null) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "not_found", requester_id: $input.uploaded_by, error_message: ("No file with id " ~ (($input.file_id ?? 0)|to_text)), request_id: $input.request_id}
        } as $log_nf
      }
    }
    precondition ($file != null) {
      error_type = "notfound"
      error = ("No file with id " ~ (($input.file_id ?? 0)|to_text))
    }

    // 3. State guard: send_to_review only from `validated`.
    function.run "s3_file_intake_check_transition" {
      input = {current_status: $file.status, action: "send_to_review"}
    } as $guard
    conditional {
      if ($guard.allowed == false) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "conflict", requester_id: $input.uploaded_by, error_message: $guard.error, request_id: $input.request_id}
        } as $log_guard
      }
    }
    precondition ($guard.allowed == true) {
      error_type = "inputerror"
      error = $guard.error
    }

    // 4. Status -> needs_review + a pending review record.
    db.edit "files" {
      field_name = "id"
      field_value = $file.id
      data = {status: "needs_review", updated_at: now}
    } as $updated

    db.add "file_reviews" {
      data = {file_id: $file.id, review_status: "pending"}
    } as $review

    // 5. Audit event.
    function.run "s3_file_intake_record_event" {
      input = {file_id: $file.id, event_type: "file_sent_to_review", created_by: $input.uploaded_by, event_payload: {review_id: $review.id, new_status: "needs_review"}}
    } as $evt

    // 6. Request log.
    function.run "s3_file_intake_log_request" {
      input = {endpoint: $endpoint, status: "ok", requester_id: $input.uploaded_by, request_id: $input.request_id}
    } as $log_ok
  }

  response = {file: $updated, status: "needs_review", review: $review}
  guid = "Ue35we2JkmGYqFVG9TlTiK7By9w"
}
