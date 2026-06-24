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
