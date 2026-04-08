defmodule Norns.Runtime.ErrorPolicy do
  @moduledoc false

  alias Norns.Runtime.Errors.Error

  @default_max_retries 3
  @rate_limit_max_retries 10
  @rate_limit_base_delay_ms 15_000

  def decision(%Error{class: :external_dependency, code: :rate_limited}, retry_count) do
    bounded_decision(retry_count, @rate_limit_max_retries, @rate_limit_base_delay_ms * (retry_count + 1))
  end

  def decision(%Error{class: class, code: code}, retry_count)
      when {class, code} in [{:transient, :timeout}, {:transient, :worker_disconnected}, {:external_dependency, :upstream_unavailable}] do
    bounded_decision(retry_count, @default_max_retries, 1000 * Integer.pow(2, retry_count))
  end

  def decision(%Error{}, _retry_count) do
    %{action: :terminal, delay_ms: 0, retry_decision: "terminal"}
  end

  defp bounded_decision(retry_count, max_retries, delay_ms) when retry_count < max_retries do
    %{action: :retry, delay_ms: delay_ms, retry_decision: "retry", max_retries: max_retries}
  end

  defp bounded_decision(_retry_count, _max_retries, _delay_ms) do
    %{action: :terminal, delay_ms: 0, retry_decision: "terminal"}
  end
end
