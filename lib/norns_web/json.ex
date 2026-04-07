defmodule NornsWeb.JSON do
  @moduledoc "Serialization helpers for API responses."

  def agent(agent) do
    %{
      id: agent.id,
      name: agent.name,
      purpose: agent.purpose,
      status: agent.status,
      system_prompt: agent.system_prompt,
      model: agent.model,
      context_strategy: Map.get(agent.model_config || %{}, "context_strategy", "sliding_window"),
      context_window: Map.get(agent.model_config || %{}, "context_window", 20),
      max_steps: agent.max_steps,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end

  def run(run) do
    %{
      id: run.id,
      agent_id: run.agent_id,
      conversation_id: run.conversation_id,
      status: run.status,
      trigger_type: run.trigger_type,
      input: run.input,
      output: run.output,
      failure_metadata: run.failure_metadata || %{},
      failure_inspector: Norns.Runs.failure_inspector(run),
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  def run_event(event) do
    %{
      id: event.id,
      sequence: event.sequence,
      event_type: event.event_type,
      payload: event.payload,
      source: event.source,
      inserted_at: event.inserted_at
    }
  end

  def conversation(conversation) do
    %{
      id: conversation.id,
      agent_id: conversation.agent_id,
      key: conversation.key,
      summary: conversation.summary,
      message_count: conversation.message_count,
      token_estimate: conversation.token_estimate,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end
end
