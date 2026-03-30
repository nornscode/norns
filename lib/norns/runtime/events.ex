defmodule Norns.Runtime.Events do
  @moduledoc false

  alias Norns.Runtime.{Event, EventValidator}
  alias Norns.Runtime.Events.{
    CheckpointSaved,
    LlmRequest,
    LlmResponse,
    RunCompleted,
    RunFailed,
    RunStarted,
    SubagentLaunched,
    ToolCall,
    ToolDuplicate,
    ToolResult
  }

  @type result :: {:ok, Event.t()} | {:error, map()}

  def run_started(attrs \\ %{}), do: RunStarted.new(attrs)
  def llm_request(attrs), do: LlmRequest.new(attrs)
  def llm_response(attrs), do: LlmResponse.new(attrs)
  def tool_call(attrs), do: ToolCall.new(attrs)
  def tool_duplicate(attrs), do: ToolDuplicate.new(attrs)
  def tool_result(attrs), do: ToolResult.new(attrs)
  def checkpoint_saved(attrs), do: CheckpointSaved.new(attrs)
  def run_failed(attrs), do: RunFailed.new(attrs)
  def run_completed(attrs), do: RunCompleted.new(attrs)
  def subagent_launched(attrs), do: SubagentLaunched.new(attrs)

  def retry(attrs), do: build("retry", attrs)

  def build(event_type, payload, opts \\ []) do
    EventValidator.validate(%Event{
      event_type: event_type,
      payload: payload,
      source: Keyword.get(opts, :source, "system"),
      metadata: Keyword.get(opts, :metadata, %{})
    })
    |> case do
      {:ok, attrs} -> {:ok, struct(Event, attrs)}
      error -> error
    end
  end
end
