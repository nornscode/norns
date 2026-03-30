defmodule NornsWeb.ToolsLive do
  use NornsWeb, :live_view

  alias Norns.Tools.Builtins
  alias Norns.Tools.Registry, as: ToolRegistry
  alias Norns.Workers.WorkerRegistry

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        built_in = Builtins.all() ++ ToolRegistry.all_tools()
        worker_tools = WorkerRegistry.available_tools(tenant.id)

        {:ok, assign(socket, tenant: tenant, current_tenant: tenant, built_in: built_in, worker_tools: worker_tools)}

      :error ->
        {:ok, assign(socket, tenant: nil, current_tenant: nil, built_in: [], worker_tools: [])}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @tenant == nil do %>
      <div class="mt-20 text-center text-gray-500">
        <p class="text-lg mb-2">Not authenticated</p>
        <p class="text-sm">Append <code class="text-gray-400">?token=your-api-key</code> to the URL</p>
      </div>
    <% else %>
      <h1 class="text-xl font-bold text-white mb-6">Tools</h1>

      <h2 class="text-sm font-bold text-gray-400 mb-2">Built-in</h2>
      <div class="space-y-1 mb-8">
        <%= for tool <- @built_in do %>
          <div class="flex items-center justify-between bg-gray-900 border border-gray-800 rounded px-4 py-2">
            <div>
              <span class="text-sm text-white"><%= tool.name %></span>
              <span class="text-xs text-gray-500 ml-3"><%= tool.description %></span>
            </div>
            <span class={"text-xs #{if tool.source == :builtin, do: "text-yellow-600", else: "text-green-600"}"}>
              <%= if tool.source == :builtin, do: "builtin", else: "local" %>
            </span>
          </div>
        <% end %>
      </div>

      <h2 class="text-sm font-bold text-gray-400 mb-2">Worker Tools</h2>
      <%= if @worker_tools == [] do %>
        <p class="text-xs text-gray-600">No workers connected.</p>
      <% else %>
        <div class="space-y-1">
          <%= for tool <- @worker_tools do %>
            <div class="flex items-center justify-between bg-gray-900 border border-gray-800 rounded px-4 py-2">
              <div>
                <span class="text-sm text-white"><%= tool.name %></span>
                <span class="text-xs text-gray-500 ml-3"><%= tool.description %></span>
              </div>
              <span class="text-xs text-blue-600">remote</span>
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
