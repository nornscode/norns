defmodule Norns.Agents.Process do
  @moduledoc """
  Durable agent GenServer. Runs an LLM-tool loop, persisting every step
  as a RunEvent so it can resume after a crash.

  Supports interrupt/resume via the `ask_user` tool — the agent pauses,
  surfaces a question, and waits for the user to respond.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Norns.{Agents, Conversations, Runs, Tenants}
  alias Norns.Agents.AgentDef
  alias Norns.Runtime.{ErrorPolicy, Errors, Events}
  alias Norns.Workers.WorkerRegistry
  alias Norns.Tools.{Idempotency, Tool}
  @tool_result_cap 200

  # -- Public API --

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    conversation_key = Keyword.get(opts, :conversation_key, "default")
    name = {:via, Registry, {Norns.AgentRegistry, {tenant_id, agent_id, conversation_key}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def send_message(pid, content) when is_binary(content) do
    GenServer.call(pid, {:send_message, content}, 10_000)
  end

  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    conversation_key = Keyword.get(opts, :conversation_key, "default")
    resume_run_id = Keyword.get(opts, :resume_run_id)

    agent = Agents.get_agent!(agent_id)
    tenant = Tenants.get_tenant!(tenant_id)
    api_key = tenant.api_keys["anthropic"] || ""

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
      conversation_key: conversation_key,
      agent: agent,
      api_key: api_key,
      agent_def: agent_def,
      conversation: nil,
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      pending_ask: nil,
      pending_llm_task: nil,
      pending_tool_tasks: nil,
      resume_action: nil,
      test_pid: Keyword.get(opts, :test_pid)
    }

    state = load_conversation_state(state)

    if resume_run_id do
      {:ok, state, {:continue, {:resume, resume_run_id}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:send_message, content}, _from, %{status: :idle} = state) do
    state = load_conversation_state(state)
    messages = messages_for_new_run(state, content)

    {:ok, run} =
      Runs.create_run(%{
        agent_id: state.agent_id,
        tenant_id: state.tenant_id,
        conversation_id: state.conversation && state.conversation.id,
        trigger_type: "message",
        input: %{"user_message" => content},
        status: "pending"
      })

    append(run, Events.run_started())
    {:ok, run} = Runs.update_run(run, %{status: "running"})

    state = %{state | run: run, messages: messages, step: 0, retry_count: 0, status: :running, resume_action: nil}

    broadcast(state, :agent_started, %{run_id: run.id})
    {:reply, {:ok, run.id}, state, {:continue, :llm_loop}}
  end

  def handle_call({:send_message, content}, _from, %{status: :waiting, pending_ask: pending} = state)
      when not is_nil(pending) do
    append(state.run, Events.user_response(%{"content" => content, "tool_call_id" => pending.tool_call_id, "step" => state.step}))

    ask_result = %{
      role: "tool",
      tool_call_id: pending.tool_call_id,
      name: "ask_user",
      content: content
    }

    all_tool_results = pending.other_results ++ [ask_result]

    messages = state.messages ++ all_tool_results
    state = %{state | messages: messages, status: :running, pending_ask: nil}

    Runs.update_run(state.run, %{status: "running"})
    broadcast(state, :agent_resumed, %{run_id: state.run.id})
    state = maybe_checkpoint(state, :tool_result)
    {:reply, {:ok, state.run.id}, state, {:continue, :llm_loop}}
  end

  def handle_call({:send_message, _content}, _from, state) do
    Logger.warning("Agent #{state.agent_id} received message while #{state.status}, ignoring")
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      agent_id: state.agent_id,
      conversation_id: state.conversation && state.conversation.id,
      conversation_key: state.conversation_key,
      run_id: state.run && state.run.id,
      status: state.status,
      step: state.step,
      message_count: length(state.messages),
      pending_question: state.pending_ask && state.pending_ask.question
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

      tools = Enum.map(state.agent_def.tools, &Tool.to_api_format/1)

      messages_for_llm =
        state
        |> apply_context_strategy()
        |> compact_messages()

      system_prompt = build_system_prompt(state)

      append(state.run, Events.llm_request(%{
        "step" => state.step,
        "message_count" => length(messages_for_llm),
        "messages" => messages_for_llm,
        "system_prompt" => system_prompt,
        "model" => state.agent_def.model
      }))

      # Dispatch LLM call to worker — non-blocking, neutral format
      llm_task = %{
        api_key: state.api_key,
        model: state.agent_def.model,
        system_prompt: system_prompt,
        messages: messages_for_llm,
        tools: tools,
        agent_id: state.agent_id,
        run_id: state.run.id,
        step: state.step
      }

      {:ok, task_id} = WorkerRegistry.dispatch_llm_task(state.tenant_id, llm_task, from_pid: self())

      {:noreply, %{state | status: :awaiting_llm, pending_llm_task: task_id}}
    end
  end

  def handle_continue({:resume, run_id}, state) do
    case rebuild_state(run_id, state) do
      {:ok, resumed_state} ->
        broadcast(resumed_state, :agent_resumed, %{run_id: run_id})
        action = resumed_state.resume_action || :llm_loop
        resumed_state = %{resumed_state | resume_action: nil}

        case action do
          :waiting -> {:noreply, resumed_state}
          _ -> {:noreply, resumed_state, {:continue, action}}
        end

      {:error, reason} ->
        Logger.error("Failed to resume run #{run_id}: #{inspect(reason)}")
        {:stop, {:resume_failed, reason}, state}
    end
  end

  def handle_continue({:execute_tools, tool_use_blocks}, state) do
    dispatch_tool_execution(state, tool_use_blocks, true)
  end

  def handle_continue({:resume_tools, tool_use_blocks}, state) do
    dispatch_tool_execution(state, tool_use_blocks, false)
  end

  defp dispatch_tool_execution(state, tool_use_blocks, log_calls?) do
    {ask_blocks, regular_blocks} =
      Enum.split_with(tool_use_blocks, fn block -> block["name"] == "ask_user" end)

    # Log tool_call events (orchestrator's job)
    if log_calls? do
      Enum.each(regular_blocks, fn tc ->
        tool = Enum.find(state.agent_def.tools, &(&1.name == tc["name"]))
        idempotency = if tool, do: Idempotency.context(state.run, state.step, tc, tool), else: %{}

        append(
          state.run,
          Events.tool_call(%{
            "tool_call_id" => tc["id"],
            "name" => tc["name"],
            "arguments" => tc["arguments"],
            "step" => state.step,
            "side_effect" => Map.get(idempotency, :side_effect?, false),
            "idempotency_key" => Map.get(idempotency, :idempotency_key)
          })
        )

        broadcast(state, :tool_call, %{name: tc["name"], arguments: tc["arguments"]})
      end)
    end

    maybe_invoke_test_hook(state, :after_tool_call_persisted, %{blocks: regular_blocks, step: state.step})

    if regular_blocks == [] do
      handle_ask_or_continue(state, ask_blocks, [], log_calls?)
    else
      pending_tools =
        Enum.map(regular_blocks, fn tc ->
          {:ok, task_id} =
            WorkerRegistry.dispatch_task(state.tenant_id, tc["name"], tc["arguments"],
              from_pid: self(),
              agent_id: state.agent_id,
              run_id: state.run.id
            )

          {task_id, tc}
        end)

      {:noreply,
       %{
         state
         | status: :awaiting_tools,
           pending_tool_tasks: %{
             tasks: Map.new(pending_tools),
             results: %{},
             ask_blocks: ask_blocks,
             log_calls?: log_calls?
           }
       }}
    end
  end

  defp handle_ask_or_continue(state, ask_blocks, regular_results, log_calls?) do
    case ask_blocks do
      [ask_block | _] ->
        question = get_in(ask_block, ["arguments", "question"]) || "What would you like me to do?"

        if log_calls? do
          append(
            state.run,
            Events.tool_call(%{
              "tool_call_id" => ask_block["id"],
              "name" => "ask_user",
              "arguments" => ask_block["arguments"],
              "step" => state.step
            })
          )
        end

        append(state.run, Events.waiting_for_user(%{"question" => question, "tool_call_id" => ask_block["id"], "step" => state.step}))
        Runs.update_run(state.run, %{status: "waiting"})
        broadcast(state, :waiting, %{question: question, tool_call_id: ask_block["id"]})

        {:noreply,
         %{
           state
           | status: :waiting,
             pending_ask: %{
               tool_call_id: ask_block["id"],
               question: question,
               other_results: regular_results
             }
         }}

      [] ->
        messages = state.messages ++ regular_results
        state = %{state | messages: messages, status: :running}
        state = maybe_checkpoint(state, :tool_result)
        {:noreply, state, {:continue, :llm_loop}}
    end
  end

  @impl true
  def handle_info({:task_result, task_id, result}, %{status: :awaiting_llm, pending_llm_task: task_id} = state) do
    state = %{state | status: :running, pending_llm_task: nil}

    case result do
      {:ok, %{"finish_reason" => finish_reason, "usage" => usage} = resp} ->
        response = %{
          content: resp["content"] || "",
          tool_calls: resp["tool_calls"] || [],
          finish_reason: finish_reason,
          usage: %{
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          }
        }

        state = %{state | retry_count: 0}
        handle_llm_response(state, response)

      {:error, reason} ->
        handle_llm_error(state, reason)
    end
  end

  # Tool result arriving while awaiting tools
  def handle_info({:task_result, task_id, result}, %{status: :awaiting_tools, pending_tool_tasks: pending} = state)
      when not is_nil(pending) do
    case Map.pop(pending.tasks, task_id) do
      {nil, _} ->
        # Unknown task ID — ignore
        {:noreply, state}

      {tc, remaining_tasks} ->
        # Build the tool result as a neutral message
        {status, content} =
          case result do
            {:ok, result_str} -> {:ok, result_str}
            {:error, reason} -> {:error, if(is_binary(reason), do: reason, else: inspect(reason))}
          end

        tool_msg = %{
          role: "tool",
          tool_call_id: tc["id"],
          name: tc["name"],
          content: content
        }

        tool_msg = if status == :error, do: Map.put(tool_msg, :is_error, true), else: tool_msg

        # Log the result event
        append(
          state.run,
          Events.tool_result(%{
            "tool_call_id" => tc["id"],
            "name" => tc["name"],
            "content" => content,
            "is_error" => status == :error,
            "step" => state.step
          })
        )

        broadcast(state, :tool_result, %{tool_call_id: tc["id"], name: tc["name"], content: content})

        results = Map.put(pending.results, tc["id"], tool_msg)

        if map_size(remaining_tasks) == 0 do
          # All tools done — collect results in original order and continue
          maybe_invoke_test_hook(state, :after_tool_execution_before_result_persisted, %{results: Map.values(results), step: state.step})

          all_results = Map.values(results)

          state = %{state | pending_tool_tasks: nil}
          handle_ask_or_continue(state, pending.ask_blocks, all_results, pending.log_calls?)
        else
          # Still waiting for more tools
          updated_pending = %{pending | tasks: remaining_tasks, results: results}
          {:noreply, %{state | pending_tool_tasks: updated_pending}}
        end

    end
  end

  def handle_info(:retry_llm, state) do
    {:noreply, state, {:continue, :llm_loop}}
  end

  def handle_info({:runtime_hook_reply, _hook, _action}, state) do
    {:noreply, state}
  end

  def handle_info({:task_result, _task_id, _result}, state) do
    # Stale task result — ignore
    {:noreply, state}
  end

  # -- Internal --

  defp handle_llm_response(state, response) do
    # Build event payload in neutral format
    event_payload = %{
      "content" => response.content,
      "tool_calls" => response.tool_calls,
      "finish_reason" => response.finish_reason,
      "usage" => %{
        "input_tokens" => response.usage.input_tokens,
        "output_tokens" => response.usage.output_tokens
      },
      "step" => state.step
    }

    append(state.run, Events.llm_response(event_payload))

    # Build assistant message in neutral format
    assistant_msg =
      if response.tool_calls != [] do
        %{role: "assistant", content: response.content, tool_calls: response.tool_calls}
      else
        %{role: "assistant", content: response.content}
      end

    messages = state.messages ++ [assistant_msg]
    state = %{state | messages: messages}
    state = maybe_checkpoint(state, :llm_response)

    broadcast(state, :llm_response, %{
      step: state.step,
      finish_reason: response.finish_reason,
      content: response.content,
      tool_calls: response.tool_calls
    })

    case response.finish_reason do
      "stop" ->
        {:noreply, complete_successfully(state, response.content)}

      "tool_call" ->
        {:noreply, state, {:continue, {:execute_tools, response.tool_calls}}}

      "length" ->
        {:noreply, complete_with_error(state, "Max tokens reached")}

      other ->
        Logger.info("Unknown finish_reason #{inspect(other)}, treating as stop")
        {:noreply, complete_successfully(state, response.content)}
    end
  end

  defp handle_llm_error(state, reason) do
    error = Errors.classify(reason)
    decision = ErrorPolicy.decision(error, state.retry_count)

    if state.agent_def.on_failure == :retry_last_step and decision.action == :retry do
      retry_count = state.retry_count + 1

      Logger.warning(
        "LLM call failed (attempt #{retry_count}), retrying in #{decision.delay_ms}ms: #{inspect(reason)}"
      )

      append(
        state.run,
        Events.retry(%{
          "error" => error.message,
          "attempt" => retry_count,
          "delay_ms" => decision.delay_ms,
          "step" => state.step,
          "error_class" => Atom.to_string(error.class),
          "error_code" => Atom.to_string(error.code),
          "retry_decision" => decision.retry_decision
        })
      )

      state = %{state | step: state.step - 1, retry_count: retry_count}
      Process.send_after(self(), :retry_llm, decision.delay_ms)
      {:noreply, state}
    else
      Logger.error("LLM call failed: #{inspect(reason)}")
      {:noreply, complete_with_error(state, error, decision.retry_decision)}
    end
  end

  defp compact_messages(messages) when length(messages) <= 4, do: messages

  defp compact_messages(messages) do
    {old, recent} = Enum.split(messages, length(messages) - 2)
    Enum.map(old, &compact_message/1) ++ recent
  end

  defp compact_message(%{role: "tool", content: content} = msg)
       when is_binary(content) and byte_size(content) > @tool_result_cap do
    truncated = String.slice(content, 0, @tool_result_cap) <> "...(truncated)"
    %{msg | content: truncated}
  end

  defp compact_message(msg), do: msg

  defp complete_successfully(state, content) do
    text = if is_binary(content), do: content, else: ""

    append(state.run, Events.run_completed(%{"output" => text}))

    {:ok, run} = Runs.update_run(state.run, %{status: "completed", output: text, failure_metadata: %{}})
    state = %{state | run: run}
    state = persist_conversation_messages(state)

    broadcast(state, :completed, %{output: text})
    finish_run(state)
  end

  defp complete_with_error(state, reason) when is_binary(reason) do
    error = Errors.classify({:internal, reason})
    complete_with_error(state, error, "terminal")
  end

  defp complete_with_error(state, %Errors.Error{} = error, retry_decision) do
    payload =
      Errors.to_metadata(error)
      |> Map.put("retry_decision", retry_decision)

    append(state.run, Events.run_failed(payload))

    {:ok, run} =
      Runs.update_run(state.run, %{
        status: "failed",
        failure_metadata: Map.put(payload, "schema_version", Norns.Runtime.EventValidator.schema_version())
      })

    state = %{state | run: run}
    state = persist_conversation_messages(state)

    broadcast(state, :error, %{error: error.message})
    finish_run(state)
  end

  defp finish_run(%{agent_def: %{mode: :conversation}} = state) do
    %{state | status: :idle, pending_ask: nil, retry_count: 0}
  end

  defp finish_run(state) do
    %{state | status: :idle, pending_ask: nil, retry_count: 0, messages: []}
  end

  defp maybe_checkpoint(state, context) do
    should_checkpoint =
      case state.agent_def.checkpoint_policy do
        :every_step -> true
        :on_tool_call -> context == :tool_result
        :manual -> false
      end

    if should_checkpoint do
      maybe_invoke_test_hook(state, :before_checkpoint_write, %{context: context, step: state.step})

      append(
        state.run,
        Events.checkpoint_saved(%{
          "messages" => state.messages,
          "step" => state.step
        })
      )
    end

    state
  end

  defp build_system_prompt(state) do
    state.agent_def.system_prompt
    |> maybe_append_summary(state)
    |> maybe_append_memory_instructions(state)
    |> Kernel.<>("\n\nCurrent date: #{Date.utc_today()}.")
  end

  defp maybe_append_summary(prompt, %{conversation: %{summary: summary}})
       when is_binary(summary) and summary != "" do
    prompt <> "\n\nSummary of earlier conversation: " <> summary
  end

  defp maybe_append_summary(prompt, _state), do: prompt

  defp maybe_append_memory_instructions(prompt, state) do
    tool_names = Enum.map(state.agent_def.tools, & &1.name)

    if "store_memory" in tool_names and "search_memory" in tool_names do
      prompt <>
        "\n\nYou have a persistent memory shared across conversations. " <>
        "Use search_memory to recall facts before answering and store_memory to save durable facts, decisions, and events."
    else
      prompt
    end
  end

  defp load_conversation_state(%{agent_def: %{mode: :conversation}} = state) do
    if state.conversation do
      state
    else
      {:ok, conversation} =
        Conversations.find_or_create_conversation(
          state.agent_id,
          state.tenant_id,
          state.conversation_key
        )

      %{state | conversation: conversation, messages: normalize_messages(conversation.messages)}
    end
  end

  defp load_conversation_state(state), do: state

  defp messages_for_new_run(%{agent_def: %{mode: :conversation}, messages: messages}, content) do
    messages ++ [%{role: "user", content: content}]
  end

  defp messages_for_new_run(_state, content) do
    [%{role: "user", content: content}]
  end

  defp persist_conversation_messages(%{agent_def: %{mode: :conversation}, conversation: conversation} = state)
       when not is_nil(conversation) do
    {:ok, conversation} =
      Conversations.update_conversation(conversation, %{
        messages: state.messages
      })

    %{state | conversation: conversation}
  end

  defp persist_conversation_messages(state), do: state

  defp apply_context_strategy(%{agent_def: %{mode: :conversation, context_strategy: :sliding_window}} = state) do
    window = max(state.agent_def.context_window, 1)
    Enum.take(state.messages, -window)
  end

  defp apply_context_strategy(%{agent_def: %{mode: :conversation, context_strategy: :none}, messages: messages}),
    do: messages

  defp apply_context_strategy(%{messages: messages}), do: messages

  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{role: _role, content: _content} = message -> message
      %{"role" => role, "content" => content} -> %{role: role, content: content}
    end)
  end

  defp normalize_messages(_messages), do: []

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
      base_state = restore_conversation_for_run(base_state, run)
      initial_messages = initial_messages_for_replay(base_state, run)
      {messages, step, pending_ask, resume_action} = replay_from_events(initial_messages, events)
      status = if pending_ask, do: :waiting, else: :running

      {:ok,
       base_state
       |> Map.put(:run, run)
       |> Map.put(:messages, messages)
       |> Map.put(:step, step)
       |> Map.put(:status, status)
       |> Map.put(:pending_ask, pending_ask)
       |> Map.put(:resume_action, resume_action)}
    end
  end

  defp restore_conversation_for_run(%{agent_def: %{mode: :conversation}} = state, run) do
    conversation = run.conversation || state.conversation
    messages = if conversation, do: normalize_messages(conversation.messages), else: []
    %{state | conversation: conversation, messages: messages}
  end

  defp restore_conversation_for_run(state, _run), do: state

  defp initial_messages_for_replay(state, run) do
    messages = state.messages
    user_message = get_in(run.input, ["user_message"])

    if is_binary(user_message) do
      messages ++ [%{role: "user", content: user_message}]
    else
      messages
    end
  end

  defp replay_from_events(initial_messages, events) do
    checkpoint =
      events
      |> Enum.reverse()
      |> Enum.find(fn event -> event.event_type in ["checkpoint_saved", "checkpoint"] end)

    case checkpoint do
      %{payload: %{"messages" => messages, "step" => step}} ->
        post_checkpoint = Enum.drop_while(events, fn event -> event.sequence <= checkpoint.sequence end)
        replay_events_onto(normalize_messages(messages), step, nil, [], post_checkpoint)

      nil ->
        replay_events_onto(initial_messages, 0, nil, [], events)
    end
  end

  defp replay_events_onto(messages, step, pending_ask, pending_tool_calls, events) do
    {msgs, current_step, ask_state, pending_calls} =
      Enum.reduce(events, {messages, step, pending_ask, pending_tool_calls}, fn event,
                                                                                {msgs, current_step, ask_state,
                                                                                 pending_calls} ->
        case event.event_type do
          "llm_response" ->
            content = event.payload["content"] || ""
            tool_calls = event.payload["tool_calls"] || []

            assistant_msg =
              if tool_calls != [] do
                %{role: "assistant", content: content, tool_calls: tool_calls}
              else
                %{role: "assistant", content: content}
              end

            {msgs ++ [assistant_msg], event.payload["step"] || current_step, nil, tool_calls}

          "tool_result" ->
            tool_msg = %{
              role: "tool",
              tool_call_id: event.payload["tool_call_id"],
              name: event.payload["name"],
              content: event.payload["content"]
            }

            tool_msg =
              if event.payload["is_error"] do
                Map.put(tool_msg, :is_error, true)
              else
                tool_msg
              end

            {msgs ++ [tool_msg], current_step, ask_state,
             remove_pending_tool_call(pending_calls, event.payload["tool_call_id"])}

          "tool_duplicate" ->
            {msgs, current_step, ask_state, remove_pending_tool_call(pending_calls, event.payload["tool_call_id"])}

          "waiting_for_user" ->
            pending_ask = %{
              tool_call_id: event.payload["tool_call_id"],
              question: event.payload["question"],
              other_results: []
            }

            {msgs, current_step, pending_ask, pending_calls}

          "user_response" ->
            {msgs, current_step, nil, remove_pending_tool_call(pending_calls, event.payload["tool_call_id"])}

          type when type in ["checkpoint_saved", "checkpoint"] ->
            {normalize_messages(event.payload["messages"]), event.payload["step"], nil, []}

          _ ->
            {msgs, current_step, ask_state, pending_calls}
        end
      end)

    resume_action =
      cond do
        ask_state -> :waiting
        pending_calls != [] -> {:resume_tools, pending_calls}
        true -> :llm_loop
      end

    {msgs, current_step, ask_state, resume_action}
  end

  defp remove_pending_tool_call(pending_calls, tool_call_id) do
    Enum.reject(pending_calls, fn tc -> tc["id"] == tool_call_id end)
  end

  defp append(run, {:ok, event}), do: Runs.append_event(run, event)
  defp append(_run, {:error, reason}), do: {:error, reason}

  defp maybe_invoke_test_hook(%{test_pid: nil}, _hook, _payload), do: :ok

  defp maybe_invoke_test_hook(%{test_pid: test_pid}, hook, payload) do
    send(test_pid, {:runtime_hook, hook, payload})

    receive do
      {:runtime_hook_reply, ^hook, :crash} -> exit({:test_crash, hook})
    after
      100 -> :ok
    end
  end
end
