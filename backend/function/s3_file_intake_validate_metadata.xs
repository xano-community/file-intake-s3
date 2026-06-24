function "s3_file_intake_validate_metadata" {
  description = "Pure validation of a file's declared metadata against the intake policy: file_type must be one of pdf, csv, xlsx, json, and file_size_bytes must be > 0 and <= 25 MB (26214400 bytes). Returns {valid, reason} and never throws, so callers can branch the file to `validated` or `failed` and log the reason. 25 MB boundary is inclusive."

  input {
    text file_type? { description = "Declared file type / extension (case-insensitive)" }
    int file_size_bytes? { description = "Declared file size in bytes" }
  }

  stack {
    var $max_bytes { value = 26214400 }
    var $allowed { value = ["pdf", "csv", "xlsx", "json"] }
    var $type_norm { value = (($input.file_type ?? "")|trim|to_lower) }
    var $size { value = ($input.file_size_bytes ?? 0) }

    var $valid { value = true }
    var $reason { value = "" }

    conditional {
      if (($allowed|some:$$ == $type_norm) == false) {
        var.update $valid { value = false }
        var.update $reason { value = ("Unsupported file_type '" ~ $type_norm ~ "'. Allowed: pdf, csv, xlsx, json.") }
      }
    }

    conditional {
      if (($valid == true) && ($size <= 0)) {
        var.update $valid { value = false }
        var.update $reason { value = "file_size_bytes must be greater than 0." }
      }
    }

    conditional {
      if (($valid == true) && ($size > $max_bytes)) {
        var.update $valid { value = false }
        var.update $reason { value = ("File size " ~ ($size|to_text) ~ " bytes exceeds the 25 MB (26214400 bytes) limit.") }
      }
    }
  }

  response = {valid: $valid, reason: $reason, type_norm: $type_norm, max_bytes: $max_bytes}

  test "accepts a pdf under the limit" {
    input = {file_type: "PDF", file_size_bytes: 1048576}
    expect.to_be_true ($response.valid)
  }

  test "accepts csv json xlsx" {
    input = {file_type: "xlsx", file_size_bytes: 10}
    expect.to_be_true ($response.valid)
  }

  test "accepts a file exactly at the 25 MB boundary" {
    input = {file_type: "json", file_size_bytes: 26214400}
    expect.to_be_true ($response.valid)
  }

  test "rejects a file one byte over the 25 MB boundary" {
    input = {file_type: "json", file_size_bytes: 26214401}
    expect.to_be_false ($response.valid)
  }

  test "rejects an unsupported file type" {
    input = {file_type: "exe", file_size_bytes: 100}
    expect.to_be_false ($response.valid)
  }

  test "rejects a zero-byte file" {
    input = {file_type: "pdf", file_size_bytes: 0}
    expect.to_be_false ($response.valid)
  }

  test "normalizes file type case" {
    input = {file_type: "Csv", file_size_bytes: 100}
    expect.to_equal ($response.type_norm) { value = "csv" }
  }
  guid = "uyfG_WNSPTL-JfPSn5rjQFzxpJI"
}
