defmodule Norns.Tools.Catalog do
  @moduledoc """
  What tools an agent in a given tenant can actually call right now.

  The tool list an agent is offered is composed from built-ins, the tools an
  agent was handed directly, and the tools advertised by connected workers,
  deduplicated by name. That composition was previously repeated at each call
  site, which meant a page or an API could describe a tool surface that didn't
  match what agents were really given. It lives here instead.

  Worker tools are only real while their worker is connected. A tool that
  vanishes when a container restarts is not the same kind of thing as a
  built-in, so `source` is always reported and callers should treat
  `:worker` as conditional.
  """

  alias Norns.Agents.ToolPolicy
  alias Norns.Tools.Builtins
  alias Norns.Workers.WorkerRegistry

  @doc """
  Tools available to `tenant_id`, deduplicated by name.

  Precedence: built-ins first, then the agent's own, then worker. An earlier
  entry shadows a later one with the same name, so a worker cannot displace a
  built-in.

  Options, all of which narrow the list the way dispatch narrows it:

    * `:extra` — tools handed straight to an agent (its def's own list)
    * `:policy` — a `Norns.Agents.ToolPolicy`; filters `:extra` and worker
      tools, never built-ins, which are orchestrator semantics
    * `:gard` — worker tools from that gard only, by strict equality, since
      the list offered to a model must only name tools dispatch can reach

  With no options this is the tenant-wide view a tools page wants. With all
  three it is exactly what one agent is offered on its next step — and that
  is the point: an agent used to compose this itself, so the page could
  describe a tool surface no agent actually had.
  """
  @spec for_tenant(term(), keyword()) :: [Norns.Tools.Tool.t()]
  def for_tenant(tenant_id, opts \\ []) do
    policy = Keyword.get(opts, :policy, %ToolPolicy{})
    extra = ToolPolicy.filter(policy, Keyword.get(opts, :extra, []))
    worker = ToolPolicy.filter(policy, WorkerRegistry.available_tools(tenant_id, gard: Keyword.get(opts, :gard)))

    (Builtins.all() ++ extra ++ worker)
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  Context a caller needs to interpret an empty or short tool list.

  `workers_connected: 0` means nothing is serving tools *for this tenant*.

  `llm_available` has wider scope on purpose: LLM dispatch falls back to
  `:default`-tenant workers, which serve every tenant, while tool dispatch does
  not. So `workers_connected: 0` alongside `llm_available: true` is coherent,
  not a contradiction — a shared LLM worker can run the agent's reasoning while
  it has no tools of its own to call.
  """
  @spec availability(term()) :: map()
  def availability(tenant_id) do
    workers = WorkerRegistry.connected_workers(tenant_id)

    %{
      workers_connected: length(workers),
      workers: workers,
      llm_available: WorkerRegistry.llm_available?(tenant_id)
    }
  end

  @doc "Normalize a tool's `source` into a stable string for API output."
  @spec source(Norns.Tools.Tool.t()) :: String.t()
  def source(%{source: :builtin}), do: "builtin"
  def source(%{source: {:remote, _}}), do: "worker"
  def source(_), do: "local"
end
