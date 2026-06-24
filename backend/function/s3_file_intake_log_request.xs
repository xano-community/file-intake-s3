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
