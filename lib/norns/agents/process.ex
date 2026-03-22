defmodule Norns.Agents.Process do
  @moduledoc """
  Durable agent GenServer. Runs an LLM-tool loop, persisting every step
  as a RunEvent so it can resume after a crash.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Norns.{Agents, LLM, Runs, Tenants}
  alias Norns.Tools.{Executor, Tool}

  @default_max_steps 50
  @checkpoint_interval 5

  # -- Public API --

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    name = {:via, Registry, {Norns.AgentRegistry, {tenant_id, agent_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def send_message(pid, content) when is_binary(content) do
    GenServer.cast(pid, {:send_message, content})
  end

  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    tools = Keyword.get(opts, :tools, [])
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    resume_run_id = Keyword.get(opts, :resume_run_id)

    agent = Agents.get_agent!(agent_id)
    tenant = Tenants.get_tenant!(tenant_id)
    api_key = tenant.api_keys["anthropic"] || ""

    state = %{
      agent_id: agent_id,
      tenant_id: tenant_id,
      agent: agent,
      api_key: api_key,
      model: agent.model,
      system_prompt: agent.system_prompt,
      tools: tools,
      messages: [],
      step: 0,
      max_steps: max_steps,
      run: nil,
      status: :idle
    }

    if resume_run_id do
      {:ok, state, {:continue, {:resume, resume_run_id}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_cast({:send_message, content}, %{status: :idle} = state) do
    # Create a new run
    {:ok, run} =
      Runs.create_run(%{
        agent_id: state.agent_id,
        tenant_id: state.tenant_id,
        trigger_type: "message",
        input: %{"user_message" => content},
        status: "pending"
      })

    Runs.append_event(run, %{event_type: "agent_started", source: "system"})
    {:ok, run} = Runs.update_run(run, %{status: "running"})

    messages = state.messages ++ [%{role: "user", content: content}]
    state = %{state | run: run, messages: messages, step: 0, status: :running}

    broadcast(state, :agent_started, %{run_id: run.id})
    {:noreply, state, {:continue, :llm_loop}}
  end

  def handle_cast({:send_message, _content}, state) do
    Logger.warning("Agent #{state.agent_id} received message while #{state.status}, ignoring")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      agent_id: state.agent_id,
      run_id: state.run && state.run.id,
      status: state.status,
      step: state.step,
      message_count: length(state.messages)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_continue(:llm_loop, state) do
    if state.step >= state.max_steps do
      {:noreply, complete_with_error(state, "Max steps (#{state.max_steps}) exceeded")}
    else
      state = %{state | step: state.step + 1}

      # Log LLM request event BEFORE making the call
      Runs.append_event(state.run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => state.step, "message_count" => length(state.messages)}
      })

      api_tools = Enum.map(state.tools, &Tool.to_api_format/1)
      opts = if api_tools == [], do: [], else: [tools: api_tools]

      case LLM.chat(state.api_key, state.model, state.system_prompt, state.messages, opts) do
        {:ok, response} ->
          handle_llm_response(state, response)

        {:error, reason} ->
          Logger.error("LLM call failed: #{inspect(reason)}")
          {:noreply, complete_with_error(state, "LLM error: #{inspect(reason)}")}
      end
    end
  end

  def handle_continue({:resume, run_id}, state) do
    case rebuild_state(run_id, state) do
      {:ok, resumed_state} ->
        broadcast(resumed_state, :agent_resumed, %{run_id: run_id})
        {:noreply, resumed_state, {:continue, :llm_loop}}

      {:error, reason} ->
        Logger.error("Failed to resume run #{run_id}: #{inspect(reason)}")
        {:stop, {:resume_failed, reason}, state}
    end
  end

  def handle_continue({:execute_tools, tool_use_blocks}, state) do
    # Log each tool call
    Enum.each(tool_use_blocks, fn block ->
      Runs.append_event(state.run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{
          "tool_use_id" => block["id"],
          "name" => block["name"],
          "input" => block["input"],
          "step" => state.step
        }
      })

      broadcast(state, :tool_call, %{name: block["name"], input: block["input"]})
    end)

    # Execute all tools
    tool_results = Executor.execute_all(tool_use_blocks, state.tools)

    # Log each tool result
    Enum.each(tool_results, fn result ->
      Runs.append_event(state.run, %{
        event_type: "tool_result",
        source: "system",
        payload: %{
          "tool_use_id" => result["tool_use_id"],
          "content" => result["content"],
          "is_error" => Map.get(result, "is_error", false),
          "step" => state.step
        }
      })

      broadcast(state, :tool_result, %{
        tool_use_id: result["tool_use_id"],
        content: result["content"]
      })
    end)

    # Append tool results as a user message and continue the loop
    messages = state.messages ++ [%{role: "user", content: tool_results}]
    state = %{state | messages: messages}

    # Periodic checkpoint
    state = maybe_checkpoint(state)

    {:noreply, state, {:continue, :llm_loop}}
  end

  # -- Internal --

  defp handle_llm_response(state, response) do
    # Log LLM response event
    Runs.append_event(state.run, %{
      event_type: "llm_response",
      source: "system",
      payload: %{
        "content" => response.content,
        "stop_reason" => response.stop_reason,
        "usage" => %{
          "input_tokens" => response.usage.input_tokens,
          "output_tokens" => response.usage.output_tokens
        },
        "step" => state.step
      }
    })

    # Append assistant message to history
    messages = state.messages ++ [%{role: "assistant", content: response.content}]
    state = %{state | messages: messages}

    broadcast(state, :llm_response, %{
      step: state.step,
      stop_reason: response.stop_reason,
      content: response.content
    })

    case response.stop_reason do
      "end_turn" ->
        {:noreply, complete_successfully(state, response.content)}

      "tool_use" ->
        tool_use_blocks =
          Enum.filter(response.content, fn c -> c["type"] == "tool_use" end)

        {:noreply, state, {:continue, {:execute_tools, tool_use_blocks}}}

      other ->
        # Treat unknown stop reasons as completion
        Logger.info("Unknown stop_reason #{inspect(other)}, treating as end_turn")
        {:noreply, complete_successfully(state, response.content)}
    end
  end

  defp complete_successfully(state, content) do
    text =
      content
      |> Enum.find_value(fn
        %{"type" => "text", "text" => t} -> t
        _ -> nil
      end) || ""

    Runs.append_event(state.run, %{
      event_type: "agent_completed",
      source: "system",
      payload: %{"output" => text}
    })

    {:ok, run} = Runs.update_run(state.run, %{status: "completed", output: text})
    broadcast(state, :completed, %{output: text})

    %{state | run: run, status: :idle}
  end

  defp complete_with_error(state, reason) do
    Runs.append_event(state.run, %{
      event_type: "agent_error",
      source: "system",
      payload: %{"error" => reason}
    })

    {:ok, run} = Runs.update_run(state.run, %{status: "failed"})
    broadcast(state, :error, %{error: reason})

    %{state | run: run, status: :idle}
  end

  defp maybe_checkpoint(%{step: step} = state) when rem(step, @checkpoint_interval) == 0 do
    Runs.append_event(state.run, %{
      event_type: "checkpoint",
      source: "system",
      payload: %{
        "messages" => state.messages,
        "step" => state.step
      }
    })

    state
  end

  defp maybe_checkpoint(state), do: state

  defp broadcast(state, event, payload) do
    Phoenix.PubSub.broadcast(
      Norns.PubSub,
      "agent:#{state.agent_id}",
      {event, Map.put(payload, :agent_id, state.agent_id)}
    )
  end

  # -- State Reconstruction --

  @doc "Rebuild agent state from the event log for a given run."
  def rebuild_state(run_id, base_state) do
    run = Runs.get_run!(run_id)
    events = Runs.list_events(run_id)

    if events == [] do
      {:error, :no_events}
    else
      # Find the last checkpoint to minimize replay
      {messages, step} = replay_from_events(events)

      {:ok,
       %{
         base_state
         | run: run,
           messages: messages,
           step: step,
           status: :running
       }}
    end
  end

  defp replay_from_events(events) do
    # Find last checkpoint
    checkpoint =
      events
      |> Enum.reverse()
      |> Enum.find(fn e -> e.event_type == "checkpoint" end)

    case checkpoint do
      %{payload: %{"messages" => messages, "step" => step}} ->
        # Replay events after the checkpoint
        post_checkpoint =
          Enum.drop_while(events, fn e -> e.sequence <= checkpoint.sequence end)

        replay_events_onto(messages, step, post_checkpoint)

      nil ->
        # No checkpoint — replay from scratch
        replay_events_onto([], 0, events)
    end
  end

  defp replay_events_onto(messages, step, events) do
    Enum.reduce(events, {messages, step}, fn event, {msgs, s} ->
      case event.event_type do
        "llm_response" ->
          content = event.payload["content"]
          {msgs ++ [%{role: "assistant", content: content}], event.payload["step"] || s}

        "tool_result" ->
          # Accumulate tool results — they'll be grouped into a user message
          # Check if last message is already a user tool_result list
          tool_result = %{
            "type" => "tool_result",
            "tool_use_id" => event.payload["tool_use_id"],
            "content" => event.payload["content"]
          }

          tool_result =
            if event.payload["is_error"],
              do: Map.put(tool_result, "is_error", true),
              else: tool_result

          case List.last(msgs) do
            %{role: "user", content: content} when is_list(content) ->
              updated = List.replace_at(msgs, -1, %{role: "user", content: content ++ [tool_result]})
              {updated, s}

            _ ->
              {msgs ++ [%{role: "user", content: [tool_result]}], s}
          end

        "agent_started" ->
          {msgs, s}

        "llm_request" ->
          {msgs, s}

        "tool_call" ->
          {msgs, s}

        "checkpoint" ->
          # If we encounter a checkpoint during post-checkpoint replay, use it
          {event.payload["messages"], event.payload["step"]}

        _ ->
          {msgs, s}
      end
    end)
  end
end
