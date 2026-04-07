defmodule Norns.Agents.Registry do
  @moduledoc "Manages agent process lifecycle: start, stop, lookup, resume."

  alias Norns.Agents.Process, as: AgentProcess

  @doc "Start a new agent process under the DynamicSupervisor."
  def start_agent(agent_id, tenant_id, opts \\ []) do
    conversation_key = Keyword.get(opts, :conversation_key, "default")

    child_opts =
      Keyword.merge(opts, agent_id: agent_id, tenant_id: tenant_id, conversation_key: conversation_key)

    DynamicSupervisor.start_child(Norns.AgentSupervisor, {AgentProcess, child_opts})
  end

  def start_conversation(agent_id, tenant_id, conversation_key, opts \\ []) do
    start_agent(agent_id, tenant_id, Keyword.put(opts, :conversation_key, conversation_key))
  end

  @doc "Resume an agent from an existing run's event log."
  def resume_agent(run_id, agent_id, tenant_id, opts \\ []) do
    conversation_key = Keyword.get(opts, :conversation_key, "default")

    child_opts =
      Keyword.merge(opts,
        agent_id: agent_id,
        tenant_id: tenant_id,
        resume_run_id: run_id,
        conversation_key: conversation_key
      )

    DynamicSupervisor.start_child(Norns.AgentSupervisor, {AgentProcess, child_opts})
  end

  @doc "Send a message to a running agent."
  def send_message(tenant_id, agent_id, content, opts \\ []) do
    conversation_key = Keyword.get(opts, :conversation_key) || default_conversation_key(tenant_id, agent_id)

    case ensure_started(agent_id, tenant_id, conversation_key, opts) do
      {:ok, pid} ->
        AgentProcess.send_message(pid, content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop a running agent process gracefully."
  def stop_agent(tenant_id, agent_id, conversation_key \\ "default") do
    case lookup(tenant_id, agent_id, conversation_key) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(Norns.AgentSupervisor, pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc "Look up a running agent process."
  def lookup(tenant_id, agent_id, conversation_key \\ "default") do
    case Registry.lookup(Norns.AgentRegistry, {tenant_id, agent_id, conversation_key}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Check if an agent process is alive."
  def alive?(tenant_id, agent_id, conversation_key \\ "default") do
    case lookup(tenant_id, agent_id, conversation_key) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  defp ensure_started(agent_id, tenant_id, conversation_key, opts) do
    case lookup(tenant_id, agent_id, conversation_key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case start_agent(agent_id, tenant_id, Keyword.put(opts, :conversation_key, conversation_key)) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp default_conversation_key(tenant_id, agent_id) do
    agent = Norns.Agents.get_agent!(agent_id)
    mode = get_in(agent.model_config || %{}, ["mode"])

    if mode == "conversation" do
      "default"
    else
      "task_#{System.unique_integer([:positive])}"
    end
  end
end
