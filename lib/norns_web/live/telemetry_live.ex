defmodule NornsWeb.TelemetryLive do
  use NornsWeb, :live_view

  alias Norns.TelemetryEvents

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        events = TelemetryEvents.list_events()
        total = TelemetryEvents.count()
        by_source = TelemetryEvents.count_by_source()

        {:ok,
         assign(socket,
           current_tenant: tenant,
           events: events,
           total: total,
           by_source: by_source
         )}

      :error ->
        {:ok, push_navigate(assign(socket, current_tenant: nil), to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="text-xl font-bold text-gray-900 dark:text-white mb-6">Telemetry</h1>

    <div class="grid grid-cols-3 gap-4 mb-6">
      <div class="bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded p-3">
        <div class="text-xs text-gray-500">Total Events</div>
        <div class="text-lg font-bold"><%= @total %></div>
      </div>
      <%= for entry <- @by_source do %>
        <div class="bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded p-3">
          <div class="text-xs text-gray-500"><%= entry.source %></div>
          <div class="text-lg font-bold"><%= entry.count %></div>
        </div>
      <% end %>
    </div>

    <h2 class="text-sm font-bold text-gray-600 dark:text-gray-400 mb-2">Recent Events</h2>
    <%= if @events == [] do %>
      <p class="text-xs text-gray-500">No telemetry events recorded yet.</p>
    <% else %>
      <div class="space-y-1">
        <%= for event <- @events do %>
          <div class="flex items-center justify-between bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded px-4 py-2">
            <div class="flex items-center gap-4">
              <span class="text-xs text-gray-500 dark:text-gray-600 w-8 text-right"><%= event.id %></span>
              <span class="text-sm text-gray-900 dark:text-white"><%= event.source %></span>
              <span class="text-xs text-gray-500"><%= event.version %></span>
            </div>
            <span class="text-xs text-gray-400 dark:text-gray-700"><%= format_time(event.inserted_at) %></span>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp format_time(nil), do: ""
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
