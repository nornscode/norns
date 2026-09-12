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
    conversation_key = Keyword.get(opts, :conversation_key) || "run_#{System.unique_integer([:positive])}"

    case ensure_started(agent_id, tenant_id, conversation_key, opts) do
      {:ok, pid} ->
        AgentProcess.send_message(
          pid,
          content,
          Keyword.take(opts, [:context, :parent_run_id, :depth, :trigger_type, :gard_id])
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deliver a human's answer to the agent parked on a run's `ask_human` call.

  The run's conversation persists the key the process registered under, so the
  exact parked process is recoverable even for runs started without an explicit
  conversation key.
  """
  def reply_to_human(tenant_id, run, answer) do
    with {:ok, key} <- conversation_key_for(run),
         {:ok, pid} <- lookup(tenant_id, run.agent_id, key) do
      AgentProcess.reply_to_human(pid, answer)
    else
      :error -> {:error, :not_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp conversation_key_for(%{conversation_id: nil}), do: {:ok, "default"}

  defp conversation_key_for(%{conversation_id: id}) do
    case Norns.Conversations.get_conversation(id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation.key}
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

  @doc """
  Stop every running process of an agent, whatever conversation it is on.
  Returns how many were stopped. Used when archiving: the definition is
  going away, so none of its conversations should keep running.
  """
  def stop_all(tenant_id, agent_id) do
    Norns.AgentRegistry
    |> Registry.select([
      {{{:"$1", :"$2", :"$3"}, :"$4", :_}, [{:==, :"$1", tenant_id}, {:==, :"$2", agent_id}], [:"$4"]}
    ])
    |> Enum.count(fn pid ->
      DynamicSupervisor.terminate_child(Norns.AgentSupervisor, pid) == :ok
    end)
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

end
