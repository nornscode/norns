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
        maybe_create_default_tenant()
        Norns.Workers.ResumeAgents.resume_orphans()
        result

      other ->
        other
    end
  end

  defp maybe_create_default_tenant do
    case System.get_env("NORNS_DEFAULT_TENANT_KEY") do
      nil ->
        :ok

      key when is_binary(key) and key != "" ->
        case Norns.Tenants.get_tenant_by_slug("default") do
          %Norns.Tenants.Tenant{} ->
            :ok

          nil ->
            {:ok, _tenant} =
              Norns.Tenants.create_tenant(%{
                name: "Default",
                slug: "default",
                api_keys: %{"norns" => key}
              })
        end
    end
  end
end
