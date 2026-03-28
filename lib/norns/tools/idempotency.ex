defmodule Norns.Tools.Idempotency do
  @moduledoc false

  alias Norns.Tools.Tool

  @type context :: %{
          run_id: pos_integer(),
          step: pos_integer(),
          tool_call_id: String.t(),
          tool_name: String.t(),
          side_effect?: boolean(),
          idempotency_key: String.t() | nil
        }

  def context(%{id: run_id}, step, %{"id" => tool_call_id, "name" => tool_name} = tc, %Tool{} = tool) do
    arguments = tc["arguments"] || tc["input"] || %{}
    side_effect? = side_effecting?(tool, arguments)

    %{
      run_id: run_id,
      step: step,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      side_effect?: side_effect?,
      idempotency_key: if(side_effect?, do: key(run_id, step, tool_call_id, tool_name), else: nil)
    }
  end

  def key(run_id, step, tool_call_id, tool_name) do
    "run:#{run_id}:step:#{step}:tool:#{tool_call_id}:name:#{tool_name}"
  end

  def side_effecting?(%Tool{name: "http_request"}, %{"method" => method}) do
    String.upcase(method) == "POST"
  end

  def side_effecting?(%Tool{name: "http_request"}, _input), do: false
  def side_effecting?(%Tool{source: {:remote, _}}, _input), do: true
  def side_effecting?(%Tool{side_effect?: side_effect?}, _input), do: side_effect?
end
