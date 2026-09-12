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
      context_policy: Map.get(agent.model_config || %{}, "context_policy"),
      max_steps: agent.max_steps,
      archived_at: agent.archived_at,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end

  def run(run) do
    %{
      id: run.id,
      agent_id: run.agent_id,
      conversation_id: run.conversation_id,
      parent_run_id: run.parent_run_id,
      depth: run.depth,
      gard_id: run.gard_id,
      status: run.status,
      trigger_type: run.trigger_type,
      input: run.input,
      output: run.output,
      failure_metadata: run.failure_metadata || %{},
      failure_inspector: Norns.Runs.failure_inspector(run),
      waiting_for: Norns.Runs.pending_question(run),
      input_tokens: run.input_tokens || 0,
      output_tokens: run.output_tokens || 0,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  # Never includes the claim token — that's returned once, on create.
  def gard(gard) do
    %{
      id: gard.id,
      name: gard.name,
      status: gard.status,
      template: gard.template,
      metadata: gard.metadata || %{},
      inserted_at: gard.inserted_at,
      updated_at: gard.updated_at
    }
  end

  def gard_port(port) do
    %{
      id: port.id,
      internal_port: port.internal_port,
      url: port.url,
      name: port.name,
      protocol: port.protocol
    }
  end

  def hook(hook) do
    %{
      id: hook.id,
      agent_id: hook.agent_id,
      name: hook.name,
      token: hook.token,
      path: "/api/v1/hooks/#{hook.token}",
      message_path: hook.message_path,
      conversation_key_path: hook.conversation_key_path,
      signature_type: hook.signature_type,
      enabled: hook.enabled,
      inserted_at: hook.inserted_at,
      updated_at: hook.updated_at
    }
  end

  def trigger(trigger) do
    %{
      id: trigger.id,
      agent_id: trigger.agent_id,
      name: trigger.name,
      cron: trigger.cron,
      message: trigger.message,
      conversation_key: trigger.conversation_key,
      enabled: trigger.enabled,
      last_fired_at: trigger.last_fired_at,
      inserted_at: trigger.inserted_at,
      updated_at: trigger.updated_at
    }
  end

  def tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      # Included here, unlike in the event log: an agent author needs the
      # shape of a call, and this is fetched once rather than per step.
      input_schema: tool.input_schema,
      source: Norns.Tools.Catalog.source(tool),
      side_effect: tool.side_effect?
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
