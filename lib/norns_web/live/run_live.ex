defmodule NornsWeb.RunLive do
  use NornsWeb, :live_view

  alias Norns.Runs

  @impl true
  def mount(%{"id" => id}, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        run = Runs.get_run!(id)

        if run.tenant_id != tenant.id do
          {:ok, push_navigate(socket, to: "/")}
        else
          events = Runs.list_events(run.id)

          if connected?(socket) && run.status == "running" do
            Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{run.agent_id}")
          end

          {:ok, assign(socket, tenant: tenant, current_tenant: tenant, run: run, events: events)}
        end

      :error ->
        {:ok, push_navigate(assign(socket, current_tenant: nil), to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-6">
      <a href={"/agents/#{@run.agent_id}"} class="text-xs text-gray-500 hover:text-gray-400">&larr; agent</a>
    </div>

    <div class="flex items-center gap-3 mb-6">
      <span class={["w-2.5 h-2.5 rounded-full", run_status_color(@run.status)]}></span>
      <h1 class="text-xl font-bold text-white">Run #<%= @run.id %></h1>
      <span class="text-xs text-gray-500"><%= @run.status %></span>
      <%= if @run.status in ["running", "waiting", "pending"] do %>
        <button phx-click="cancel" class="text-xs text-red-400 hover:text-red-300 border border-red-900 px-2 py-1 rounded">
          cancel
        </button>
      <% end %>
    </div>

    <%!-- Input message --%>
    <%= if @run.input["user_message"] do %>
      <div class="bg-gray-900 border border-gray-800 rounded p-4 mb-6">
        <div class="text-xs text-gray-500 mb-1">Input</div>
        <div class="text-sm text-gray-300"><%= @run.input["user_message"] %></div>
      </div>
    <% end %>

    <%!-- Run info --%>
    <div class="grid grid-cols-3 gap-4 mb-6">
      <div class="bg-gray-900 border border-gray-800 rounded p-3">
        <div class="text-xs text-gray-500">Trigger</div>
        <div class="text-sm"><%= @run.trigger_type %></div>
      </div>
      <div class="bg-gray-900 border border-gray-800 rounded p-3">
        <div class="text-xs text-gray-500">Started</div>
        <div class="text-sm"><%= format_time(@run.inserted_at) %></div>
      </div>
      <div class="bg-gray-900 border border-gray-800 rounded p-3">
        <div class="text-xs text-gray-500">Events</div>
        <div class="text-sm"><%= length(@events) %></div>
      </div>
    </div>

    <%!-- Output --%>
    <%= if @run.output do %>
      <div class="mb-6">
        <h2 class="text-sm font-bold text-gray-400 mb-2">Output</h2>
        <div class="bg-gray-900 border border-gray-800 rounded p-4 text-sm text-gray-300 whitespace-pre-wrap">
          <%= @run.output %>
        </div>
      </div>
    <% end %>

    <%= if @run.status == "failed" do %>
      <% inspector = Runs.failure_inspector(@run) %>
      <div class="mb-6">
        <h2 class="text-sm font-bold text-gray-400 mb-2">Failure Inspector</h2>
        <div class="bg-gray-900 border border-gray-800 rounded p-4 text-sm text-gray-300 space-y-2">
          <div>Error class: <span class="text-white"><%= inspector["error_class"] || "unknown" %></span></div>
          <div>Error code: <span class="text-white"><%= inspector["error_code"] || "unknown" %></span></div>
          <div>Retry decision: <span class="text-white"><%= inspector["retry_decision"] || "unknown" %></span></div>
          <%= if checkpoint = inspector["last_checkpoint"] do %>
            <div>Last checkpoint: <span class="text-white">#<%= checkpoint["sequence"] %> <%= checkpoint["event_type"] %></span></div>
          <% end %>
          <%= if event = inspector["last_event"] do %>
            <div>Last event: <span class="text-white">#<%= event["sequence"] %> <%= event["event_type"] %></span></div>
          <% end %>
          <%= if @run.input["user_message"] do %>
            <div class="pt-2">
              <button phx-click="retry" class="text-xs text-blue-400 hover:text-blue-300 border border-blue-900 px-3 py-1.5 rounded">
                Retry with same message
              </button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <%!-- Event timeline --%>
    <h2 class="text-sm font-bold text-gray-400 mb-2">Event Log</h2>
    <div class="space-y-1">
      <%= for event <- Enum.reverse(@events) do %>
        <div class="bg-gray-900 border border-gray-800 rounded px-4 py-2">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <span class="text-xs text-gray-600 w-6 text-right"><%= event.sequence %></span>
              <span class={["text-xs font-medium", event_type_color(event.event_type)]}><%= event.event_type %></span>
              <span class="text-xs text-gray-500"><%= event_summary(event) %></span>
            </div>
            <span class="text-xs text-gray-700"><%= format_time(event.inserted_at) %></span>
          </div>
          <%= if event_detail(event) do %>
            <div class="mt-1 ml-9 text-xs text-gray-600 whitespace-pre-wrap"><%= event_detail(event) %></div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    run = socket.assigns.run
    tenant = socket.assigns.tenant

    # Stop the agent process if it's running
    Norns.Agents.Registry.stop_agent(tenant.id, run.agent_id)

    # Mark the run as failed
    Norns.Runs.append_event(run, %{
      event_type: "run_failed",
      payload: %{
        "error" => "Cancelled by user",
        "error_class" => "policy",
        "error_code" => "cancelled",
        "retry_decision" => "terminal",
        "schema_version" => 1
      }
    })

    {:ok, updated_run} = Norns.Runs.update_run(run, %{
      status: "failed",
      failure_metadata: %{
        "error_class" => "policy",
        "error_code" => "cancelled",
        "retry_decision" => "terminal"
      }
    })

    events = Norns.Runs.list_events(run.id)

    {:noreply,
     socket
     |> assign(run: updated_run, events: events)
     |> put_flash(:info, "Run cancelled")}
  end

  def handle_event("retry", _params, socket) do
    run = socket.assigns.run
    tenant = socket.assigns.tenant
    message = run.input["user_message"]

    if message do
      case Norns.Agents.Registry.send_message(tenant.id, run.agent_id, message) do
        :ok ->
          {:noreply, socket |> put_flash(:info, "Retrying: #{String.slice(message, 0, 60)}")}

        {:error, _reason} ->
          {:noreply, socket |> put_flash(:error, "Failed to retry")}
      end
    else
      {:noreply, socket |> put_flash(:error, "No message to retry")}
    end
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:llm_response, :tool_call, :tool_result, :completed, :error, :waiting, :agent_resumed] do
    run = Runs.get_run!(socket.assigns.run.id)
    events = Runs.list_events(run.id)
    {:noreply, assign(socket, run: run, events: events)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp run_status_color("completed"), do: "bg-green-400"
  defp run_status_color("running"), do: "bg-blue-400 animate-pulse-dot"
  defp run_status_color("waiting"), do: "bg-yellow-400 animate-pulse-dot"
  defp run_status_color("failed"), do: "bg-red-400"
  defp run_status_color(_), do: "bg-gray-600"

  defp event_type_color("llm_request"), do: "text-blue-500"
  defp event_type_color("llm_response"), do: "text-blue-400"
  defp event_type_color("tool_call"), do: "text-yellow-400"
  defp event_type_color("tool_result"), do: "text-yellow-300"
  defp event_type_color("tool_duplicate"), do: "text-orange-300"
  defp event_type_color("checkpoint_saved"), do: "text-gray-500"
  defp event_type_color("checkpoint"), do: "text-gray-500"
  defp event_type_color("retry"), do: "text-orange-400"
  defp event_type_color("run_completed"), do: "text-green-400"
  defp event_type_color("run_failed"), do: "text-red-400"
  defp event_type_color("run_started"), do: "text-gray-400"
  defp event_type_color("agent_completed"), do: "text-green-400"
  defp event_type_color("agent_error"), do: "text-red-400"
  defp event_type_color("waiting_for_user"), do: "text-yellow-400"
  defp event_type_color("user_response"), do: "text-white"
  defp event_type_color("agent_started"), do: "text-gray-400"
  defp event_type_color(_), do: "text-gray-500"

  defp event_summary(%{event_type: "llm_response", payload: %{"finish_reason" => fr}}), do: fr
  defp event_summary(%{event_type: "llm_response", payload: %{"stop_reason" => sr}}), do: sr
  defp event_summary(%{event_type: "tool_call", payload: %{"name" => name}}), do: name
  defp event_summary(%{event_type: "tool_result", payload: %{"name" => name}}), do: name
  defp event_summary(%{event_type: "tool_result", payload: %{"tool_call_id" => id}}), do: id
  defp event_summary(%{event_type: "tool_duplicate", payload: %{"tool_call_id" => id}}), do: id
  defp event_summary(%{event_type: "tool_duplicate", payload: %{"tool_use_id" => id}}), do: id
  defp event_summary(%{event_type: "checkpoint_saved", payload: %{"step" => s}}), do: "step #{s}"
  defp event_summary(%{event_type: "checkpoint", payload: %{"step" => s}}), do: "step #{s}"
  defp event_summary(%{event_type: "retry", payload: %{"attempt" => a}}), do: "attempt #{a}"
  defp event_summary(%{event_type: "run_failed", payload: %{"error" => e}}), do: String.slice(e, 0, 120)
  defp event_summary(%{event_type: "agent_error", payload: %{"error" => e}}), do: String.slice(e, 0, 120)
  defp event_summary(%{event_type: "waiting_for_user", payload: %{"question" => q}}), do: String.slice(q, 0, 80)
  defp event_summary(%{event_type: "user_response", payload: %{"content" => c}}), do: String.slice(c, 0, 80)
  defp event_summary(_), do: ""

  defp event_detail(%{event_type: "llm_request", payload: payload}) do
    header = "step #{payload["step"]}, #{payload["message_count"]} messages, model: #{payload["model"] || "?"}"

    input =
      case payload["messages"] do
        messages when is_list(messages) ->
          last_user =
            messages
            |> Enum.reverse()
            |> Enum.find(fn
              %{"role" => "user"} -> true
              %{role: "user"} -> true
              _ -> false
            end)

          case last_user do
            %{"content" => c} when is_binary(c) -> "input: #{String.slice(c, 0, 300)}"
            %{content: c} when is_binary(c) -> "input: #{String.slice(c, 0, 300)}"
            _ -> nil
          end

        _ ->
          nil
      end

    [header, input] |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp event_detail(%{event_type: "llm_response", payload: payload}) do
    parts = []

    # Token usage
    parts =
      case payload["usage"] do
        %{"input_tokens" => i, "output_tokens" => o} when is_integer(i) and is_integer(o) ->
          ["#{i} in / #{o} out tokens" | parts]
        _ -> parts
      end

    # Text content
    parts =
      case payload["content"] do
        c when is_binary(c) and c != "" -> [String.slice(c, 0, 500) | parts]
        _ -> parts
      end

    # Tool calls
    parts =
      case payload["tool_calls"] do
        calls when is_list(calls) and calls != [] ->
          names = Enum.map_join(calls, ", ", &(&1["name"] || "?"))
          ["tool calls: #{names}" | parts]
        _ -> parts
      end

    Enum.reverse(parts) |> Enum.join("\n")
  end

  defp event_detail(%{event_type: "tool_call", payload: %{"arguments" => args}}) when is_map(args), do: inspect(args, pretty: true, limit: 500)
  defp event_detail(%{event_type: "tool_call", payload: %{"input" => input}}) when is_map(input), do: inspect(input, pretty: true, limit: 500)
  defp event_detail(%{event_type: "tool_result", payload: %{"content" => c}}) when is_binary(c), do: String.slice(c, 0, 500)
  defp event_detail(%{event_type: "tool_duplicate", payload: %{"resolution" => resolution, "idempotency_key" => key}}), do: "#{resolution}: #{key}"
  defp event_detail(%{event_type: "run_completed", payload: %{"output" => o}}), do: String.slice(o || "", 0, 500)
  defp event_detail(%{event_type: "run_failed", payload: %{"error" => e}}), do: e
  defp event_detail(%{event_type: "agent_completed", payload: %{"output" => o}}), do: String.slice(o || "", 0, 500)
  defp event_detail(%{event_type: "agent_error", payload: %{"error" => e}}), do: e
  defp event_detail(%{event_type: "waiting_for_user", payload: %{"question" => q}}), do: q
  defp event_detail(%{event_type: "user_response", payload: %{"content" => c}}), do: c
  defp event_detail(_), do: nil

  defp format_time(nil), do: ""
  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S.") <> String.slice(to_string(dt.microsecond |> elem(0)), 0, 3)

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
