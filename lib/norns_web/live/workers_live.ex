defmodule NornsWeb.WorkersLive do
  @moduledoc """
  Every worker holding a connection to this node for the current tenant.

  This is the liveness half of the deployment picture. A container can be
  "running" and still absent here — crash-looping, or unable to reach Norns.
  The list is read from `WorkerRegistry` on every refresh, so it is the same
  answer `GET /api/v1/workers` gives.
  """

  use NornsWeb, :live_view

  alias Norns.Workers.WorkerRegistry

  @refresh_ms 5_000

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
        {:ok, assign(socket, tenant: tenant, current_tenant: tenant) |> load_workers()}

      :error ->
        {:ok, assign(socket, tenant: nil, current_tenant: nil, workers: [])}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_workers(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_workers(socket)}
  end

  defp load_workers(%{assigns: %{tenant: tenant}} = socket) do
    workers =
      tenant.id
      |> WorkerRegistry.connected_workers()
      |> Enum.sort_by(& &1.worker_id)

    assign(socket, workers: workers)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @tenant == nil do %>
      <div class="mt-20 text-center text-gray-500">
        <p class="text-lg mb-2">Not authenticated</p>
        <p class="text-sm">Append <code class="text-gray-600 dark:text-gray-400">?token=your-api-key</code> to the URL</p>
      </div>
    <% else %>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-xl font-bold text-gray-900 dark:text-white">Workers</h1>
        <button phx-click="refresh" class="text-xs text-gray-500 hover:text-gray-700 dark:hover:text-gray-300">refresh</button>
      </div>

      <%= if @workers == [] do %>
        <p class="text-xs text-gray-500 dark:text-gray-600">
          No workers connected. A worker registers over the <code class="text-gray-600 dark:text-gray-400">/worker</code>
          socket and shows up here while its connection is open.
        </p>
      <% else %>
        <div class="space-y-2">
          <%= for worker <- @workers do %>
            <div id={"worker-#{worker.worker_id}"} class="bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded px-4 py-3">
              <div class="flex items-center gap-3">
                <span class={if worker.draining, do: "text-yellow-600", else: "text-green-600"}>●</span>
                <span class="text-sm text-gray-900 dark:text-white"><%= worker.worker_id %></span>
                <span class="text-xs text-gray-500"><%= if worker.draining, do: "draining", else: "ready" %></span>
                <%= for cap <- worker.capabilities do %>
                  <span class="text-xs px-1.5 py-0.5 rounded bg-gray-200 dark:bg-gray-800 text-gray-600 dark:text-gray-400"><%= cap %></span>
                <% end %>
                <%= if worker.serverless do %>
                  <span class="text-xs px-1.5 py-0.5 rounded bg-purple-100 dark:bg-purple-900/40 text-purple-700 dark:text-purple-400">serverless</span>
                <% end %>
                <%= if worker.gard do %>
                  <a href="/gards" class="text-xs text-blue-700 dark:text-blue-500 hover:underline">gard <%= worker.gard %></a>
                <% end %>
                <span class="text-xs text-gray-500 ml-auto">
                  connected <.local_time id={"worker-#{worker.worker_id}-at"} at={worker.connected_at} format="time" />
                </span>
              </div>

              <div class="mt-2 text-xs text-gray-600 dark:text-gray-400 pl-6">
                <%= if worker.tools == [] do %>
                  no tools
                <% else %>
                  <%= worker.tool_count %> <%= if worker.tool_count == 1, do: "tool", else: "tools" %>:
                  <%= Enum.join(worker.tools, ", ") %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    <% end %>
    """
  end

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
