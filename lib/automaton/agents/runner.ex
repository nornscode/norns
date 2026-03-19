defmodule Automaton.Agents.Runner do
  @moduledoc """
  Synchronous agent execution. Takes an agent, input, and tenant,
  runs the LLM call, and records everything as a Run with events.
  """

  alias Automaton.Runs
  alias Automaton.LLM

  def execute(%{id: agent_id, tenant_id: tenant_id} = agent, input, tenant) do
    api_key = tenant.api_keys["anthropic"] || ""

    with {:ok, run} <- create_run(agent, input),
         {:ok, _} <- Runs.append_event(run, %{event_type: "run_started", source: "system"}),
         {:ok, run} <- Runs.update_run(run, %{status: "running"}),
         {:ok, response} <- call_llm(api_key, agent, input),
         {:ok, _} <- log_llm_response(run, response),
         {:ok, run} <- Runs.update_run(run, %{status: "completed", output: response}) do
      Runs.append_event(run, %{event_type: "run_completed", source: "system"})
      {:ok, run}
    else
      {:error, reason} = err ->
        # Best-effort: try to mark the run as failed if it exists
        handle_failure(agent_id, tenant_id, input, reason)
        err
    end
  end

  defp create_run(agent, input) do
    Runs.create_run(%{
      agent_id: agent.id,
      tenant_id: agent.tenant_id,
      trigger_type: "external",
      input: %{"user_message" => input},
      status: "pending"
    })
  end

  defp call_llm(api_key, agent, input) do
    model_config = agent.model_config || %{}
    opts = if model_config["max_tokens"], do: [max_tokens: model_config["max_tokens"]], else: []

    LLM.complete(api_key, agent.model, agent.system_prompt, input, opts)
  end

  defp log_llm_response(run, response) do
    Runs.append_event(run, %{
      event_type: "llm_response",
      source: "system",
      payload: %{"response" => response}
    })
  end

  defp handle_failure(agent_id, tenant_id, _input, reason) do
    # If we already have a run in the DB, we could look it up and mark failed.
    # For now, just log — the run's status stays wherever it was.
    require Logger

    Logger.error(
      "Agent run failed: agent_id=#{agent_id} tenant_id=#{tenant_id} reason=#{inspect(reason)}"
    )
  end
end
