// POST /files/{file_id}/mark-processed — mark an approved file as fully processed by downstream
// systems. Status -> `processed`. Allowed only from status `approved`.
query "files/{file_id}/mark-processed" verb=POST {
  api_group = "S3FileIntake"
  description = "Mark an approved file as processed: status -> `processed`. Allowed only from `approved`. Requires the API secret."

  input {
    int file_id? { description = "The file to mark processed" }
    text uploaded_by? { description = "Identity of the caller, for the audit trail" }
    text api_secret? { description = "Shared API secret (or send X-API-Secret header)" }
    text request_id? { description = "Optional client correlation id for the request log" }
  }

  stack {
    var $endpoint { value = "POST /files/{file_id}/mark-processed" }
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

    // 3. State guard: mark_processed only from `approved`.
    function.run "s3_file_intake_check_transition" {
      input = {current_status: $file.status, action: "mark_processed"}
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

    // 4. Status -> processed.
    db.edit "files" {
      field_name = "id"
      field_value = $file.id
      data = {status: "processed", updated_at: now}
    } as $updated

    // 5. Audit event.
    function.run "s3_file_intake_record_event" {
      input = {file_id: $file.id, event_type: "file_processed", created_by: $input.uploaded_by, event_payload: {new_status: "processed"}}
    } as $evt

    // 6. Request log.
    function.run "s3_file_intake_log_request" {
      input = {endpoint: $endpoint, status: "ok", requester_id: $input.uploaded_by, request_id: $input.request_id}
    } as $log_ok
  }

  response = {file: $updated, status: "processed"}
  guid = "rsV8euMMTfmFTMJoiDmrErnsGbI"
}
