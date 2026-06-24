// POST /files/{file_id}/validate — validate a registered file's declared type + size against the
// intake policy. Valid -> status `validated`; invalid -> status `failed`. When AWS credentials are
// configured, also confirms the object exists in S3 (native cloud.aws.s3.get_file_info). Allowed
// only from status `registered`.
query "files/{file_id}/validate" verb=POST {
  api_group = "S3FileIntake"
  description = "Validate a file's type (pdf|csv|xlsx|json) and size (<= 25 MB). Pass -> `validated`, fail -> `failed`. If AWS creds are set, also verifies the S3 object exists. Allowed only from `registered`. Requires the API secret."

  input {
    int file_id? { description = "The file to validate" }
    text uploaded_by? { description = "Identity of the caller, for the audit trail" }
    text api_secret? { description = "Shared API secret (or send X-API-Secret header)" }
    text request_id? { description = "Optional client correlation id for the request log" }
  }

  stack {
    var $endpoint { value = "POST /files/{file_id}/validate" }
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

    // 2. Load the file (404 if it doesn't exist).
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

    // 3. State guard: validate only from `registered`.
    function.run "s3_file_intake_check_transition" {
      input = {current_status: $file.status, action: "validate"}
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

    // 4. Policy validation of declared metadata.
    function.run "s3_file_intake_validate_metadata" {
      input = {file_type: $file.file_type, file_size_bytes: $file.file_size_bytes}
    } as $check

    // 5. Optional S3 existence check (genuinely uses the AWS creds when configured; skipped otherwise).
    function.run "s3_file_intake_s3_head" {
      input = {s3_key: $file.s3_key}
    } as $head

    // The object check only downgrades a metadata-valid file: if creds are configured and the object
    // is genuinely absent, the file fails. When creds are unset, $head.checked is false and is ignored.
    var $valid { value = $check.valid }
    var $reason { value = $check.reason }
    conditional {
      if (($valid == true) && ($head.checked == true) && ($head.exists == false)) {
        var.update $valid { value = false }
        var.update $reason { value = ("Metadata is valid but the S3 object was not found: " ~ $head.error) }
      }
    }

    // 6. Transition to `validated` or `failed`.
    var $new_status { value = "failed" }
    conditional {
      if ($valid == true) {
        var.update $new_status { value = "validated" }
      }
    }
    db.edit "files" {
      field_name = "id"
      field_value = $file.id
      data = {status: $new_status, updated_at: now}
    } as $updated

    // 7. Audit event records the outcome and the reason on failure.
    var $evt_type { value = "file_failed_validation" }
    conditional {
      if ($valid == true) {
        var.update $evt_type { value = "file_validated" }
      }
    }
    function.run "s3_file_intake_record_event" {
      input = {file_id: $file.id, event_type: $evt_type, created_by: $input.uploaded_by, event_payload: {valid: $valid, reason: $reason, s3_object_checked: $head.checked, s3_object_exists: $head.exists, new_status: $new_status}}
    } as $evt

    // 8. Request log.
    function.run "s3_file_intake_log_request" {
      input = {endpoint: $endpoint, status: "ok", requester_id: $input.uploaded_by, request_id: $input.request_id}
    } as $log_ok
  }

  response = {file: $updated, status: $new_status, valid: $valid, reason: $reason, s3_object_checked: $head.checked, s3_object_exists: $head.exists}
  guid = "7L-g3Sha2e1N7gONkWJt4TYMp0o"
}
