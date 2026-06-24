// GET /files/{file_id}/status — the read model for a file: its metadata, current status, the latest
// review status, the canonical S3 URL, and the full ordered event history. Auth-gated and logged.
query "files/{file_id}/status" verb=GET {
  api_group = "S3FileIntake"
  description = "Return a file's metadata, current status, latest review status, S3 URL, and full event history. Requires the API secret (api_secret query param or X-API-Secret header)."

  input {
    int file_id? { description = "The file to read" }
    text api_secret? { description = "Shared API secret (or send X-API-Secret header)" }
    text request_id? { description = "Optional client correlation id for the request log" }
  }

  stack {
    var $endpoint { value = "GET /files/{file_id}/status" }
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
          input = {endpoint: $endpoint, status: "unauthorized", error_message: $auth_res.error, request_id: $input.request_id}
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
          input = {endpoint: $endpoint, status: "not_found", error_message: ("No file with id " ~ (($input.file_id ?? 0)|to_text)), request_id: $input.request_id}
        } as $log_nf
      }
    }
    precondition ($file != null) {
      error_type = "notfound"
      error = ("No file with id " ~ (($input.file_id ?? 0)|to_text))
    }

    // 3. Latest review (if any).
    db.query "file_reviews" {
      where = $db.file_reviews.file_id == $file.id
      sort = {created_at: "desc"}
      return = {type: "single"}
    } as $latest_review

    // 4. Full event history, oldest first.
    db.query "file_events" {
      where = $db.file_events.file_id == $file.id
      sort = {created_at: "asc"}
      return = {type: "list"}
    } as $events

    // 5. Canonical S3 URL.
    function.run "s3_file_intake_s3_object_url" {
      input = {s3_key: $file.s3_key}
    } as $loc

    // 6. Request log (success).
    function.run "s3_file_intake_log_request" {
      input = {endpoint: $endpoint, status: "ok", request_id: $input.request_id}
    } as $log_ok

    var $review_status { value = null }
    conditional {
      if ($latest_review != null) {
        var.update $review_status { value = $latest_review.review_status }
      }
    }
  }

  response = {
    file: $file,
    status: $file.status,
    review_status: $review_status,
    latest_review: $latest_review,
    s3_url: $loc.url,
    events: $events
  }
  guid = "FZLnM_MXB6Kbh4DkV47H_6CUJmQ"
}
