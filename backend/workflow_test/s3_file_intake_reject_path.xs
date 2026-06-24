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
