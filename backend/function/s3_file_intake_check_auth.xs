function "s3_file_intake_check_auth" {
  description = "Gate every endpoint on the shared API_AUTH_SECRET. When $env.API_AUTH_SECRET is set, the caller-supplied secret must match it exactly (constant comparison) or the request is denied. When API_AUTH_SECRET is unset/empty (e.g. an un-provisioned workspace), the gate is a no-op so the module still runs — production deployments MUST set it. Returns {ok, error} and never throws."

  input {
    text provided_secret? { description = "Secret supplied by the caller (X-API-Secret header or api_secret body field)" }
  }

  stack {
    // Reading the env here keeps the secret out of inputs; mocked in unit tests to cover both branches.
    var $configured {
      value = ($env.API_AUTH_SECRET ?? "")
      mock = {
        "denies when secret is configured and the request omits it": "s3cr3t-prod-value",
        "denies when secret is configured and the request sends the wrong value": "s3cr3t-prod-value",
        "allows when secret is configured and the request matches": "s3cr3t-prod-value"
      }
    }
    var $provided { value = ($input.provided_secret ?? "") }

    var $ok { value = true }
    var $err { value = "" }

    conditional {
      if (($configured|strlen) > 0) {
        conditional {
          if ($provided == $configured) {
            var.update $ok { value = true }
          }
          else {
            var.update $ok { value = false }
            var.update $err { value = "Unauthorized: missing or invalid API secret." }
          }
        }
      }
    }
  }

  response = {ok: $ok, error: $err, enforced: (($configured|strlen) > 0)}

  test "allows when no secret is configured (no-op gate)" {
    input = {provided_secret: ""}
    expect.to_be_true ($response.ok)
  }

  test "no-op gate reports enforced=false when unconfigured" {
    input = {provided_secret: "anything"}
    expect.to_be_false ($response.enforced)
  }

  test "allows when secret is configured and the request matches" {
    input = {provided_secret: "s3cr3t-prod-value"}
    expect.to_be_true ($response.ok)
  }

  test "denies when secret is configured and the request omits it" {
    input = {provided_secret: ""}
    expect.to_be_false ($response.ok)
  }

  test "denies when secret is configured and the request sends the wrong value" {
    input = {provided_secret: "guess"}
    expect.to_be_false ($response.ok)
  }
  guid = "ZG5p4rEXPbfL67ajao7IzEpaBlA"
}
