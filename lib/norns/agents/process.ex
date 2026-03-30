defmodule Norns.Agents.Process do
  @moduledoc """
  Durable agent GenServer. Runs an LLM-tool loop, persisting every step
  as a RunEvent so it can resume after a crash.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Norns.{Agents, Conversations, Runs, Tenants}
  alias Norns.Agents.AgentDef
  alias Norns.Runtime.{ErrorPolicy, Errors, Events}
  alias Norns.Workers.WorkerRegistry
  alias Norns.Tools.{Builtins, Idempotency, Tool}
  @tool_result_cap 200
  @task_timeout_ms 300_000  # 5 minutes

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
        explicit_tools = Keyword.get(opts, :tools, [])
        worker_tools = WorkerRegistry.available_tools(tenant_id)
        tools = explicit_tools ++ worker_tools
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
      pending_llm_task: nil,
      pending_tool_tasks: nil,
      task_timer: nil,
      pending_subagents: %{},
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

      # Resolve tools at dispatch time: built-ins + agent_def tools + worker-registered tools
      builtin_tools = Builtins.all()
      agent_tools = state.agent_def.tools
      worker_tools = WorkerRegistry.available_tools(state.tenant_id)
      all_tools = (builtin_tools ++ agent_tools ++ worker_tools) |> Enum.uniq_by(& &1.name)
      tools = Enum.map(all_tools, &Tool.to_api_format/1)

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

      timer = Process.send_after(self(), {:task_timeout, task_id}, @task_timeout_ms)
      {:noreply, %{state | status: :awaiting_llm, pending_llm_task: task_id, task_timer: timer}}
    end
  end

  def handle_continue({:resume, run_id}, state) do
    case rebuild_state(run_id, state) do
      {:ok, resumed_state} ->
        broadcast(resumed_state, :agent_resumed, %{run_id: run_id})
        action = resumed_state.resume_action || :llm_loop
        resumed_state = %{resumed_state | resume_action: nil}

        case action do
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
    {wait_blocks, remaining} =
      Enum.split_with(tool_use_blocks, fn block -> block["name"] == "wait" end)

    {list_agents_blocks, remaining} =
      Enum.split_with(remaining, fn block -> block["name"] == "list_agents" end)

    {launch_agent_blocks, regular_blocks} =
      Enum.split_with(remaining, fn block -> block["name"] == "launch_agent" end)

    # Resolve list_agents synchronously — results go into the pool immediately
    list_agents_results = resolve_list_agents(state, list_agents_blocks, log_calls?)

    # Resolve launch_agent — may produce immediate error results or async pending tasks
    {launch_results, launch_pending, state} =
      resolve_launch_agents(state, launch_agent_blocks, log_calls?)

    sync_results = list_agents_results ++ launch_results

    # Log tool_call events for regular (worker-dispatched) blocks
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

    all_async_blocks = regular_blocks
    has_async = all_async_blocks != [] or launch_pending != []

    if not has_async do
      handle_wait_or_continue(state, wait_blocks, sync_results, log_calls?)
    else
      worker_pending =
        Enum.map(all_async_blocks, fn tc ->
          {:ok, task_id} =
            WorkerRegistry.dispatch_task(state.tenant_id, tc["name"], tc["arguments"],
              from_pid: self(),
              agent_id: state.agent_id,
              run_id: state.run.id
            )

          {task_id, tc}
        end)

      all_pending = worker_pending ++ launch_pending

      timer = Process.send_after(self(), {:task_timeout, :tools}, @task_timeout_ms)

      {:noreply,
       %{
         state
         | status: :awaiting_tools,
           task_timer: timer,
           pending_tool_tasks: %{
             tasks: Map.new(all_pending),
             results: Map.new(sync_results, fn r -> {r.tool_call_id, r} end),
             wait_blocks: wait_blocks,
             log_calls?: log_calls?
           }
       }}
    end
  end

  defp resolve_list_agents(state, blocks, log_calls?) do
    Enum.map(blocks, fn block ->
      if log_calls? do
        append(state.run, Events.tool_call(%{
          "tool_call_id" => block["id"],
          "name" => "list_agents",
          "arguments" => block["arguments"] || %{},
          "step" => state.step
        }))
      end

      agents = Agents.list_agents(state.tenant_id)

      result =
        agents
        |> Enum.reject(&(&1.id == state.agent_id))
        |> Enum.map(fn a -> %{"name" => a.name, "purpose" => a.purpose || ""} end)
        |> Jason.encode!()

      append(state.run, Events.tool_result(%{
        "tool_call_id" => block["id"],
        "name" => "list_agents",
        "content" => result,
        "is_error" => false,
        "step" => state.step
      }))

      broadcast(state, :tool_result, %{tool_call_id: block["id"], name: "list_agents", content: result})

      %{role: "tool", tool_call_id: block["id"], name: "list_agents", content: result}
    end)
  end

  defp resolve_launch_agents(state, blocks, log_calls?) do
    Enum.reduce(blocks, {[], [], state}, fn block, {results, pending, st} ->
      if log_calls? do
        append(st.run, Events.tool_call(%{
          "tool_call_id" => block["id"],
          "name" => "launch_agent",
          "arguments" => block["arguments"] || %{},
          "step" => st.step
        }))
      end

      agent_name = get_in(block, ["arguments", "agent_name"]) || ""
      message = get_in(block, ["arguments", "message"]) || ""

      child_agent = Agents.get_agent_by_name(st.tenant_id, agent_name)

      cond do
        is_nil(child_agent) ->
          error_msg = "Agent '#{agent_name}' not found"
          result = make_error_tool_result(st, block, "launch_agent", error_msg)
          {results ++ [result], pending, st}

        child_agent.id == st.agent_id ->
          error_msg = "Cannot launch self as a sub-agent"
          result = make_error_tool_result(st, block, "launch_agent", error_msg)
          {results ++ [result], pending, st}

        true ->
          # Subscribe to child agent events
          Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{child_agent.id}")

          conversation_key = "subagent_#{block["id"]}_#{System.unique_integer([:positive])}"

          case Norns.Agents.Registry.send_message(st.tenant_id, child_agent.id, message, conversation_key: conversation_key) do
            {:ok, child_run_id} ->
              task_id = "subagent_#{block["id"]}"

              append(st.run, Events.subagent_launched(%{
                "tool_call_id" => block["id"],
                "child_agent_name" => agent_name,
                "child_run_id" => to_string(child_run_id),
                "step" => st.step
              }))

              broadcast(st, :tool_call, %{name: "launch_agent", arguments: block["arguments"]})

              # Synthetic tool_call block for pending task tracking
              synthetic_tc = %{
                "id" => block["id"],
                "name" => "launch_agent",
                "arguments" => block["arguments"]
              }

              new_subagents = Map.put(st.pending_subagents, child_agent.id, %{
                task_id: task_id,
                run_id: child_run_id,
                tool_call_id: block["id"]
              })

              st = %{st | pending_subagents: new_subagents}

              {results, pending ++ [{task_id, synthetic_tc}], st}

            {:error, reason} ->
              error_msg = "Failed to launch agent '#{agent_name}': #{inspect(reason)}"
              result = make_error_tool_result(st, block, "launch_agent", error_msg)
              {results ++ [result], pending, st}
          end
      end
    end)
  end

  defp make_error_tool_result(state, block, name, error_msg) do
    append(state.run, Events.tool_result(%{
      "tool_call_id" => block["id"],
      "name" => name,
      "content" => error_msg,
      "is_error" => true,
      "step" => state.step
    }))

    broadcast(state, :tool_result, %{tool_call_id: block["id"], name: name, content: error_msg})

    %{role: "tool", tool_call_id: block["id"], name: name, content: error_msg, is_error: true}
  end

  defp handle_wait_or_continue(state, wait_blocks, regular_results, log_calls?) do
    cond do
      wait_blocks != [] ->
        [wait_block | _] = wait_blocks
        seconds = get_in(wait_block, ["arguments", "seconds"]) || 0
        seconds = if is_binary(seconds), do: String.to_integer(seconds), else: seconds
        reason = get_in(wait_block, ["arguments", "reason"]) || "Agent requested a delay"

        if log_calls? do
          append(state.run, Events.tool_call(%{
            "tool_call_id" => wait_block["id"],
            "name" => "wait",
            "arguments" => wait_block["arguments"],
            "step" => state.step
          }))
        end

        append(state.run, Events.build("waiting_for_timer", %{
          "tool_call_id" => wait_block["id"],
          "seconds" => seconds,
          "reason" => reason,
          "step" => state.step
        }))

        broadcast(state, :waiting_timer, %{seconds: seconds, reason: reason})

        timer_ref = Process.send_after(self(), {:timer_complete, wait_block["id"], regular_results, log_calls?}, seconds * 1000)

        {:noreply, %{state | status: :waiting_timer, task_timer: timer_ref}}

      true ->
        messages = state.messages ++ regular_results
        state = %{state | messages: messages, status: :running}
        state = maybe_checkpoint(state, :tool_result)
        {:noreply, state, {:continue, :llm_loop}}
    end
  end

  @impl true
  def handle_info({:task_result, task_id, result}, %{status: :awaiting_llm, pending_llm_task: task_id} = state) do
    cancel_timer(state.task_timer)
    state = %{state | status: :running, pending_llm_task: nil, task_timer: nil}

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
          # All tools done
          cancel_timer(state.task_timer)
          maybe_invoke_test_hook(state, :after_tool_execution_before_result_persisted, %{results: Map.values(results), step: state.step})

          all_results = Map.values(results)

          state = %{state | pending_tool_tasks: nil, task_timer: nil}
          handle_wait_or_continue(state, pending.wait_blocks || [], all_results, pending.log_calls?)
        else
          # Still waiting for more tools
          updated_pending = %{pending | tasks: remaining_tasks, results: results}
          {:noreply, %{state | pending_tool_tasks: updated_pending}}
        end

    end
  end

  def handle_info({:timer_complete, tool_call_id, pending_results, log_calls?}, %{status: :waiting_timer} = state) do
    # Timer fired — deliver the wait tool result and continue
    wait_result = %{
      role: "tool",
      tool_call_id: tool_call_id,
      name: "wait",
      content: "Timer completed."
    }

    append(state.run, Events.tool_result(%{
      "tool_call_id" => tool_call_id,
      "name" => "wait",
      "content" => "Timer completed.",
      "is_error" => false,
      "step" => state.step
    }))

    broadcast(state, :tool_result, %{tool_call_id: tool_call_id, name: "wait", content: "Timer completed."})

    all_results = pending_results ++ [wait_result]
    state = %{state | task_timer: nil}

    handle_wait_or_continue(state, [], all_results, log_calls?)
  end

  def handle_info({:task_timeout, task_id}, %{pending_llm_task: task_id} = state) do
    Logger.warning("LLM task #{task_id} timed out after #{@task_timeout_ms}ms")
    handle_llm_error(state, {:timeout, "LLM task timed out — worker may have disconnected"})
  end

  def handle_info({:task_timeout, _task_id}, %{status: :awaiting_tools} = state) do
    Logger.warning("Tool task timed out after #{@task_timeout_ms}ms")
    {:noreply, complete_with_error(state, "Tool task timed out — worker may have disconnected")}
  end

  def handle_info({:task_timeout, _task_id}, state) do
    # Stale timeout — task already completed
    {:noreply, state}
  end

  def handle_info(:retry_llm, state) do
    {:noreply, state, {:continue, :llm_loop}}
  end

  # Child agent completed — convert to task_result for existing pipeline
  def handle_info({:completed, %{agent_id: child_id, output: output}}, %{status: :awaiting_tools} = state) do
    case find_subagent_task(state, child_id) do
      {task_id, _} ->
        send(self(), {:task_result, task_id, {:ok, output || ""}})
        {:noreply, %{state | pending_subagents: Map.delete(state.pending_subagents, child_id)}}

      nil ->
        {:noreply, state}
    end
  end

  # Child agent failed — convert to task_result error
  def handle_info({:error, %{agent_id: child_id, error: error}}, %{status: :awaiting_tools} = state) do
    case find_subagent_task(state, child_id) do
      {task_id, _} ->
        send(self(), {:task_result, task_id, {:error, "Sub-agent failed: #{error}"}})
        {:noreply, %{state | pending_subagents: Map.delete(state.pending_subagents, child_id)}}

      nil ->
        {:noreply, state}
    end
  end

  # Ignore child PubSub events when not awaiting tools
  def handle_info({event, %{agent_id: _}}, state) when event in [:completed, :error, :agent_started, :llm_response, :tool_call, :tool_result, :waiting_timer] do
    {:noreply, state}
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
    %{state | status: :idle, retry_count: 0}
  end

  defp finish_run(state) do
    %{state | status: :idle, retry_count: 0, messages: []}
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
    |> Kernel.<>("\n\nCurrent date: #{Date.utc_today()}.")
  end

  defp maybe_append_summary(prompt, %{conversation: %{summary: summary}})
       when is_binary(summary) and summary != "" do
    prompt <> "\n\nSummary of earlier conversation: " <> summary
  end

  defp maybe_append_summary(prompt, _state), do: prompt

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
      {messages, step, resume_action} = replay_from_events(initial_messages, events)

      {:ok,
       base_state
       |> Map.put(:run, run)
       |> Map.put(:messages, messages)
       |> Map.put(:step, step)
       |> Map.put(:status, :running)
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
        replay_events_onto(normalize_messages(messages), step, [], post_checkpoint)

      nil ->
        replay_events_onto(initial_messages, 0, [], events)
    end
  end

  defp replay_events_onto(messages, step, pending_tool_calls, events) do
    {msgs, current_step, pending_calls} =
      Enum.reduce(events, {messages, step, pending_tool_calls}, fn event,
                                                                    {msgs, current_step, pending_calls} ->
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

            {msgs ++ [assistant_msg], event.payload["step"] || current_step, tool_calls}

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

            {msgs ++ [tool_msg], current_step,
             remove_pending_tool_call(pending_calls, event.payload["tool_call_id"])}

          "tool_duplicate" ->
            {msgs, current_step, remove_pending_tool_call(pending_calls, event.payload["tool_call_id"])}

          "subagent_launched" ->
            # Track as a pending tool call so it gets re-dispatched on resume
            synthetic_tc = %{
              "id" => event.payload["tool_call_id"],
              "name" => "launch_agent",
              "arguments" => %{
                "agent_name" => event.payload["child_agent_name"]
              }
            }

            {msgs, current_step, pending_calls ++ [synthetic_tc]}

          "waiting_for_timer" ->
            {msgs, current_step, pending_calls}

          type when type in ["checkpoint_saved", "checkpoint"] ->
            {normalize_messages(event.payload["messages"]), event.payload["step"], []}

          _ ->
            {msgs, current_step, pending_calls}
        end
      end)

    resume_action =
      if pending_calls != [], do: {:resume_tools, pending_calls}, else: :llm_loop

    {msgs, current_step, resume_action}
  end

  defp remove_pending_tool_call(pending_calls, tool_call_id) do
    Enum.reject(pending_calls, fn tc -> tc["id"] == tool_call_id end)
  end

  defp find_subagent_task(state, child_agent_id) do
    case Map.get(state.pending_subagents, child_agent_id) do
      %{task_id: task_id, tool_call_id: tool_call_id} -> {task_id, tool_call_id}
      nil -> nil
    end
  end

  defp append(run, {:ok, event}), do: Runs.append_event(run, event)
  defp append(_run, {:error, reason}), do: {:error, reason}

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

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
