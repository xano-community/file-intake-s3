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
