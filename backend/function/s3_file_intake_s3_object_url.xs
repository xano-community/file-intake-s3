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
