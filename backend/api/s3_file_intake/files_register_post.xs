// POST /files/register — the S3 upload handoff point. The client uploads the bytes to S3 itself,
// then registers the object's metadata here. Creates a `files` row (status `registered`) and a
// `file_registered` event. Auth-gated and fully logged.
query "files/register" verb=POST {
  api_group = "S3FileIntake"
  description = "Register a file already uploaded to S3. Body: s3_key, file_name, file_type, file_size_bytes, uploaded_by. Creates a files row in status `registered` and a file_registered event. Requires the API secret."

  // Inputs are optional at the platform layer so blank/invalid values reach the stack and produce a
  // governed error + an api_request_logs row (rather than a pre-stack platform rejection).
  input {
    text s3_key? { description = "Object key in the S3 bucket (unique)" }
    text file_name? { description = "Original file name" }
    text file_type? { description = "File type / extension: pdf, csv, xlsx, json" }
    int file_size_bytes? { description = "File size in bytes" }
    text uploaded_by? { description = "Identity of the uploader" }
    text api_secret? { description = "Shared API secret (or send X-API-Secret header)" }
    text request_id? { description = "Optional client correlation id for the request log" }
  }

  stack {
    var $endpoint { value = "POST /files/register" }
    var $hdr_secret { value = "" }
    conditional {
      if (($env.$http_headers != null) && ($env.$http_headers|has:"x-api-secret")) {
        var.update $hdr_secret { value = (($env.$http_headers|get:"x-api-secret") ?? "") }
      }
    }
    var $secret { value = (($input.api_secret ?? "") || $hdr_secret) }

    // 1. Auth gate (no-op when API_AUTH_SECRET is unset; enforced when set).
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

    // 2. Validate required fields are present (optional at the platform layer, required by the contract).
    var $missing { value = [] }
    conditional {
      if ((($input.s3_key ?? "")|trim|strlen) == 0) {
        var.update $missing { value = ($missing|push:"s3_key") }
      }
    }
    conditional {
      if ((($input.file_name ?? "")|trim|strlen) == 0) {
        var.update $missing { value = ($missing|push:"file_name") }
      }
    }
    conditional {
      if ((($input.file_type ?? "")|trim|strlen) == 0) {
        var.update $missing { value = ($missing|push:"file_type") }
      }
    }
    conditional {
      if (($input.file_size_bytes ?? 0) <= 0) {
        var.update $missing { value = ($missing|push:"file_size_bytes") }
      }
    }

    conditional {
      if (($missing|count) > 0) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "invalid", requester_id: $input.uploaded_by, error_message: ("Missing required field(s): " ~ ($missing|join:", ")), request_id: $input.request_id}
        } as $log_missing
      }
    }
    precondition (($missing|count) == 0) {
      error_type = "inputerror"
      error = ("Missing required field(s): " ~ ($missing|join:", "))
    }

    // 3. Reject a duplicate s3_key (the unique index would otherwise hard-fail).
    db.has "files" {
      field_name = "s3_key"
      field_value = (($input.s3_key)|trim)
    } as $dup
    conditional {
      if ($dup == true) {
        function.run "s3_file_intake_log_request" {
          input = {endpoint: $endpoint, status: "conflict", requester_id: $input.uploaded_by, error_message: "A file with this s3_key is already registered.", request_id: $input.request_id}
        } as $log_dup
      }
    }
    precondition ($dup == false) {
      error_type = "inputerror"
      error = "A file with this s3_key is already registered."
    }

    // 4. Create the file row in `registered`.
    db.add "files" {
      data = {
        s3_key: (($input.s3_key)|trim),
        file_name: $input.file_name,
        file_type: (($input.file_type)|trim|to_lower),
        file_size_bytes: $input.file_size_bytes,
        uploaded_by: $input.uploaded_by,
        status: "registered"
      }
    } as $file

    // 5. Audit event.
    function.run "s3_file_intake_record_event" {
      input = {file_id: $file.id, event_type: "file_registered", created_by: $input.uploaded_by, event_payload: {s3_key: $file.s3_key, file_type: $file.file_type, file_size_bytes: $file.file_size_bytes}}
    } as $evt

    // 6. Canonical S3 URL for convenience (null if bucket/region env unset).
    function.run "s3_file_intake_s3_object_url" {
      input = {s3_key: $file.s3_key}
    } as $loc

    // 7. Request log (success).
    function.run "s3_file_intake_log_request" {
      input = {endpoint: $endpoint, status: "ok", requester_id: $input.uploaded_by, request_id: $input.request_id}
    } as $log_ok
  }

  response = {file: $file, s3_url: $loc.url, status: $file.status}
  guid = "TS8Hk-Y-GDlzoGokVnSOBc_p2cs"
}
