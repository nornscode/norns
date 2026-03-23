defmodule NornsWeb.AgentsLive do
  use NornsWeb, :live_view

  alias Norns.Agents
  alias Norns.Agents.Registry

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        agents = Agents.list_agents(tenant.id)

        if connected?(socket) do
          Enum.each(agents, fn a ->
            Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{a.id}")
          end)
        end

        {:ok,
         assign(socket,
           tenant: tenant,
           current_tenant: tenant,
           agents: agents,
           agent_states: build_states(agents, tenant),
           show_create: false,
           create_error: nil
         )}

      :error ->
        {:ok,
         assign(socket,
           tenant: nil,
           current_tenant: nil,
           agents: [],
           agent_states: %{},
           show_create: false,
           create_error: nil
         )}
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
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-xl font-bold text-white">Agents</h1>
        <div class="flex items-center gap-3">
          <span class="text-xs text-gray-600"><%= length(@agents) %> agents</span>
          <button phx-click="toggle_create"
            class="text-xs text-blue-400 hover:text-blue-300 border border-blue-900 px-2 py-1 rounded">
            + new agent
          </button>
        </div>
      </div>

      <%!-- Create agent form --%>
      <%= if @show_create do %>
        <div class="bg-gray-900 border border-gray-800 rounded p-4 mb-4">
          <%= if @create_error do %>
            <div class="bg-red-900/30 border border-red-800 text-red-300 px-3 py-1.5 rounded mb-3 text-xs">
              <%= @create_error %>
            </div>
          <% end %>
          <form phx-submit="create_agent" class="space-y-3">
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="text-xs text-gray-500 block mb-1">Name</label>
                <input type="text" name="name" required placeholder="my-agent"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-gray-500" />
              </div>
              <div>
                <label class="text-xs text-gray-500 block mb-1">Model</label>
                <input type="text" name="model" value="claude-sonnet-4-20250514" placeholder="claude-sonnet-4-20250514"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-gray-500" />
              </div>
            </div>
            <div>
              <label class="text-xs text-gray-500 block mb-1">System prompt</label>
              <textarea name="system_prompt" rows="3" required placeholder="You are a helpful assistant."
                class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-gray-500"></textarea>
            </div>
            <div class="flex items-center gap-2">
              <button type="submit"
                class="text-xs bg-white text-gray-950 font-medium px-3 py-1.5 rounded hover:bg-gray-200">
                Create
              </button>
              <button type="button" phx-click="toggle_create"
                class="text-xs text-gray-500 hover:text-gray-400 px-3 py-1.5">
                Cancel
              </button>
            </div>
          </form>
        </div>
      <% end %>

      <%!-- Agent list --%>
      <%= if @agents == [] and not @show_create do %>
        <p class="text-gray-500 text-sm">No agents yet. Click "+ new agent" to create one.</p>
      <% else %>
        <div class="space-y-2">
          <%= for agent <- @agents do %>
            <% state = Map.get(@agent_states, agent.id) %>
            <div class="flex items-center justify-between bg-gray-900 border border-gray-800 rounded px-4 py-3">
              <div class="flex items-center gap-3">
                <span class={["w-2 h-2 rounded-full", status_color(state)]}>
                </span>
                <a href={"/agents/#{agent.id}"} class="text-white hover:text-blue-400">
                  <%= agent.name %>
                </a>
                <span class="text-xs text-gray-600"><%= agent.model %></span>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-xs text-gray-500">
                  <%= if state && state.status == :running, do: "step #{state.step}", else: agent.status %>
                </span>
                <%= if state && state.status != :stopped do %>
                  <button phx-click="stop" phx-value-id={agent.id}
                    class="text-xs text-red-400 hover:text-red-300 border border-red-900 px-2 py-1 rounded">
                    stop
                  </button>
                <% else %>
                  <button phx-click="start" phx-value-id={agent.id}
                    class="text-xs text-green-400 hover:text-green-300 border border-green-900 px-2 py-1 rounded">
                    start
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    <% end %>
    """
  end

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply, assign(socket, show_create: !socket.assigns.show_create, create_error: nil)}
  end

  def handle_event("create_agent", params, socket) do
    tenant = socket.assigns.tenant

    attrs = %{
      tenant_id: tenant.id,
      name: String.trim(params["name"] || ""),
      system_prompt: String.trim(params["system_prompt"] || ""),
      model: String.trim(params["model"] || "claude-sonnet-4-20250514"),
      status: "idle"
    }

    case Agents.create_agent(attrs) do
      {:ok, _agent} ->
        {:noreply, socket |> assign(show_create: false, create_error: nil) |> refresh()}

      {:error, changeset} ->
        error =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
          |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

        {:noreply, assign(socket, create_error: error)}
    end
  end

  def handle_event("start", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    tenant = socket.assigns.tenant
    tools = Norns.Tools.Registry.all_tools()
    Registry.start_agent(agent_id, tenant.id, tools: tools)
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent_id}")
    {:noreply, refresh(socket)}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    Registry.stop_agent(socket.assigns.tenant.id, agent_id)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:agent_started, :completed, :error, :agent_resumed] do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    agents = Agents.list_agents(socket.assigns.tenant.id)
    assign(socket, agents: agents, agent_states: build_states(agents, socket.assigns.tenant))
  end

  defp build_states(agents, tenant) do
    Map.new(agents, fn agent ->
      state =
        case Registry.lookup(tenant.id, agent.id) do
          {:ok, pid} ->
            try do
              Agents.Process.get_state(pid)
            catch
              :exit, _ -> %{status: :running, step: "?"}
            end
          :error -> %{status: :stopped, step: 0}
        end

      {agent.id, state}
    end)
  end

  defp status_color(%{status: :running}), do: "bg-green-400 animate-pulse-dot"
  defp status_color(%{status: :idle}), do: "bg-blue-400"
  defp status_color(_), do: "bg-gray-600"

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
