defmodule Automaton.Agents do
  @moduledoc "Agent CRUD."

  import Ecto.Query

  alias Automaton.Repo
  alias Automaton.Agents.Agent

  def get_agent!(id), do: Repo.get!(Agent, id)

  def get_agent_by_name(tenant_id, name) do
    Agent
    |> where([a], a.tenant_id == ^tenant_id and a.name == ^name)
    |> Repo.one()
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
