defmodule NornsWeb.AgentLive do
  use NornsWeb, :live_view

  alias Norns.{Agents, Runs}
  alias Norns.Agents.Registry

  @impl true
  def mount(%{"id" => id}, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        agent = Agents.get_agent!(id)

        if agent.tenant_id != tenant.id do
          {:ok, push_navigate(socket, to: "/")}
        else
          if connected?(socket) do
            Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
          end

          runs = Runs.list_runs(agent.id)
          state = get_process_state(tenant.id, agent.id)

          config = agent.model_config || %{}

          {:ok,
           assign(socket,
             tenant: tenant,
             current_tenant: tenant,
             agent: agent,
             runs: runs,
             state: state,
             events: [],
             message: "",
             editing_config: false,
             config: config
           )}
        end

      :error ->
        {:ok, push_navigate(assign(socket, current_tenant: nil), to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-6">
      <a href="/" class="text-xs text-gray-500 hover:text-gray-400">&larr; agents</a>
    </div>

    <div class="flex items-center gap-3 mb-6">
      <span class={["w-2.5 h-2.5 rounded-full", status_color(@state)]}></span>
      <h1 class="text-xl font-bold text-white"><%= @agent.name %></h1>
      <span class="text-xs text-gray-500"><%= @agent.model %></span>
    </div>

    <%!-- Agent info --%>
    <div class="grid grid-cols-2 gap-4 mb-6">
      <div class="bg-gray-900 border border-gray-800 rounded p-4">
        <div class="text-xs text-gray-500 mb-1">System Prompt</div>
        <div class="text-sm text-gray-300 whitespace-pre-wrap"><%= @agent.system_prompt %></div>
      </div>
      <div class="bg-gray-900 border border-gray-800 rounded p-4 space-y-2">
        <div>
          <span class="text-xs text-gray-500">Status:</span>
          <span class="text-sm ml-1"><%= if @state, do: @state.status, else: "stopped" %></span>
        </div>
        <div>
          <span class="text-xs text-gray-500">Step:</span>
          <span class="text-sm ml-1"><%= if @state, do: @state.step, else: "-" %></span>
        </div>
        <div>
          <span class="text-xs text-gray-500">Max Steps:</span>
          <span class="text-sm ml-1"><%= @agent.max_steps %></span>
        </div>
      </div>
    </div>

    <%!-- Config --%>
    <div class="bg-gray-900 border border-gray-800 rounded p-4 mb-6">
      <div class="flex items-center justify-between mb-3">
        <span class="text-xs text-gray-500 font-medium">Configuration</span>
        <button phx-click="toggle_config_edit" class="text-xs text-gray-500 hover:text-gray-400">
          <%= if @editing_config, do: "cancel", else: "edit" %>
        </button>
      </div>

      <%= if @editing_config do %>
        <form phx-submit="save_config" class="space-y-3">
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="text-xs text-gray-500 block mb-1">Model</label>
              <input type="text" name="model" value={@agent.model}
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-gray-500" />
            </div>
            <div>
              <label class="text-xs text-gray-500 block mb-1">Max Steps</label>
              <input type="number" name="max_steps" value={@agent.max_steps}
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-gray-500" />
            </div>
            <div>
              <label class="text-xs text-gray-500 block mb-1">On Failure</label>
              <select name="on_failure"
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-gray-500">
                <option value="stop" selected={@config["on_failure"] != "retry_last_step"}>stop</option>
                <option value="retry_last_step" selected={@config["on_failure"] == "retry_last_step"}>retry_last_step</option>
              </select>
            </div>
            <div>
              <label class="text-xs text-gray-500 block mb-1">Mode</label>
              <select name="mode"
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-gray-500">
                <option value="task" selected={@config["mode"] != "conversation"}>task</option>
                <option value="conversation" selected={@config["mode"] == "conversation"}>conversation</option>
              </select>
            </div>
            <div>
              <label class="text-xs text-gray-500 block mb-1">Checkpoint Policy</label>
              <select name="checkpoint_policy"
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-gray-500">
                <option value="on_tool_call" selected={@config["checkpoint_policy"] not in ["every_step", "manual"]}>on_tool_call</option>
                <option value="every_step" selected={@config["checkpoint_policy"] == "every_step"}>every_step</option>
                <option value="manual" selected={@config["checkpoint_policy"] == "manual"}>manual</option>
              </select>
            </div>
            <div>
              <label class="text-xs text-gray-500 block mb-1">Context Window</label>
              <input type="number" name="context_window" value={@config["context_window"] || 20}
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-gray-500" />
            </div>
          </div>
          <button type="submit" class="text-xs bg-white text-gray-950 font-medium px-3 py-1.5 rounded hover:bg-gray-200">
            Save
          </button>
        </form>
      <% else %>
        <div class="grid grid-cols-3 gap-x-6 gap-y-1 text-sm">
          <div>
            <span class="text-gray-500">Model:</span>
            <span class="text-gray-300 ml-1"><%= @agent.model %></span>
          </div>
          <div>
            <span class="text-gray-500">On Failure:</span>
            <span class="text-gray-300 ml-1"><%= @config["on_failure"] || "stop" %></span>
          </div>
          <div>
            <span class="text-gray-500">Mode:</span>
            <span class="text-gray-300 ml-1"><%= @config["mode"] || "task" %></span>
          </div>
          <div>
            <span class="text-gray-500">Checkpoint:</span>
            <span class="text-gray-300 ml-1"><%= @config["checkpoint_policy"] || "on_tool_call" %></span>
          </div>
          <div>
            <span class="text-gray-500">Context Window:</span>
            <span class="text-gray-300 ml-1"><%= @config["context_window"] || 20 %></span>
          </div>
          <div>
            <span class="text-gray-500">Max Steps:</span>
            <span class="text-gray-300 ml-1"><%= @agent.max_steps %></span>
          </div>
        </div>
      <% end %>
    </div>

    <%!-- Controls --%>
    <div class="flex items-center gap-3 mb-6">
      <form phx-submit="send_message" class="flex items-center gap-2 flex-1">
        <input type="text" name="content" value={@message} placeholder="Send a message..."
          class="flex-1 bg-gray-900 border border-gray-700 rounded px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-gray-500" />
        <button type="submit" class="text-xs text-blue-400 hover:text-blue-300 border border-blue-900 px-3 py-1.5 rounded">
          send
        </button>
      </form>
    </div>

    <%!-- Live events --%>
    <%= if @events != [] do %>
      <div class="mb-6">
        <h2 class="text-sm font-bold text-gray-400 mb-2">Live Events</h2>
        <div class="space-y-1 max-h-60 overflow-y-auto">
          <%= for event <- Enum.reverse(@events) do %>
            <div class="text-xs text-gray-400 bg-gray-900 border border-gray-800 rounded px-3 py-1.5">
              <span class={event_color(event.type)}><%= event.type %></span>
              <span class="text-gray-600 ml-2"><%= event.detail %></span>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <%!-- Runs --%>
    <h2 class="text-sm font-bold text-gray-400 mb-2">Runs</h2>
    <%= if @runs == [] do %>
      <p class="text-gray-600 text-xs">No runs yet.</p>
    <% else %>
      <div class="space-y-4">
        <%= for {conv_id, runs} <- group_runs_by_conversation(@runs) do %>
          <%= if conv_id do %>
            <div class="text-xs text-gray-600 mt-1">conversation #<%= conv_id %></div>
          <% end %>
          <div class="space-y-1">
            <%= for run <- runs do %>
              <a href={"/runs/#{run.id}"} class="flex items-center justify-between bg-gray-900 border border-gray-800 rounded px-4 py-2 hover:border-gray-700">
                <div class="flex items-center gap-3 min-w-0">
                  <span class={["w-1.5 h-1.5 rounded-full shrink-0", run_status_color(run.status)]}></span>
                  <span class="text-xs text-gray-400 shrink-0">Run #<%= run.id %></span>
                  <span class="text-xs text-gray-600 shrink-0"><%= run.status %></span>
                  <%= if preview = run_input_preview(run) do %>
                    <span class="text-xs text-gray-500 truncate"><%= preview %></span>
                  <% end %>
                </div>
                <span class="text-xs text-gray-600 shrink-0 ml-3"><%= format_time(run.inserted_at) %></span>
              </a>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  @impl true
  def handle_event("toggle_config_edit", _params, socket) do
    {:noreply, assign(socket, editing_config: !socket.assigns.editing_config)}
  end

  def handle_event("save_config", params, socket) do
    agent = socket.assigns.agent

    config =
      (agent.model_config || %{})
      |> Map.merge(%{
        "on_failure" => params["on_failure"],
        "mode" => params["mode"],
        "checkpoint_policy" => params["checkpoint_policy"],
        "context_window" => params["context_window"]
      })

    max_steps =
      case Integer.parse(params["max_steps"] || "") do
        {n, ""} when n > 0 -> n
        _ -> agent.max_steps
      end

    case Agents.update_agent(agent, %{
           model: String.trim(params["model"] || agent.model),
           max_steps: max_steps,
           model_config: config
         }) do
      {:ok, updated_agent} ->
        {:noreply,
         assign(socket,
           agent: updated_agent,
           config: updated_agent.model_config || %{},
           editing_config: false
         )
         |> put_flash(:info, "Configuration saved")}

      {:error, _changeset} ->
        {:noreply, socket |> put_flash(:error, "Failed to save configuration")}
    end
  end

  def handle_event("send_message", %{"content" => content}, socket) when content != "" do
    agent = socket.assigns.agent
    tenant = socket.assigns.tenant

    case Registry.send_message(tenant.id, agent.id, content) do
      {:ok, run_id} ->
        events = [%{type: "message_sent", detail: "run ##{run_id}: #{String.slice(content, 0, 60)}"} | socket.assigns.events]
        {:noreply, assign(socket, message: "", events: events, state: %{status: :running, step: 0})}

      {:error, :busy} ->
        {:noreply, socket |> put_flash(:error, "Agent is busy")}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Error: #{inspect(reason)}")}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:agent_started, %{run_id: run_id}}, socket) do
    events = [%{type: "agent_started", detail: "run ##{run_id}"} | socket.assigns.events]
    runs = Runs.list_runs(socket.assigns.agent.id)
    state = get_process_state(socket.assigns.tenant.id, socket.assigns.agent.id)
    {:noreply, assign(socket, events: events, runs: runs, state: state)}
  end

  def handle_info({:llm_response, %{stop_reason: sr, step: step}}, socket) do
    events = [%{type: "llm_response", detail: "step #{step}, #{sr}"} | socket.assigns.events]
    state = get_process_state(socket.assigns.tenant.id, socket.assigns.agent.id)
    {:noreply, assign(socket, events: events, state: state)}
  end

  def handle_info({:tool_call, %{name: name}}, socket) do
    events = [%{type: "tool_call", detail: name} | socket.assigns.events]
    {:noreply, assign(socket, events: events)}
  end

  def handle_info({:tool_result, %{tool_use_id: id, content: content}}, socket) do
    preview = String.slice(content || "", 0, 60)
    events = [%{type: "tool_result", detail: "#{id}: #{preview}"} | socket.assigns.events]
    {:noreply, assign(socket, events: events)}
  end

  def handle_info({:completed, %{output: output}}, socket) do
    preview = String.slice(output || "", 0, 80)
    events = [%{type: "completed", detail: preview} | socket.assigns.events]
    runs = Runs.list_runs(socket.assigns.agent.id)
    state = get_process_state(socket.assigns.tenant.id, socket.assigns.agent.id)
    {:noreply, assign(socket, events: events, runs: runs, state: state)}
  end


  def handle_info({:error, %{error: reason}}, socket) do
    events = [%{type: "error", detail: String.slice(reason, 0, 100)} | socket.assigns.events]
    state = get_process_state(socket.assigns.tenant.id, socket.assigns.agent.id)
    {:noreply, assign(socket, events: events, state: state)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp get_process_state(tenant_id, agent_id) do
    case Registry.lookup(tenant_id, agent_id) do
      {:ok, pid} ->
        try do
          Agents.Process.get_state(pid)
        catch
          :exit, _ -> %{status: :running, step: "?"}
        end

      :error ->
        %{status: :stopped, step: 0}
    end
  end

  defp status_color(%{status: :running}), do: "bg-green-400 animate-pulse-dot"
  defp status_color(%{status: :waiting_timer}), do: "bg-yellow-400 animate-pulse-dot"
  defp status_color(%{status: :idle}), do: "bg-blue-400"
  defp status_color(_), do: "bg-gray-600"

  defp run_status_color("completed"), do: "bg-green-400"
  defp run_status_color("running"), do: "bg-blue-400 animate-pulse-dot"
  defp run_status_color("failed"), do: "bg-red-400"
  defp run_status_color(_), do: "bg-gray-600"

  defp event_color(%{type: "message_sent"}), do: "text-white"
  defp event_color(%{type: "waiting_timer"}), do: "text-yellow-400"
  defp event_color(%{type: "tool_call"}), do: "text-yellow-400"
  defp event_color(%{type: "tool_result"}), do: "text-yellow-300"
  defp event_color(%{type: "llm_response"}), do: "text-blue-400"
  defp event_color(%{type: "completed"}), do: "text-green-400"
  defp event_color(%{type: "error"}), do: "text-red-400"
  defp event_color(_), do: "text-gray-400"

  defp run_input_preview(%{input: %{"user_message" => msg}}) when is_binary(msg) and msg != "" do
    String.slice(msg, 0, 80)
  end

  defp run_input_preview(_), do: nil

  defp group_runs_by_conversation(runs) do
    runs
    |> Enum.group_by(& &1.conversation_id)
    |> Enum.sort_by(fn {_conv_id, runs} -> hd(runs).inserted_at end, {:desc, DateTime})
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
