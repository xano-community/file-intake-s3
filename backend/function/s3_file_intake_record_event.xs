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
