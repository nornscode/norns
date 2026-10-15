defmodule Norns.Workers.HttpSignatureTest do
  use ExUnit.Case, async: true

  alias Norns.Workers.HttpSignature

  @secret "s3cret"
  @body ~s({"type":"wake","worker_id":"w"})

  test "a fresh signature over the same bytes verifies" do
    header = HttpSignature.sign(@secret, @body)
    assert :ok = HttpSignature.verify(@secret, @body, header)
  end

  test "a different body or secret does not" do
    header = HttpSignature.sign(@secret, @body)
    assert {:error, "invalid_signature"} = HttpSignature.verify(@secret, @body <> " ", header)
    assert {:error, "invalid_signature"} = HttpSignature.verify("other", @body, header)
  end

  test "an old timestamp is rejected" do
    header = HttpSignature.sign(@secret, @body, System.os_time(:second) - 600)
    assert {:error, "stale_timestamp"} = HttpSignature.verify(@secret, @body, header)
  end

  test "a missing or malformed header is reported as missing" do
    assert {:error, "missing_signature"} = HttpSignature.verify(@secret, @body, nil)
    assert {:error, "missing_signature"} = HttpSignature.verify(@secret, @body, "garbage")
  end

  test "reads as a Stripe-style signature to the hooks verifier" do
    header = HttpSignature.sign(@secret, @body)
    hook = %{signature_type: "stripe", signing_secret: @secret}
    assert :ok = Norns.Hooks.Signature.verify(hook, @body, [{"stripe-signature", header}])
  end
end
