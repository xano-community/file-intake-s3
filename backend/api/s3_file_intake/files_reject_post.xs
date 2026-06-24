// POST /files/{file_id}/reject — reject a file that is in review. File status -> `rejected`, the
// pending review -> `rejected`. Allowed only from status `needs_review`. Requires reviewer_id and a
// non-empty review_note.
query "files/{file_id}/reject" verb=POST {
  api_group = "S3FileIntake"
  description = "Reject a file in review. Body: reviewer_id, review_note (must not be empty). File status -> `rejected`, review_status -> `rejected`. Allowed only from `needs_review`. Requires the API secret."

  input {
    int file_id? { description = "The file to reject" }
    text reviewer_id? { description = "Identity of the reviewer (required)" }
    text review_note? { description = "Reason for rejection (required, non-empty)" }
    text api_secret? { description = "Shared API secret (or send X-API-Secret header)" }
    text request_id? { description = "Optional client correlation id for the request log" }
  }

  stack {
    var $endpoint { value = "POST /files/{file_id}/reject" }
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

    // 2. Required review fields — review_note must be present and non-empty.
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

    // 4. State guard: reject only from `needs_review`.
    function.run "s3_file_intake_check_transition" {
      input = {current_status: $file.status, action: "reject"}
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

    // 5. File -> rejected; the pending review -> rejected.
    db.edit "files" {
      field_name = "id"
      field_value = $file.id
      data = {status: "rejected", updated_at: now}
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
          data = {review_status: "rejected", reviewer_id: $input.reviewer_id, review_note: $input.review_note}
        } as $review_done
      }
    }

    // 6. Audit event.
    function.run "s3_file_intake_record_event" {
      input = {file_id: $file.id, event_type: "file_rejected", created_by: $input.reviewer_id, event_payload: {reviewer_id: $input.reviewer_id, review_note: $input.review_note, new_status: "rejected"}}
    } as $evt

    // 7. Request log.
    function.run "s3_file_intake_log_request" {
      input = {endpoint: $endpoint, status: "ok", requester_id: $input.reviewer_id, request_id: $input.request_id}
    } as $log_ok
  }

  response = {file: $updated, status: "rejected", review_status: "rejected"}
  guid = "A5dLc2IgmAbnNsoEjY3ZPqbDYaI"
}
