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
