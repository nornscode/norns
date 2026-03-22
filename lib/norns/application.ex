defmodule Norns.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Norns.Repo,
      {Oban, Application.fetch_env!(:norns, Oban)},
      {Phoenix.PubSub, name: Norns.PubSub},
      {Registry, keys: :unique, name: Norns.AgentRegistry},
      {DynamicSupervisor, name: Norns.AgentSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Norns.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Resume orphaned agent runs after supervision tree is up
    case result do
      {:ok, _pid} ->
        Norns.Workers.ResumeAgents.resume_orphans()
        result

      other ->
        other
    end
  end
end
