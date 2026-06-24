function "s3_file_intake_check_transition" {
  description = "Pure state-machine guard. Given a file's current status and a requested action, returns {allowed, error} describing whether the transition is legal. Never throws — callers branch on `allowed` and surface `error` to the client + the api_request_logs row. Rules: validate only from `registered`; send_to_review only from `validated`; approve/reject only from `needs_review`; mark_processed only from `approved`."

  input {
    text current_status? { description = "The file's current status" }
    text action? { description = "One of: validate, send_to_review, approve, reject, mark_processed" }
  }

  stack {
    // Map each action to the single status it is allowed to run from.
    var $required {
      value = {
        validate: "registered",
        send_to_review: "validated",
        approve: "needs_review",
        reject: "needs_review",
        mark_processed: "approved"
      }
    }

    var $action { value = (($input.action ?? "")|trim) }
    var $status { value = (($input.current_status ?? "")|trim) }
    var $allowed { value = false }
    var $err { value = "" }

    var $needed { value = ($required|get:$action) }

    conditional {
      if ($needed == null) {
        var.update $err { value = ("Unknown action '" ~ $action ~ "'.") }
      }
      elseif ($status == $needed) {
        var.update $allowed { value = true }
      }
      else {
        var.update $err { value = ("Action '" ~ $action ~ "' requires status '" ~ $needed ~ "', but the file is '" ~ $status ~ "'.") }
      }
    }
  }

  response = {allowed: $allowed, error: $err, required_status: $needed}

  test "validate is allowed only from registered" {
    input = {current_status: "registered", action: "validate"}
    expect.to_be_true ($response.allowed)
  }

  test "validate is rejected from validated" {
    input = {current_status: "validated", action: "validate"}
    expect.to_be_false ($response.allowed)
  }

  test "send_to_review is allowed only from validated" {
    input = {current_status: "validated", action: "send_to_review"}
    expect.to_be_true ($response.allowed)
  }

  test "send_to_review is rejected from registered" {
    input = {current_status: "registered", action: "send_to_review"}
    expect.to_be_false ($response.allowed)
  }

  test "approve is allowed only from needs_review" {
    input = {current_status: "needs_review", action: "approve"}
    expect.to_be_true ($response.allowed)
  }

  test "approve is rejected from validated" {
    input = {current_status: "validated", action: "approve"}
    expect.to_be_false ($response.allowed)
  }

  test "reject is allowed only from needs_review" {
    input = {current_status: "needs_review", action: "reject"}
    expect.to_be_true ($response.allowed)
  }

  test "reject is rejected from approved" {
    input = {current_status: "approved", action: "reject"}
    expect.to_be_false ($response.allowed)
  }

  test "mark_processed is allowed only from approved" {
    input = {current_status: "approved", action: "mark_processed"}
    expect.to_be_true ($response.allowed)
  }

  test "mark_processed is rejected from needs_review" {
    input = {current_status: "needs_review", action: "mark_processed"}
    expect.to_be_false ($response.allowed)
  }

  test "unknown action is rejected" {
    input = {current_status: "registered", action: "frobnicate"}
    expect.to_be_false ($response.allowed)
  }
  guid = "1waGBnH3mMEfuVXcXPKNZWYf6a4"
}
