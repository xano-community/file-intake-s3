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
