defmodule Norns.Agents do
  @moduledoc "Agent CRUD."

  import Ecto.Query

  alias Norns.Repo
  alias Norns.Agents.Agent

  @doc """
  Fetch an agent by id, archived or not.

  Archived agents stay readable: their runs are still in the log, and a run
  page has to be able to name the agent that produced it.
  """
  def get_agent!(id), do: Repo.get!(Agent, id)

  def list_agents(tenant_id) do
    Agent
    |> where([a], a.tenant_id == ^tenant_id and is_nil(a.archived_at))
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  def get_agent_by_name(tenant_id, name) do
    Agent
    |> where([a], a.tenant_id == ^tenant_id and a.name == ^name and is_nil(a.archived_at))
    |> Repo.one()
  end

  @doc """
  Archive an agent: stamp `archived_at` and stop every process it has
  running. The row, its runs, and its conversations all stay — an event log
  you can delete is not a log. Archiving frees the name for reuse.

  Refuses while a run is in flight unless `force: true`, so cleaning up a
  stale agent can never quietly kill work someone is waiting on.
  """
  def archive(tenant_id, agent_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if not force and has_active_run?(agent_id) do
      {:error, :active_run}
    else
      query =
        from a in Agent,
          where: a.id == ^agent_id and a.tenant_id == ^tenant_id and is_nil(a.archived_at)

      case Repo.update_all(query, set: [archived_at: DateTime.utc_now(), status: "inactive"]) do
        {1, _} ->
          Norns.Agents.Registry.stop_all(tenant_id, agent_id)
          :ok

        {0, _} ->
          {:error, :not_found}
      end
    end
  end

  defp has_active_run?(agent_id) do
    Repo.exists?(
      from r in Norns.Runs.Run,
        where: r.agent_id == ^agent_id and r.status in ["pending", "running", "waiting"]
    )
  end

  def create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end
end
