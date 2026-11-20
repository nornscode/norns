defmodule NornsWeb.RunsLive do
  @moduledoc """
  The tenant's runs across every agent, newest first.

  Filters live in the query string (`?agent_id=…&status=…`) so a filtered
  view can be linked to and survives a reload. Reads the same query as
  `GET /api/v1/runs`.
  """

  use NornsWeb, :live_view

  alias Norns.{Agents, Runs}

  @refresh_ms 5_000
  @limit 100
  @statuses ~w(pending running waiting completed failed)

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

        {:ok,
         assign(socket,
           tenant: tenant,
           current_tenant: tenant,
           agents: Agents.list_agents(tenant.id),
           agent_id: nil,
           status: nil,
           runs: []
         )}

      :error ->
        {:ok, assign(socket, tenant: nil, current_tenant: nil)}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{tenant: nil}} = socket), do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(agent_id: parse_id(params["agent_id"]), status: parse_status(params["status"]))
      |> load_runs()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      %{"agent_id" => params["agent_id"], "status" => params["status"]}
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    path = if query == [], do: "/runs", else: "/runs?" <> URI.encode_query(query)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_runs(socket)}

  defp load_runs(%{assigns: assigns} = socket) do
    runs =
      Runs.list_runs_for_tenant(assigns.tenant.id,
        limit: @limit,
        agent_id: assigns.agent_id,
        status: assigns.status,
        preload: [:agent]
      )

    assign(socket, runs: runs)
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
        <h1 class="text-xl font-bold text-gray-900 dark:text-white">Runs</h1>
        <form id="runs-filter" phx-change="filter" class="flex items-center gap-2">
          <select name="agent_id"
            class="bg-white dark:bg-gray-950 border border-gray-300 dark:border-gray-700 rounded px-2 py-1 text-xs text-gray-900 dark:text-white focus:outline-none focus:border-gray-500">
            <option value="">all agents</option>
            <option :for={agent <- @agents} value={agent.id} selected={agent.id == @agent_id}><%= agent.name %></option>
          </select>
          <select name="status"
            class="bg-white dark:bg-gray-950 border border-gray-300 dark:border-gray-700 rounded px-2 py-1 text-xs text-gray-900 dark:text-white focus:outline-none focus:border-gray-500">
            <option value="">any status</option>
            <option :for={status <- statuses()} value={status} selected={status == @status}><%= status %></option>
          </select>
        </form>
      </div>

      <%= if @runs == [] do %>
        <p class="text-xs text-gray-500 dark:text-gray-600">No runs match.</p>
      <% else %>
        <div class="space-y-1">
          <a :for={run <- @runs} id={"run-#{run.id}"} href={"/runs/#{run.id}"}
            class="flex items-center justify-between bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded px-4 py-2 hover:border-gray-300 dark:hover:border-gray-700">
            <div class="flex items-center gap-3 min-w-0">
              <span class={["w-1.5 h-1.5 rounded-full shrink-0", status_color(run.status)]}></span>
              <span class="text-xs text-gray-600 dark:text-gray-400 shrink-0">Run #<%= run.id %></span>
              <span class="text-xs text-gray-900 dark:text-gray-200 shrink-0"><%= agent_name(run) %></span>
              <span class="text-xs text-gray-500 dark:text-gray-600 shrink-0"><%= run.status %></span>
              <span class="text-xs text-gray-500 dark:text-gray-600 shrink-0"><%= run.trigger_type %></span>
              <%= if preview = input_preview(run) do %>
                <span class="text-xs text-gray-500 truncate"><%= preview %></span>
              <% end %>
            </div>
            <.local_time id={"run-#{run.id}-at"} at={run.inserted_at} class="text-xs text-gray-500 dark:text-gray-600 shrink-0 ml-3" />
          </a>
        </div>
        <p :if={length(@runs) == limit()} class="text-xs text-gray-500 dark:text-gray-600 mt-3">
          Showing the newest <%= limit() %>.
        </p>
      <% end %>
    <% end %>
    """
  end

  defp statuses, do: @statuses
  defp limit, do: @limit

  defp parse_id(nil), do: nil

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_status(status) when status in @statuses, do: status
  defp parse_status(_), do: nil

  defp agent_name(%{agent: %{name: name}}), do: name
  defp agent_name(run), do: "agent ##{run.agent_id}"

  defp status_color("completed"), do: "bg-green-400"
  defp status_color("running"), do: "bg-blue-400 animate-pulse-dot"
  defp status_color("waiting"), do: "bg-amber-500 animate-pulse-dot"
  defp status_color("failed"), do: "bg-red-400"
  defp status_color(_), do: "bg-gray-400 dark:bg-gray-600"

  defp input_preview(%{input: %{"user_message" => msg}}) when is_binary(msg) and msg != "" do
    String.slice(msg, 0, 80)
  end

  defp input_preview(_), do: nil

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
