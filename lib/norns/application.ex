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
      {DynamicSupervisor, name: Norns.AgentSupervisor, strategy: :one_for_one},
      Norns.Workers.WorkerRegistry,
      Norns.Workers.TaskQueue,
      NornsWeb.Telemetry,
      NornsWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Norns.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        Norns.Tools.Registry.init()
        Norns.Tools.Registry.register(Norns.Tools.WebSearch)
        Norns.Tools.Registry.register(Norns.Tools.Http)
        Norns.Tools.Registry.register(Norns.Tools.Shell)
        Norns.Workers.ResumeAgents.resume_orphans()
        result

      other ->
        other
    end
  end
end
