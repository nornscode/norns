defmodule Norns.Agents.Process do
  @moduledoc """
  Durable agent GenServer. Runs an LLM-tool loop, persisting every step
  as a RunEvent so it can resume after a crash.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Norns.{Agents, LLM, Runs, Tenants}
  alias Norns.Agents.AgentDef
  alias Norns.Tools.{Executor, Tool}

  @max_retries 3
  @max_rate_limit_retries 10
  @rate_limit_base_delay_ms 15_000

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
    resume_run_id = Keyword.get(opts, :resume_run_id)

    agent = Agents.get_agent!(agent_id)
    tenant = Tenants.get_tenant!(tenant_id)
    api_key = tenant.api_keys["anthropic"] || ""

    # Build AgentDef from opts or from agent record
    agent_def =
      Keyword.get_lazy(opts, :agent_def, fn ->
        tools = Keyword.get(opts, :tools, [])
        max_steps = Keyword.get(opts, :max_steps)

        def_opts = [tools: tools]
        base_def = AgentDef.from_agent(agent, def_opts)

        if max_steps, do: %{base_def | max_steps: max_steps}, else: base_def
      end)

    state = %{
      agent_id: agent_id,
      tenant_id: tenant_id,
      agent: agent,
      api_key: api_key,
      agent_def: agent_def,
      messages: [],
      step: 0,
      retry_count: 0,
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
    state = %{state | run: run, messages: messages, step: 0, retry_count: 0, status: :running}

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
    max_steps = state.agent_def.max_steps

    if state.step >= max_steps do
      {:noreply, complete_with_error(state, "Max steps (#{max_steps}) exceeded")}
    else
      state = %{state | step: state.step + 1}

      Runs.append_event(state.run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => state.step, "message_count" => length(state.messages)}
      })

      api_tools = Enum.map(state.agent_def.tools, &Tool.to_api_format/1)
      opts = if api_tools == [], do: [], else: [tools: api_tools]

      case LLM.chat(state.api_key, state.agent_def.model, state.agent_def.system_prompt, state.messages, opts) do
        {:ok, response} ->
          state = %{state | retry_count: 0}
          handle_llm_response(state, response)

        {:error, reason} ->
          handle_llm_error(state, reason)
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

    tool_results = Executor.execute_all(tool_use_blocks, state.agent_def.tools)

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

    messages = state.messages ++ [%{role: "user", content: tool_results}]
    state = %{state | messages: messages}

    state = maybe_checkpoint(state, :tool_result)

    {:noreply, state, {:continue, :llm_loop}}
  end

  @impl true
  def handle_info(:retry_llm, state) do
    {:noreply, state, {:continue, :llm_loop}}
  end

  # -- Internal --

  defp handle_llm_response(state, response) do
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

    messages = state.messages ++ [%{role: "assistant", content: response.content}]
    state = %{state | messages: messages}

    state = maybe_checkpoint(state, :llm_response)

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
        Logger.info("Unknown stop_reason #{inspect(other)}, treating as end_turn")
        {:noreply, complete_successfully(state, response.content)}
    end
  end

  defp handle_llm_error(state, reason) do
    {max_retries, delay} = retry_params(reason, state.retry_count)

    if state.agent_def.on_failure == :retry_last_step and state.retry_count < max_retries do
      retry_count = state.retry_count + 1

      Logger.warning("LLM call failed (attempt #{retry_count}/#{max_retries}), retrying in #{delay}ms: #{inspect(reason)}")

      Runs.append_event(state.run, %{
        event_type: "retry",
        source: "system",
        payload: %{
          "error" => inspect(reason),
          "attempt" => retry_count,
          "delay_ms" => delay,
          "step" => state.step
        }
      })

      # Undo the step increment so the retry re-executes the same step
      state = %{state | step: state.step - 1, retry_count: retry_count}
      Process.send_after(self(), :retry_llm, delay)
      {:noreply, state}
    else
      Logger.error("LLM call failed: #{inspect(reason)}")
      {:noreply, complete_with_error(state, "LLM error: #{inspect(reason)}")}
    end
  end

  defp retry_params(reason, retry_count) do
    if rate_limit_error?(reason) do
      # Rate limits need longer waits — 15s base with linear backoff
      {@max_rate_limit_retries, @rate_limit_base_delay_ms * (retry_count + 1)}
    else
      # Other errors: exponential backoff from 1s
      {@max_retries, 1000 * Integer.pow(2, retry_count)}
    end
  end

  defp rate_limit_error?({429, _}), do: true
  defp rate_limit_error?(_), do: false

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

  # Checkpoint policies
  defp maybe_checkpoint(state, context) do
    should_checkpoint =
      case state.agent_def.checkpoint_policy do
        :every_step -> true
        :on_tool_call -> context == :tool_result
        :manual -> false
      end

    if should_checkpoint do
      Runs.append_event(state.run, %{
        event_type: "checkpoint",
        source: "system",
        payload: %{
          "messages" => state.messages,
          "step" => state.step
        }
      })
    end

    state
  end

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
    checkpoint =
      events
      |> Enum.reverse()
      |> Enum.find(fn e -> e.event_type == "checkpoint" end)

    case checkpoint do
      %{payload: %{"messages" => messages, "step" => step}} ->
        post_checkpoint =
          Enum.drop_while(events, fn e -> e.sequence <= checkpoint.sequence end)

        replay_events_onto(messages, step, post_checkpoint)

      nil ->
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

        "checkpoint" ->
          {event.payload["messages"], event.payload["step"]}

        _ ->
          {msgs, s}
      end
    end)
  end
end
