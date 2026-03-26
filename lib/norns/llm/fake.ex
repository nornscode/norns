defmodule Norns.LLM.Fake do
  @moduledoc """
  Fake LLM for testing. Uses process dictionary or a registered scripted response list.

  ## Usage

  In tests, script responses before starting an agent:

      Norns.LLM.Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "Hello!"}], stop_reason: "end_turn"},
      ])

  Or for tool use flows:

      Norns.LLM.Fake.set_responses([
        %{content: [%{"type" => "tool_use", "id" => "call_1", "name" => "web_search", "input" => %{"query" => "elixir"}}], stop_reason: "tool_use"},
        %{content: [%{"type" => "text", "text" => "Here are the results."}], stop_reason: "end_turn"},
      ])
  """

  @behaviour Norns.LLM.Behaviour

  @doc "Set the scripted responses for the current test. Responses are consumed in order."
  def set_responses(responses) when is_list(responses) do
    # Store in an ETS table so GenServer processes can access them
    ensure_table()
    :ets.insert(__MODULE__, {:responses, responses})
    :ets.insert(__MODULE__, {:calls, []})
    :ok
  end

  @doc "Return recorded chat calls."
  def calls do
    ensure_table()

    case :ets.lookup(__MODULE__, :calls) do
      [{:calls, calls}] -> Enum.reverse(calls)
      _ -> []
    end
  end

  @doc "Get and consume the next scripted response."
  def next_response do
    ensure_table()

    case :ets.lookup(__MODULE__, :responses) do
      [{:responses, [next | rest]}] ->
        :ets.insert(__MODULE__, {:responses, rest})
        next

      _ ->
        %{
          content: [%{"type" => "text", "text" => "No more scripted responses"}],
          stop_reason: "end_turn",
          usage: %{input_tokens: 0, output_tokens: 0}
        }
    end
  end

  @impl true
  def chat(api_key, model, system_prompt, messages, opts \\ []) do
    record_call(%{api_key: api_key, model: model, system_prompt: system_prompt, messages: messages, opts: opts})
    response = next_response()

    response =
      Map.put_new(response, :usage, %{input_tokens: 10, output_tokens: 20})

    {:ok, response}
  end

  defp ensure_table do
    case :ets.info(__MODULE__) do
      :undefined ->
        :ets.new(__MODULE__, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end

  defp record_call(call) do
    ensure_table()

    calls =
      case :ets.lookup(__MODULE__, :calls) do
        [{:calls, existing}] -> existing
        _ -> []
      end

    :ets.insert(__MODULE__, {:calls, [call | calls]})
  end
end
