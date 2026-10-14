defmodule Norns.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    warn_if_unclustered_multi_node()

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

  # Norns is a single-node deployment. Node.list() is the only signal
  # available: mix.exs has no libcluster and no Horde, so nothing here
  # forms, verifies, or even names a cluster. If this node can already see
  # others, something outside this app (an operator, a deploy tool)
  # connected them, and that is unsupported — Norns.Workers.WorkerRegistry
  # and Norns.Workers.TaskQueue both keep their state in plain GenServer
  # process state, keyed with no node identity at all. Two connected nodes
  # each run their own, independent copies: a worker registered on one is
  # invisible to dispatch on the other, and GET /api/v1/workers only ever
  # answers for the node that served the request. Multi-node is planned;
  # the port is to libcluster + Horde (nornscode/norns#17;
  # docs/roadmap.md "Multi-node / Horde clustering"; docs/decision-log.md
  # "## Open" > "Multi-node"). A single node with no peers (the deployed
  # default: the operator holds the machine count at 1 via `fly scale
  # count 1`) never hits this branch.
  defp warn_if_unclustered_multi_node do
    case Node.list() do
      [] ->
        :ok

      peers ->
        Logger.warning("""
        Norns is single-node: this build has no clustering (no \
        libcluster, no Horde), and WorkerRegistry and TaskQueue are \
        node-local. This node (#{inspect(Node.self())}) can see other \
        connected nodes (#{inspect(peers)}), which means two independent, \
        unsynchronised copies of worker dispatch and the task queue are \
        now running. Workers registered on one node are invisible to the \
        other, and GET /api/v1/workers only reports the node that served \
        the request. Multi-node support is planned (nornscode/norns#17; \
        docs/roadmap.md "Multi-node / Horde clustering"). Run one node \
        until it lands.
        """)
    end
  end
end
