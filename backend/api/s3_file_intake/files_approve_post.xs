// POST /files/{file_id}/approve — approve a file that is in review. File status -> `approved`, the
// pending review -> `approved`. Allowed only from status `needs_review`. Requires reviewer_id and
// review_note.
query "files/{file_id}/approve" verb=POST {
  api_group = "S3FileIntake"
  description = "Approve a file in review. Body: reviewer_id, review_note. File status -> `approved`, review_status -> `approved`. Allowed only from `needs_review`. Requires the API secret."

  input {
    int file_id? { description = "The file to approve" }
    text reviewer_id? { description = "Identity of the reviewer (required)" }
    text review_note? { description = "Reviewer's note (required)" }
    text api_secret? { description = "Shared API secret (or send X-API-Secret header)" }
    text request_id? { description = "Optional client correlation id for the request log" }
  }

  stack {
    var $endpoint { value = "POST /files/{file_id}/approve" }
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
          input = {endpoint: $endpoint, status: "unauthorized", requester_id: $input.reviewer_id, error_message: $auth_res.error, request_id: $input.request_id}
        } as $log_unauth
      }
    }
    precondition ($auth_res.ok == true) {
      error_type = "accessdenied"
      error = $auth_res.error
    }

    // 2. Required review fields.
    var $missing { value = [] }
    conditional {
      if ((($input.reviewer_id ?? "")|trim|strlen) == 0) {
        var.update $missing { value = ($missing|push:"reviewer_id") }
      }
    }
    conditional {
      if ((($input.review_note ?? "")|trim|strlen) == 0) {
        var.update $missing { value = ($missing|push:"review_note") }
      }
    }
    conditional {
      if (($missing|count) > 0) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "invalid", requester_id: $input.reviewer_id, error_message: ("Missing required field(s): " ~ ($missing|join:", ")), request_id: $input.request_id}
        } as $log_missing
      }
    }
    precondition (($missing|count) == 0) {
      error_type = "inputerror"
      error = ("Missing required field(s): " ~ ($missing|join:", "))
    }

    // 3. Load the file.
    db.get "files" {
      field_name = "id"
      field_value = ($input.file_id ?? 0)
    } as $file
    conditional {
      if ($file == null) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "not_found", requester_id: $input.reviewer_id, error_message: ("No file with id " ~ (($input.file_id ?? 0)|to_text)), request_id: $input.request_id}
        } as $log_nf
      }
    }
    precondition ($file != null) {
      error_type = "notfound"
      error = ("No file with id " ~ (($input.file_id ?? 0)|to_text))
    }

    // 4. State guard: approve only from `needs_review`.
    function.run "s3_file_intake_check_transition" {
      input = {current_status: $file.status, action: "approve"}
    } as $guard
    conditional {
      if ($guard.allowed == false) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "conflict", requester_id: $input.reviewer_id, error_message: $guard.error, request_id: $input.request_id}
        } as $log_guard
      }
    }
    precondition ($guard.allowed == true) {
      error_type = "inputerror"
      error = $guard.error
    }

    // 5. File -> approved; the pending review -> approved (carry reviewer + note).
    db.edit "files" {
      field_name = "id"
      field_value = $file.id
      data = {status: "approved", updated_at: now}
    } as $updated

    db.query "file_reviews" {
      where = $db.file_reviews.file_id == $file.id && $db.file_reviews.review_status == "pending"
      sort = {created_at: "desc"}
      return = {type: "single"}
    } as $pending_review
    conditional {
      if ($pending_review != null) {
        db.edit "file_reviews" {
          field_name = "id"
          field_value = $pending_review.id
          data = {review_status: "approved", reviewer_id: $input.reviewer_id, review_note: $input.review_note}
        } as $review_done
      }
    }

    // 6. Audit event.
    function.run "s3_file_intake_record_event" {
      input = {file_id: $file.id, event_type: "file_approved", created_by: $input.reviewer_id, event_payload: {reviewer_id: $input.reviewer_id, review_note: $input.review_note, new_status: "approved"}}
    } as $evt

    // 7. Request log.
    function.run "s3_file_intake_log_request" {
      input = {endpoint: $endpoint, status: "ok", requester_id: $input.reviewer_id, request_id: $input.request_id}
    } as $log_ok
  }

  response = {file: $updated, status: "approved", review_status: "approved"}
  guid = "YPPgYEf-pQvksxCeiyvNO4vb4Nk"
}
