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
