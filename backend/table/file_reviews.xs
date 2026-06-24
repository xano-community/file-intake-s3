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
