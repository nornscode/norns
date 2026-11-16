defmodule NornsWeb.RunsLive do
  @moduledoc """
  Every run of the tenant, across agents, newest first.

  Filters and page live in the URL (`?status=…&agent=…&page=…`) so a view
  can be linked. The page reloads when any of the tenant's agents starts,
  pauses or ends a run — the same per-agent PubSub topics `AgentsLive`
  listens on.
  """

  use NornsWeb, :live_view

  alias Norns.{Agents, Runs}

  @per_page 50

  # Filter value => the run statuses it selects. "running" means in progress,
  # so it includes runs not yet picked up.
  @status_filters [
    {"all", nil},
    {"running", ["pending", "running"]},
    {"waiting", ["waiting"]},
    {"completed", ["completed"]},
    {"failed", ["failed"]}
  ]

  @refresh_events [
    :agent_started,
    :agent_resumed,
    :waiting_for_user,
    :waiting_timer,
    :completed,
    :error
  ]

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        {:ok,
         assign(socket,
           tenant: tenant,
           current_tenant: tenant,
           agents: [],
           subscribed: MapSet.new(),
           status: "all",
           agent_id: nil,
           page: 1,
           runs: [],
           has_next: false,
           now: DateTime.utc_now()
         )}

      :error ->
        {:ok, push_navigate(assign(socket, current_tenant: nil), to: "/")}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{current_tenant: nil}} = socket),
    do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    socket =
      assign(socket,
        status: parse_status(params["status"]),
        agent_id: parse_int(params["agent"]),
        page: parse_int(params["page"]) || 1
      )

    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to: runs_path(%{status: params["status"], agent_id: parse_int(params["agent"]), page: 1})
     )}
  end

  @impl true
  def handle_info({event, _payload}, socket) when event in @refresh_events do
    {:noreply, load(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load(%{assigns: %{tenant: tenant}} = socket) do
    agents = Agents.list_agents(tenant.id)

    %{runs: runs, has_next: has_next} =
      Runs.page_runs_for_tenant(tenant.id,
        status: status_values(socket.assigns.status),
        agent_id: socket.assigns.agent_id,
        page: socket.assigns.page,
        per_page: @per_page
      )

    socket
    |> assign(agents: agents, runs: runs, has_next: has_next, now: DateTime.utc_now())
    |> subscribe(agents)
  end

  # Agents created after mount are picked up on the next load.
  defp subscribe(socket, agents) do
    if connected?(socket) do
      new_ids =
        agents
        |> Enum.map(& &1.id)
        |> Enum.reject(&MapSet.member?(socket.assigns.subscribed, &1))

      Enum.each(new_ids, &Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{&1}"))
      assign(socket, subscribed: MapSet.union(socket.assigns.subscribed, MapSet.new(new_ids)))
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :status_filters, Enum.map(@status_filters, &elem(&1, 0)))

    ~H"""
    <div class="flex items-center justify-between mb-6">
      <h1 class="text-xl font-bold text-gray-900 dark:text-white">Runs</h1>
      <form id="runs-filter" phx-change="filter" class="flex items-center gap-3">
        <label class="text-xs text-gray-500">
          status
          <select name="status"
            class="ml-1 bg-gray-50 dark:bg-gray-900 border border-gray-300 dark:border-gray-700 rounded px-2 py-1 text-xs text-gray-900 dark:text-white focus:outline-none focus:border-gray-500">
            <option :for={s <- @status_filters} value={s} selected={s == @status}><%= s %></option>
          </select>
        </label>
        <label class="text-xs text-gray-500">
          agent
          <select name="agent"
            class="ml-1 bg-gray-50 dark:bg-gray-900 border border-gray-300 dark:border-gray-700 rounded px-2 py-1 text-xs text-gray-900 dark:text-white focus:outline-none focus:border-gray-500">
            <option value="" selected={is_nil(@agent_id)}>all</option>
            <option :for={a <- @agents} value={a.id} selected={a.id == @agent_id}><%= a.name %></option>
          </select>
        </label>
      </form>
    </div>

    <%= if @runs == [] do %>
      <p class="text-gray-500 dark:text-gray-600 text-xs">No runs<%= if @page > 1, do: " on this page" %>.</p>
    <% else %>
      <div class="overflow-x-auto">
        <table id="runs" class="w-full text-xs">
          <thead>
            <tr class="text-left text-gray-500 border-b border-gray-200 dark:border-gray-800">
              <th class="py-2 pr-4 font-medium">Run</th>
              <th class="py-2 pr-4 font-medium">Agent</th>
              <th class="py-2 pr-4 font-medium">Status</th>
              <th class="py-2 pr-4 font-medium">Trigger</th>
              <th class="py-2 pr-4 font-medium">Conversation</th>
              <th class="py-2 pr-4 font-medium">Started</th>
              <th class="py-2 pr-4 font-medium">Finished</th>
              <th class="py-2 font-medium">Duration</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} id={"run-#{run.id}"} class="border-b border-gray-100 dark:border-gray-900 hover:bg-gray-50 dark:hover:bg-gray-900">
              <td class="py-2 pr-4">
                <a href={"/runs/#{run.id}"} class="text-gray-900 dark:text-white hover:text-blue-600 dark:hover:text-blue-400">#<%= run.id %></a>
                <%= if run.parent_run_id do %>
                  <span class="text-gray-500 ml-1" title={"launched by run ##{run.parent_run_id}"}>&uarr;#<%= run.parent_run_id %></span>
                <% end %>
              </td>
              <td class="py-2 pr-4">
                <a href={"/agents/#{run.agent_id}"} class="text-gray-600 dark:text-gray-400 hover:text-blue-600 dark:hover:text-blue-400"><%= run.agent.name %></a>
              </td>
              <td class="py-2 pr-4">
                <span class="inline-flex items-center gap-1.5">
                  <span class={["w-1.5 h-1.5 rounded-full", run_status_color(run.status)]}></span>
                  <span class="text-gray-600 dark:text-gray-400"><%= run.status %></span>
                </span>
              </td>
              <td class="py-2 pr-4 text-gray-500"><%= run.trigger_type %></td>
              <td class="py-2 pr-4 text-gray-500 max-w-[12rem] truncate"><%= conversation_label(run.conversation) %></td>
              <td class="py-2 pr-4 text-gray-500 whitespace-nowrap">
                <.local_time id={"run-#{run.id}-started"} at={run.inserted_at} />
              </td>
              <td class="py-2 pr-4 text-gray-500 whitespace-nowrap">
                <.local_time id={"run-#{run.id}-finished"} at={finished_at(run)} />
              </td>
              <td class="py-2 text-gray-500 whitespace-nowrap"><%= duration(run, @now) %></td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>

    <div :if={@page > 1 or @has_next} class="flex items-center justify-between mt-4 text-xs">
      <span>
        <.link :if={@page > 1} patch={runs_path(%{status: @status, agent_id: @agent_id, page: @page - 1})}
          class="text-gray-500 hover:text-gray-700 dark:hover:text-gray-400">&larr; newer</.link>
      </span>
      <span class="text-gray-500">page <%= @page %></span>
      <span>
        <.link :if={@has_next} patch={runs_path(%{status: @status, agent_id: @agent_id, page: @page + 1})}
          class="text-gray-500 hover:text-gray-700 dark:hover:text-gray-400">older &rarr;</.link>
      </span>
    </div>
    """
  end

  defp runs_path(%{status: status, agent_id: agent_id, page: page}) do
    query =
      [
        status: if(status in [nil, "", "all"], do: nil, else: status),
        agent: agent_id,
        page: if(page > 1, do: page)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if query == [], do: "/runs", else: "/runs?" <> URI.encode_query(query)
  end

  defp parse_status(status) do
    if List.keymember?(@status_filters, status, 0), do: status, else: "all"
  end

  defp status_values(status) do
    {_, values} = List.keyfind(@status_filters, status, 0, {"all", nil})
    values
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp conversation_label(nil), do: "-"
  defp conversation_label(%{title: title}) when is_binary(title) and title != "", do: title
  defp conversation_label(%{key: key}), do: key

  # Runs carry no finish timestamp of their own. A terminal run's last write
  # is the one that settled its status, so updated_at stands in for it.
  defp finished_at(%{status: status, updated_at: at}) when status in ["completed", "failed"],
    do: at

  defp finished_at(_run), do: nil

  defp duration(run, now) do
    case finished_at(run) do
      nil -> format_duration(DateTime.diff(now, run.inserted_at, :millisecond)) <> " so far"
      at -> format_duration(DateTime.diff(at, run.inserted_at, :millisecond))
    end
  end

  defp format_duration(ms) when ms < 0, do: "-"
  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_duration(ms) when ms < 3_600_000 do
    s = div(ms, 1_000)
    "#{div(s, 60)}m #{rem(s, 60)}s"
  end

  defp format_duration(ms) do
    m = div(ms, 60_000)
    "#{div(m, 60)}h #{rem(m, 60)}m"
  end

  defp run_status_color("completed"), do: "bg-green-400"
  defp run_status_color("running"), do: "bg-blue-400 animate-pulse-dot"
  defp run_status_color("waiting"), do: "bg-yellow-400 animate-pulse-dot"
  defp run_status_color("failed"), do: "bg-red-400"
  defp run_status_color(_), do: "bg-gray-400 dark:bg-gray-600"

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
