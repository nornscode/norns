defmodule Norns.Runtime.ErrorPolicyTest do
  @moduledoc "Gate 3: Failure classification and retry policy conformance."
  use ExUnit.Case, async: true

  alias Norns.Runtime.{Errors, ErrorPolicy}

  describe "error classification" do
    test "429 classified as external_dependency/rate_limited" do
      error = Errors.classify({429, %{"message" => "rate limit"}})
      assert error.class == :external_dependency
      assert error.code == :rate_limited
    end

    test "500 classified as external_dependency/upstream_unavailable" do
      error = Errors.classify({500, %{"message" => "internal error"}})
      assert error.class == :external_dependency
      assert error.code == :upstream_unavailable
    end

    test "502 classified as external_dependency/upstream_unavailable" do
      error = Errors.classify({502, "bad gateway"})
      assert error.class == :external_dependency
      assert error.code == :upstream_unavailable
    end

    test "timeout classified as transient/timeout" do
      error = Errors.classify(:timeout)
      assert error.class == :transient
      assert error.code == :timeout
    end

    test "validation tuple classified correctly" do
      error = Errors.classify({:validation, :bad_schema, "invalid input"})
      assert error.class == :validation
      assert error.code == :bad_schema
    end

    test "policy tuple classified correctly" do
      error = Errors.classify({:policy, :forbidden, "not allowed"})
      assert error.class == :policy
      assert error.code == :forbidden
    end

    test "internal string classified as internal/runtime_failure" do
      error = Errors.classify({:internal, "something broke"})
      assert error.class == :internal
      assert error.code == :runtime_failure
    end

    test "unknown errors classified as internal/unexpected_failure" do
      error = Errors.classify(%RuntimeError{message: "boom"})
      assert error.class == :internal
      assert error.code == :unexpected_failure
    end

    test "to_metadata produces string keys" do
      error = Errors.classify({429, "rate limit"})
      meta = Errors.to_metadata(error)
      assert is_binary(meta["error_class"])
      assert is_binary(meta["error_code"])
      assert is_binary(meta["error"])
    end
  end

  describe "retry policy decisions" do
    test "rate_limited errors are retryable with linear backoff" do
      error = Errors.classify({429, "rate limit"})
      decision = ErrorPolicy.decision(error, 0)
      assert decision.action == :retry
      assert decision.delay_ms == 15_000
      assert decision.retry_decision == "retry"
    end

    test "rate_limited errors exhaust after 10 retries" do
      error = Errors.classify({429, "rate limit"})
      decision = ErrorPolicy.decision(error, 10)
      assert decision.action == :terminal
      assert decision.retry_decision == "terminal"
    end

    test "upstream_unavailable errors are retryable with exponential backoff" do
      error = Errors.classify({500, "server error"})
      d0 = ErrorPolicy.decision(error, 0)
      d1 = ErrorPolicy.decision(error, 1)
      assert d0.action == :retry
      assert d0.delay_ms == 1000
      assert d1.delay_ms == 2000
    end

    test "upstream_unavailable errors exhaust after 3 retries" do
      error = Errors.classify({500, "server error"})
      decision = ErrorPolicy.decision(error, 3)
      assert decision.action == :terminal
    end

    test "timeout errors are retryable" do
      error = Errors.classify(:timeout)
      decision = ErrorPolicy.decision(error, 0)
      assert decision.action == :retry
    end

    test "validation errors are terminal" do
      error = Errors.classify({:validation, :bad_input, "nope"})
      decision = ErrorPolicy.decision(error, 0)
      assert decision.action == :terminal
      assert decision.retry_decision == "terminal"
    end

    test "policy errors are terminal" do
      error = Errors.classify({:policy, :denied, "not allowed"})
      decision = ErrorPolicy.decision(error, 0)
      assert decision.action == :terminal
    end

    test "internal errors are terminal" do
      error = Errors.classify({:internal, "crash"})
      decision = ErrorPolicy.decision(error, 0)
      assert decision.action == :terminal
    end

    test "decisions are deterministic (same input = same output)" do
      error = Errors.classify({429, "rate limit"})
      d1 = ErrorPolicy.decision(error, 2)
      d2 = ErrorPolicy.decision(error, 2)
      assert d1 == d2
    end
  end
end
