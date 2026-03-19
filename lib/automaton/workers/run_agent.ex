defmodule Automaton.Workers.RunAgent do
  @moduledoc "Oban worker that executes an agent run."

  use Oban.Worker, queue: :agents, max_attempts: 1

  alias Automaton.Agents
  alias Automaton.Agents.Runner
  alias Automaton.Tenants

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"agent_id" => agent_id, "tenant_id" => tenant_id, "input" => input}}) do
    agent = Agents.get_agent!(agent_id)
    tenant = Tenants.get_tenant!(tenant_id)

    case Runner.execute(agent, input, tenant) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
