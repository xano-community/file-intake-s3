workspace templates {
  acceptance = {ai_terms: false}
  preferences = {
    internal_docs    : false
    track_performance: true
    sql_names        : false
    sql_columns      : true
  }
}
---
table "api_request_logs" {
  auth = false
  description = "Audit row for every API call into the module — one per request, recording the endpoint, requester, outcome status, and any error message."

  schema {
    int id
    text request_id filters=trim
    text endpoint filters=trim
    text requester_id? filters=trim
    text status filters=trim
    text error_message? filters=trim
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "endpoint"}]}
    {type: "btree", field: [{name: "request_id"}]}
  ]
  guid = "QUhuaPJNUKWMsWYwoYlNftF3hOk"
}
---
table "file_events" {
  auth = false
  description = "Append-only audit trail. Every status change and lifecycle action writes one row here, giving each file a full, ordered event history."

  schema {
    int id
    int file_id { table = "files" }
    text event_type filters=trim
    json event_payload?
    text created_by? filters=trim
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "file_id"}]}
    {type: "btree", field: [{name: "event_type"}]}
  ]
  guid = "ofLNFGHF0JprZRPcAVISR8QwN5U"
}
---
table "file_reviews" {
  auth = false
  description = "One review record per file once it enters the approval flow. review_status moves pending -> approved | rejected alongside the file's status."

  schema {
    int id
    int file_id { table = "files" }
    text review_status?="pending" filters=trim
    text reviewer_id? filters=trim
    text review_note? filters=trim
    timestamp created_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree", field: [{name: "file_id"}]}
    {type: "btree", field: [{name: "review_status"}]}
  ]
  guid = "X38z4BCzcm477_fPxd8eHNRF93s"
}
---
table "files" {
  auth = false
  description = "One row per file handed off from S3. Xano owns the metadata + workflow status; the bytes live in S3 under s3_key."

  schema {
    int id
    text s3_key filters=trim
    text file_name filters=trim
    text file_type filters=trim|lower
    int file_size_bytes
    text uploaded_by? filters=trim
    text status?="registered" filters=trim
    timestamp created_at?=now
    timestamp updated_at?=now
  }

  index = [
    {type: "primary", field: [{name: "id"}]}
    {type: "btree|unique", field: [{name: "s3_key"}]}
    {type: "btree", field: [{name: "status"}]}
  ]
  guid = "HKvwbVJo6fsmisRWhFykGazPqIM"
}
---
function "s3_file_intake_check_auth" {
  description = "Gate every endpoint on the shared API_AUTH_SECRET. When $env.API_AUTH_SECRET is set, the caller-supplied secret must match it exactly (constant comparison) or the request is denied. When API_AUTH_SECRET is unset/empty (e.g. an un-provisioned workspace), the gate is a no-op so the module still runs — production deployments MUST set it. Returns {ok, error} and never throws."

  input {
    text provided_secret? { description = "Secret supplied by the caller (X-API-Secret header or api_secret body field)" }
  }

  stack {
    // Reading the env here keeps the secret out of inputs; mocked in unit tests to cover both branches.
    var $configured {
      value = ($env.API_AUTH_SECRET ?? "")
      mock = {
        "denies when secret is configured and the request omits it": "s3cr3t-prod-value",
        "denies when secret is configured and the request sends the wrong value": "s3cr3t-prod-value",
        "allows when secret is configured and the request matches": "s3cr3t-prod-value"
      }
    }
    var $provided { value = ($input.provided_secret ?? "") }

    var $ok { value = true }
    var $err { value = "" }

    conditional {
      if (($configured|strlen) > 0) {
        conditional {
          if ($provided == $configured) {
            var.update $ok { value = true }
          }
          else {
            var.update $ok { value = false }
            var.update $err { value = "Unauthorized: missing or invalid API secret." }
          }
        }
      }
    }
  }

  response = {ok: $ok, error: $err, enforced: (($configured|strlen) > 0)}

  test "allows when no secret is configured (no-op gate)" {
    input = {provided_secret: ""}
    expect.to_be_true ($response.ok)
  }

  test "no-op gate reports enforced=false when unconfigured" {
    input = {provided_secret: "anything"}
    expect.to_be_false ($response.enforced)
  }

  test "allows when secret is configured and the request matches" {
    input = {provided_secret: "s3cr3t-prod-value"}
    expect.to_be_true ($response.ok)
  }

  test "denies when secret is configured and the request omits it" {
    input = {provided_secret: ""}
    expect.to_be_false ($response.ok)
  }

  test "denies when secret is configured and the request sends the wrong value" {
    input = {provided_secret: "guess"}
    expect.to_be_false ($response.ok)
  }
  guid = "ZG5p4rEXPbfL67ajao7IzEpaBlA"
}
---
function "s3_file_intake_check_transition" {
  description = "Pure state-machine guard. Given a file's current status and a requested action, returns {allowed, error} describing whether the transition is legal. Never throws — callers branch on `allowed` and surface `error` to the client + the api_request_logs row. Rules: validate only from `registered`; send_to_review only from `validated`; approve/reject only from `needs_review`; mark_processed only from `approved`."

  input {
    text current_status? { description = "The file's current status" }
    text action? { description = "One of: validate, send_to_review, approve, reject, mark_processed" }
  }

  stack {
    // Map each action to the single status it is allowed to run from.
    var $required {
      value = {
        validate: "registered",
        send_to_review: "validated",
        approve: "needs_review",
        reject: "needs_review",
        mark_processed: "approved"
      }
    }

    var $action { value = (($input.action ?? "")|trim) }
    var $status { value = (($input.current_status ?? "")|trim) }
    var $allowed { value = false }
    var $err { value = "" }

    var $needed { value = ($required|get:$action) }

    conditional {
      if ($needed == null) {
        var.update $err { value = ("Unknown action '" ~ $action ~ "'.") }
      }
      elseif ($status == $needed) {
        var.update $allowed { value = true }
      }
      else {
        var.update $err { value = ("Action '" ~ $action ~ "' requires status '" ~ $needed ~ "', but the file is '" ~ $status ~ "'.") }
      }
    }
  }

  response = {allowed: $allowed, error: $err, required_status: $needed}

  test "validate is allowed only from registered" {
    input = {current_status: "registered", action: "validate"}
    expect.to_be_true ($response.allowed)
  }

  test "validate is rejected from validated" {
    input = {current_status: "validated", action: "validate"}
    expect.to_be_false ($response.allowed)
  }

  test "send_to_review is allowed only from validated" {
    input = {current_status: "validated", action: "send_to_review"}
    expect.to_be_true ($response.allowed)
  }

  test "send_to_review is rejected from registered" {
    input = {current_status: "registered", action: "send_to_review"}
    expect.to_be_false ($response.allowed)
  }

  test "approve is allowed only from needs_review" {
    input = {current_status: "needs_review", action: "approve"}
    expect.to_be_true ($response.allowed)
  }

  test "approve is rejected from validated" {
    input = {current_status: "validated", action: "approve"}
    expect.to_be_false ($response.allowed)
  }

  test "reject is allowed only from needs_review" {
    input = {current_status: "needs_review", action: "reject"}
    expect.to_be_true ($response.allowed)
  }

  test "reject is rejected from approved" {
    input = {current_status: "approved", action: "reject"}
    expect.to_be_false ($response.allowed)
  }

  test "mark_processed is allowed only from approved" {
    input = {current_status: "approved", action: "mark_processed"}
    expect.to_be_true ($response.allowed)
  }

  test "mark_processed is rejected from needs_review" {
    input = {current_status: "needs_review", action: "mark_processed"}
    expect.to_be_false ($response.allowed)
  }

  test "unknown action is rejected" {
    input = {current_status: "registered", action: "frobnicate"}
    expect.to_be_false ($response.allowed)
  }
  guid = "1waGBnH3mMEfuVXcXPKNZWYf6a4"
}
---
function "s3_file_intake_log_request" {
  description = "Write one audit row to api_request_logs for an endpoint call. Called by every endpoint exactly once, on both success and failure, so the request log is a complete record of traffic and outcomes. Generates a request_id when the caller doesn't supply one."

  input {
    text endpoint { description = "Endpoint path, e.g. POST /files/register" }
    text status { description = "ok | unauthorized | invalid | conflict | not_found | error" }
    text requester_id? { description = "Identity of the caller, when known" }
    text error_message? { description = "Error detail on a non-ok outcome" }
    text request_id? { description = "Optional client-supplied correlation id" }
  }

  stack {
    var $rid { value = (($input.request_id ?? "")|trim) }
    conditional {
      if (($rid|strlen) == 0) {
        security.create_uuid as $uuid
        var.update $rid { value = $uuid }
      }
    }

    db.add "api_request_logs" {
      data = {
        request_id: $rid,
        endpoint: $input.endpoint,
        requester_id: $input.requester_id,
        status: $input.status,
        error_message: $input.error_message
      }
    } as $row
  }

  response = {request_id: $rid, log_id: $row.id}
  guid = "6erT2s7R5AUMMuQeiJnM5GezuMs"
}
---
function "s3_file_intake_record_event" {
  description = "Append one row to file_events for a file. Called on registration and on every status change (file_registered, file_validated, file_failed_validation, file_sent_to_review, file_approved, file_rejected, file_processed), giving each file a complete, ordered audit trail."

  input {
    int file_id { description = "The file this event belongs to" }
    text event_type { description = "Event name, e.g. file_validated" }
    json event_payload? { description = "Arbitrary structured context for the event" }
    text created_by? { description = "Identity that triggered the event, when known" }
  }

  stack {
    db.add "file_events" {
      data = {
        file_id: $input.file_id,
        event_type: $input.event_type,
        event_payload: $input.event_payload,
        created_by: $input.created_by
      }
    } as $row
  }

  response = {event_id: $row.id}
  guid = "OUEjHwTyw15iRIrqCaqldlS1k0U"
}
---
function "s3_file_intake_s3_head" {
  description = "Best-effort existence check of the S3 object behind a key, using Xano's native cloud.aws.s3.get_file_info with $env.AWS_ACCESS_KEY_ID / $env.AWS_SECRET_ACCESS_KEY / $env.AWS_REGION / $env.S3_BUCKET_NAME. Only runs when all four are configured; otherwise returns {checked:false} so un-provisioned workspaces (and credential-free tests) skip it cleanly. Wrapped in try_catch — a missing object or transport error returns {checked:true, exists:false, error} and never throws. Returns {checked, exists, size, error}."

  input {
    text s3_key? { description = "The object key to look up in the bucket" }
  }

  stack {
    var $bucket { value = ($env.S3_BUCKET_NAME ?? "") }
    var $region { value = ($env.AWS_REGION ?? "") }
    var $access_key { value = ($env.AWS_ACCESS_KEY_ID ?? "") }
    var $secret_key { value = ($env.AWS_SECRET_ACCESS_KEY ?? "") }
    var $key { value = (($input.s3_key ?? "")|trim) }

    var $configured {
      value = ((($bucket|strlen) > 0) && (($region|strlen) > 0) && (($access_key|strlen) > 0) && (($secret_key|strlen) > 0) && (($key|strlen) > 0))
    }

    var $checked { value = false }
    var $exists { value = false }
    var $size { value = null }
    var $err { value = "" }

    conditional {
      if ($configured == true) {
        var.update $checked { value = true }
        try_catch {
          try {
            cloud.aws.s3.get_file_info {
              bucket = $bucket
              region = $region
              key = $access_key
              secret = $secret_key
              file_key = $key
            } as $info
            var.update $exists { value = true }
            var.update $size { value = (($info|get:"size") ?? ($info|get:"ContentLength")) }
          }
          catch {
            var.update $exists { value = false }
            var.update $err { value = "S3 object not found or not reachable for the supplied key/credentials." }
          }
        }
      }
    }
  }

  response = {checked: $checked, exists: $exists, size: $size, error: $err}

  test "skips the S3 call when AWS credentials are not configured" {
    input = {s3_key: "incoming/report.pdf"}
    expect.to_be_false ($response.checked)
  }
  guid = "69MAOmERdmNqAue77peMvDs1Dpc"
}
---
function "s3_file_intake_s3_object_url" {
  description = "Build the canonical virtual-hosted-style S3 object URL for a key from $env.S3_BUCKET_NAME and $env.AWS_REGION: https://<bucket>.s3.<region>.amazonaws.com/<s3_key>. Returns null when the bucket/region env vars are not configured so callers can omit the field honestly rather than emit a broken URL."

  input {
    text s3_key? { description = "The object key within the bucket" }
  }

  stack {
    var $bucket {
      value = ($env.S3_BUCKET_NAME ?? "")
      mock = {
        "builds a virtual-hosted-style url from bucket + region": "acme-intake",
        "returns null when bucket is not configured": ""
      }
    }
    var $region {
      value = ($env.AWS_REGION ?? "")
      mock = {
        "builds a virtual-hosted-style url from bucket + region": "us-east-1",
        "returns null when bucket is not configured": "us-east-1"
      }
    }
    var $key { value = (($input.s3_key ?? "")|trim) }
    var $url { value = null }

    conditional {
      if ((($bucket|strlen) > 0) && (($region|strlen) > 0) && (($key|strlen) > 0)) {
        var.update $url { value = ("https://" ~ $bucket ~ ".s3." ~ $region ~ ".amazonaws.com/" ~ $key) }
      }
    }
  }

  response = {url: $url, bucket: $bucket, region: $region}

  test "builds a virtual-hosted-style url from bucket + region" {
    input = {s3_key: "incoming/report.pdf"}
    expect.to_equal ($response.url) { value = "https://acme-intake.s3.us-east-1.amazonaws.com/incoming/report.pdf" }
  }

  test "returns null when bucket is not configured" {
    input = {s3_key: "incoming/report.pdf"}
    expect.to_be_null ($response.url)
  }
  guid = "ZSLftlGY_1PLeSXZ7Cq3Q4a36KM"
}
---
function "s3_file_intake_validate_metadata" {
  description = "Pure validation of a file's declared metadata against the intake policy: file_type must be one of pdf, csv, xlsx, json, and file_size_bytes must be > 0 and <= 25 MB (26214400 bytes). Returns {valid, reason} and never throws, so callers can branch the file to `validated` or `failed` and log the reason. 25 MB boundary is inclusive."

  input {
    text file_type? { description = "Declared file type / extension (case-insensitive)" }
    int file_size_bytes? { description = "Declared file size in bytes" }
  }

  stack {
    var $max_bytes { value = 26214400 }
    var $allowed { value = ["pdf", "csv", "xlsx", "json"] }
    var $type_norm { value = (($input.file_type ?? "")|trim|to_lower) }
    var $size { value = ($input.file_size_bytes ?? 0) }

    var $valid { value = true }
    var $reason { value = "" }

    conditional {
      if (($allowed|some:$$ == $type_norm) == false) {
        var.update $valid { value = false }
        var.update $reason { value = ("Unsupported file_type '" ~ $type_norm ~ "'. Allowed: pdf, csv, xlsx, json.") }
      }
    }

    conditional {
      if (($valid == true) && ($size <= 0)) {
        var.update $valid { value = false }
        var.update $reason { value = "file_size_bytes must be greater than 0." }
      }
    }

    conditional {
      if (($valid == true) && ($size > $max_bytes)) {
        var.update $valid { value = false }
        var.update $reason { value = ("File size " ~ ($size|to_text) ~ " bytes exceeds the 25 MB (26214400 bytes) limit.") }
      }
    }
  }

  response = {valid: $valid, reason: $reason, type_norm: $type_norm, max_bytes: $max_bytes}

  test "accepts a pdf under the limit" {
    input = {file_type: "PDF", file_size_bytes: 1048576}
    expect.to_be_true ($response.valid)
  }

  test "accepts csv json xlsx" {
    input = {file_type: "xlsx", file_size_bytes: 10}
    expect.to_be_true ($response.valid)
  }

  test "accepts a file exactly at the 25 MB boundary" {
    input = {file_type: "json", file_size_bytes: 26214400}
    expect.to_be_true ($response.valid)
  }

  test "rejects a file one byte over the 25 MB boundary" {
    input = {file_type: "json", file_size_bytes: 26214401}
    expect.to_be_false ($response.valid)
  }

  test "rejects an unsupported file type" {
    input = {file_type: "exe", file_size_bytes: 100}
    expect.to_be_false ($response.valid)
  }

  test "rejects a zero-byte file" {
    input = {file_type: "pdf", file_size_bytes: 0}
    expect.to_be_false ($response.valid)
  }

  test "normalizes file type case" {
    input = {file_type: "Csv", file_size_bytes: 100}
    expect.to_equal ($response.type_norm) { value = "csv" }
  }
  guid = "uyfG_WNSPTL-JfPSn5rjQFzxpJI"
}
---
api_group S3FileIntake {
  canonical = "s3-file-intake"
  description = "Govern files stored in AWS S3 from Xano: register metadata, validate type + size, drive an approval state machine, and expose a full, audited event history. S3 stores the bytes; Xano owns the workflow."
  tags = ["s3", "files", "workflow", "governance"]
  guid = "4GRZkUQ9U2E1kQCRIRnSsVnSO-M"
}
---
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
---
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
---
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
---
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
---
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
---
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
---
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
---
// Outcome test: a file walks the full intake lifecycle register -> validate -> send-to-review ->
// approve -> mark-processed, the status is correct at every step, and the audit trail (file_events)
// + request log (api_request_logs) are written. Runs credential-free: API_AUTH_SECRET is unset on the
// throwaway workspace (no-op auth gate), and validation uses declared metadata (no S3 call needed).
workflow_test "s3_file_intake_happy_path_register_to_processed" {
  stack {
    // 1. Register a fresh file (unique s3_key per run).
    var $rid { value = ("wf-" ~ ("now"|to_ms|to_text)) }
    var $key { value = ("incoming/" ~ $rid ~ "/report.pdf") }

    api.call "files/register" verb=POST {
      api_group = "S3FileIntake"
      input = {s3_key: $key, file_name: "report.pdf", file_type: "pdf", file_size_bytes: 1048576, uploaded_by: "wf-tester", request_id: $rid}
    } as $registered

    expect.to_not_be_null ($registered.file.id)
    expect.to_equal ($registered.status) { value = "registered" }

    var $fid { value = $registered.file.id }

    // 2. Validate -> validated.
    api.call "files/{file_id}/validate" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid, uploaded_by: "wf-tester", request_id: $rid}
    } as $validated

    expect.to_equal ($validated.status) { value = "validated" }
    expect.to_be_true ($validated.valid)

    // 3. Send to review -> needs_review + a pending review.
    api.call "files/{file_id}/send-to-review" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid, uploaded_by: "wf-tester", request_id: $rid}
    } as $in_review

    expect.to_equal ($in_review.status) { value = "needs_review" }
    expect.to_equal ($in_review.review.review_status) { value = "pending" }

    // 4. Approve -> approved (file + review).
    api.call "files/{file_id}/approve" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid, reviewer_id: "reviewer-1", review_note: "Looks good.", request_id: $rid}
    } as $approved

    expect.to_equal ($approved.status) { value = "approved" }
    expect.to_equal ($approved.review_status) { value = "approved" }

    // 5. Mark processed -> processed.
    api.call "files/{file_id}/mark-processed" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid, uploaded_by: "wf-tester", request_id: $rid}
    } as $processed

    expect.to_equal ($processed.status) { value = "processed" }

    // 6. The read model reflects the final state and carries the full event history.
    api.call "files/{file_id}/status" verb=GET {
      api_group = "S3FileIntake"
      input = {file_id: $fid, request_id: $rid}
    } as $status

    expect.to_equal ($status.status) { value = "processed" }
    expect.to_equal ($status.review_status) { value = "approved" }

    // 7. Every status change wrote a file_events row: registered, validated, sent_to_review,
    //    approved, processed = 5 events for this file.
    db.query "file_events" {
      where = $db.file_events.file_id == $fid
      return = {type: "count"}
    } as $event_count
    expect.to_equal ($event_count) { value = 5 }

    // 8. Each endpoint call wrote an api_request_logs row: register, validate, send-to-review,
    //    approve, mark-processed, status = 6 successful requests, all logged with status "ok".
    db.query "api_request_logs" {
      where = $db.api_request_logs.request_id == $rid && $db.api_request_logs.status == "ok"
      return = {type: "count"}
    } as $log_count
    expect.to_be_greater_than ($log_count) { value = 5 }
  }
  tags = ["s3_file_intake", "outcome", "lifecycle"]
  guid = "pYcka7tPKAYQNl355XUsCazto6Q"
}
---
// Flow test: the reject branch. A file reaches review and is rejected with a note (file + review ->
// rejected); an invalid file fails validation instead of being validated; and an empty-note
// rejection is refused. Credential-free (API_AUTH_SECRET unset on the throwaway workspace).
workflow_test "s3_file_intake_reject_and_failed_validation_paths" {
  stack {
    var $rid { value = ("wf-rej-" ~ ("now"|to_ms|to_text)) }

    // --- Reject branch: register -> validate -> send-to-review -> reject ---
    var $key1 { value = ("incoming/" ~ $rid ~ "/contract.csv") }
    api.call "files/register" verb=POST {
      api_group = "S3FileIntake"
      input = {s3_key: $key1, file_name: "contract.csv", file_type: "csv", file_size_bytes: 2048, uploaded_by: "wf-tester"}
    } as $reg
    var $fid { value = $reg.file.id }

    api.call "files/{file_id}/validate" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid}
    } as $val
    expect.to_equal ($val.status) { value = "validated" }

    api.call "files/{file_id}/send-to-review" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid}
    } as $rev
    expect.to_equal ($rev.status) { value = "needs_review" }

    // Reject with a note -> rejected.
    api.call "files/{file_id}/reject" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid, reviewer_id: "reviewer-9", review_note: "Wrong document; reupload."}
    } as $rejected
    expect.to_equal ($rejected.status) { value = "rejected" }
    expect.to_equal ($rejected.review_status) { value = "rejected" }

    // The status read model shows rejected + the rejected review.
    api.call "files/{file_id}/status" verb=GET {
      api_group = "S3FileIntake"
      input = {file_id: $fid}
    } as $status1
    expect.to_equal ($status1.status) { value = "rejected" }
    expect.to_equal ($status1.review_status) { value = "rejected" }

    // --- Failed-validation branch: an oversize file fails instead of validating ---
    var $key3 { value = ("incoming/" ~ $rid ~ "/huge.json") }
    api.call "files/register" verb=POST {
      api_group = "S3FileIntake"
      input = {s3_key: $key3, file_name: "huge.json", file_type: "json", file_size_bytes: 99999999, uploaded_by: "wf-tester"}
    } as $reg3
    var $fid3 { value = $reg3.file.id }
    api.call "files/{file_id}/validate" verb=POST {
      api_group = "S3FileIntake"
      input = {file_id: $fid3}
    } as $val3
    expect.to_equal ($val3.status) { value = "failed" }
    expect.to_be_false ($val3.valid)

    // --- Empty-note rejection is refused. Self-contained inside the to_throw stack (nested stacks
    //     don't inherit outer vars): register -> validate -> send-to-review -> reject with a blank note,
    //     which must throw an input error.
    expect.to_throw {
      stack {
        var $rid2 { value = ("wf-rej2-" ~ ("now"|to_ms|to_text)) }
        var $key2 { value = ("incoming/" ~ $rid2 ~ "/contract2.csv") }
        api.call "files/register" verb=POST {
          api_group = "S3FileIntake"
          input = {s3_key: $key2, file_name: "contract2.csv", file_type: "csv", file_size_bytes: 2048, uploaded_by: "wf-tester"}
        } as $reg2
        api.call "files/{file_id}/validate" verb=POST {
          api_group = "S3FileIntake"
          input = {file_id: $reg2.file.id}
        } as $val2
        api.call "files/{file_id}/send-to-review" verb=POST {
          api_group = "S3FileIntake"
          input = {file_id: $reg2.file.id}
        } as $rev2
        api.call "files/{file_id}/reject" verb=POST {
          api_group = "S3FileIntake"
          input = {file_id: $reg2.file.id, reviewer_id: "reviewer-9", review_note: "   "}
        } as $bad_reject
      }
      exception = "review_note"
    }
  }
  tags = ["s3_file_intake", "flow", "reject"]
  guid = "7h41uZt5Z75TA4ANV5MBb2kUx-4"
}
