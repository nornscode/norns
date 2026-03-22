defmodule Norns.Agents.Registry do
  @moduledoc "Manages agent process lifecycle: start, stop, lookup, resume."

  alias Norns.Agents.Process, as: AgentProcess

  @doc "Start a new agent process under the DynamicSupervisor."
  def start_agent(agent_id, tenant_id, opts \\ []) do
    child_opts =
      Keyword.merge(opts, agent_id: agent_id, tenant_id: tenant_id)

    DynamicSupervisor.start_child(Norns.AgentSupervisor, {AgentProcess, child_opts})
  end

  @doc "Resume an agent from an existing run's event log."
  def resume_agent(run_id, agent_id, tenant_id, opts \\ []) do
    child_opts =
      Keyword.merge(opts,
        agent_id: agent_id,
        tenant_id: tenant_id,
        resume_run_id: run_id
      )

    DynamicSupervisor.start_child(Norns.AgentSupervisor, {AgentProcess, child_opts})
  end

  @doc "Send a message to a running agent."
  def send_message(tenant_id, agent_id, content) do
    case lookup(tenant_id, agent_id) do
      {:ok, pid} ->
        AgentProcess.send_message(pid, content)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc "Stop a running agent process gracefully."
  def stop_agent(tenant_id, agent_id) do
    case lookup(tenant_id, agent_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(Norns.AgentSupervisor, pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc "Look up a running agent process."
  def lookup(tenant_id, agent_id) do
    case Registry.lookup(Norns.AgentRegistry, {tenant_id, agent_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Check if an agent process is alive."
  def alive?(tenant_id, agent_id) do
    case lookup(tenant_id, agent_id) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end
end
