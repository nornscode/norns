defmodule Norns.Agents.Process do
  @moduledoc """
  Durable agent GenServer. Runs an LLM-tool loop, persisting every step
  as a RunEvent so it can resume after a crash.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Norns.{Agents, Conversations, Runs}
  alias Norns.Agents.{AgentDef, SubagentPolicy, ToolPolicy}
  alias Norns.Runtime.{Content, ErrorPolicy, Errors, Events}
  alias Norns.Workers.WorkerRegistry
  alias Norns.Tools.{Builtins, Idempotency, Tool}
  @task_timeout_ms 300_000  # 5 minutes

  # -- Public API --

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    conversation_key = Keyword.get(opts, :conversation_key, "default")
    name = {:via, Registry, {Norns.AgentRegistry, {tenant_id, agent_id, conversation_key}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a run on this agent.

  Options:

    * `:context` — extra context map merged into the run input
    * `:parent_run_id` / `:depth` — lineage, set when this run is a sub-agent
      launched by another run. Absent for user-initiated runs.
    * `:trigger_type` — what started the run: `"message"` (default) or
      `"schedule"` (cron trigger).
    * `:gard_id` — bind this run to a gard: all tool dispatch goes only to
      workers in that gard. Per-run, not per-process.
  """
  def send_message(pid, content, opts \\ []) when is_binary(content) or is_map(content) do
    lineage =
      opts
      |> Keyword.take([:context, :parent_run_id, :depth, :trigger_type, :gard_id])
      |> Keyword.put_new(:depth, 0)

    GenServer.call(pid, {:send_message, content, lineage}, 10_000)
  end

  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc "Deliver a human's answer to an agent parked in `:waiting` on `ask_human`."
  def reply_to_human(pid, answer) when is_binary(answer) or is_map(answer) do
    GenServer.call(pid, {:reply_to_human, answer}, 10_000)
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    conversation_key = Keyword.get(opts, :conversation_key, "default")
    resume_run_id = Keyword.get(opts, :resume_run_id)

    agent = Agents.get_agent!(agent_id)

    explicit_tools = Keyword.get(opts, :tools, [])
    max_steps_override = Keyword.get(opts, :max_steps)

    agent_def =
      Keyword.get_lazy(opts, :agent_def, fn ->
        worker_tools = WorkerRegistry.available_tools(tenant_id)
        tools = explicit_tools ++ worker_tools

        def_opts = [tools: tools]
        base_def = AgentDef.from_agent(agent, def_opts)

        if max_steps_override, do: %{base_def | max_steps: max_steps_override}, else: base_def
      end)

    state = %{
      agent_id: agent_id,
      tenant_id: tenant_id,
      conversation_key: conversation_key,
      agent: agent,
      agent_def: agent_def,
      explicit_tools: explicit_tools,
      max_steps_override: max_steps_override,
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
      pending_human: nil,
      gard_id: nil,
      resume_action: nil,
      test_pid: Keyword.get(opts, :test_pid),
      input_tokens: 0,
      output_tokens: 0,
      # Compaction (context_policy): the running summary of folded history,
      # the input-token count of the last LLM response, and the compaction
      # task in flight, if any.
      summary: nil,
      last_input_tokens: nil,
      pending_compaction: nil
    }

    state = load_conversation_state(state)

    if resume_run_id do
      {:ok, state, {:continue, {:resume, resume_run_id}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:send_message, content, opts}, _from, %{status: :idle} = state) do
    context = Keyword.get(opts, :context)
    gard_id = Keyword.get(opts, :gard_id)
    state = load_conversation_state(state)
    messages = messages_for_new_run(state, content, context)

    input = %{"user_message" => content}
    input = if context, do: Map.put(input, "context", context), else: input

    {:ok, run} =
      Runs.create_run(%{
        agent_id: state.agent_id,
        tenant_id: state.tenant_id,
        conversation_id: state.conversation && state.conversation.id,
        trigger_type: Keyword.get(opts, :trigger_type, "message"),
        input: input,
        status: "pending",
        parent_run_id: Keyword.get(opts, :parent_run_id),
        depth: Keyword.get(opts, :depth, 0),
        gard_id: gard_id
      })

    append(run, Events.run_started())
    {:ok, run} = Runs.update_run(run, %{status: "running"})

    state = %{state | run: run, messages: messages, step: 0, retry_count: 0, status: :running, gard_id: gard_id, resume_action: nil}

    broadcast(state, :agent_started, %{run_id: run.id})
    {:reply, {:ok, run.id}, state, {:continue, :llm_loop}}
  end

  # A message arriving while parked on ask_human is the answer. Conversational
  # clients (a Slack bot, a chat UI) shouldn't have to track agent state and
  # switch endpoints mid-conversation — the human just replies.
  def handle_call({:send_message, content, _opts}, _from, %{status: :waiting, pending_human: pending} = state)
      when not is_nil(pending) do
    deliver_human_answer(state, content, {:ok, state.run.id})
  end

  def handle_call({:send_message, _content, _opts}, _from, state) do
    Logger.warning("Agent #{state.agent_id} received message while #{state.status}, ignoring")
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:reply_to_human, answer}, _from, %{status: :waiting, pending_human: pending} = state)
      when not is_nil(pending) do
    deliver_human_answer(state, answer, :ok)
  end

  def handle_call({:reply_to_human, _answer}, _from, state) do
    {:reply, {:error, :not_waiting}, state}
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

  # Resolve the parked ask_human call with the human's answer and resume.
  # Shared by the dedicated reply call and by a plain message arriving while
  # the agent is parked.
  defp deliver_human_answer(%{pending_human: pending} = state, answer, reply_value) do
    append(state.run, Events.tool_result(%{
      "tool_call_id" => pending.tool_call_id,
      "name" => "ask_human",
      "content" => answer,
      "is_error" => false,
      "step" => state.step
    }))

    broadcast(state, :tool_result, %{
      tool_call_id: pending.tool_call_id,
      name: "ask_human",
      content: answer
    })

    answer_result = %{
      role: "tool",
      tool_call_id: pending.tool_call_id,
      name: "ask_human",
      content: answer
    }

    all_results = pending.pending_results ++ [answer_result]
    {:ok, run} = Runs.update_run(state.run, %{status: "running"})
    state = %{state | run: run, pending_human: nil}

    case handle_pause_or_continue(state, pending.wait_blocks, [], all_results, pending.log_calls?) do
      {:noreply, new_state} -> {:reply, reply_value, new_state}
      {:noreply, new_state, continue} -> {:reply, reply_value, new_state, continue}
    end
  end

  @impl true
  def handle_continue(:llm_loop, state) do
    state = refresh_agent_def(state)
    max_steps = state.agent_def.max_steps

    cond do
      state.step >= max_steps ->
        {:noreply, complete_with_error(state, "Max steps (#{max_steps}) exceeded")}

      compaction = compaction_needed(state) ->
        dispatch_compaction(state, compaction)

      true ->
        dispatch_llm(state)
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

  # Re-reads the agent record before every LLM dispatch so REST updates to
  # model/system_prompt/max_steps/etc. take effect on the next step, without
  # requiring the process to be restarted.
  defp refresh_agent_def(state) do
    agent = Agents.get_agent!(state.agent_id)
    base_def = AgentDef.from_agent(agent, tools: state.explicit_tools)

    agent_def =
      if state.max_steps_override, do: %{base_def | max_steps: state.max_steps_override}, else: base_def

    %{state | agent: agent, agent_def: agent_def}
  end

  defp dispatch_tool_execution(state, tool_use_blocks, log_calls?) do
    {wait_blocks, remaining} =
      Enum.split_with(tool_use_blocks, fn block -> block["name"] == "wait" end)

    {ask_blocks, remaining} =
      Enum.split_with(remaining, fn block -> block["name"] == "ask_human" end)

    {list_agents_blocks, remaining} =
      Enum.split_with(remaining, fn block -> block["name"] == "list_agents" end)

    {launch_agent_blocks, regular_blocks} =
      Enum.split_with(remaining, fn block -> block["name"] == "launch_agent" end)

    # Enforce the tool policy at dispatch, not just at advertisement — the
    # model can name a tool it was never offered, or the allowlist can have
    # changed mid-conversation. Built-ins were already split out above.
    {denied_blocks, regular_blocks} =
      Enum.split_with(regular_blocks, fn block ->
        ToolPolicy.authorize(state.agent_def.tool_policy, block["name"]) != :ok
      end)

    denied_results = resolve_denied_tools(state, denied_blocks, log_calls?)

    # Resolve list_agents synchronously — results go into the pool immediately
    list_agents_results = resolve_list_agents(state, list_agents_blocks, log_calls?)

    # Resolve launch_agent — may produce immediate error results or async pending tasks
    {launch_results, launch_pending, state} =
      resolve_launch_agents(state, launch_agent_blocks, log_calls?)

    sync_results = denied_results ++ list_agents_results ++ launch_results

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

    if has_async do
      worker_pending =
        Enum.map(all_async_blocks, fn tc ->
          {:ok, task_id} =
            WorkerRegistry.dispatch_task(state.tenant_id, tc["name"], tc["arguments"],
              from_pid: self(),
              agent_id: state.agent_id,
              run_id: state.run.id,
              gard: state.gard_id
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
             ask_blocks: ask_blocks,
             log_calls?: log_calls?
           }
       }}
    else
      handle_pause_or_continue(state, wait_blocks, ask_blocks, sync_results, log_calls?)
    end
  end

  # A denied tool call gets an error result back to the LLM (recoverable — it
  # can pick an allowed tool) and a tool_call_denied audit event, mirroring
  # the subagent decision trail.
  defp resolve_denied_tools(state, blocks, log_calls?) do
    Enum.map(blocks, fn block ->
      if log_calls? do
        append(state.run, Events.tool_call(%{
          "tool_call_id" => block["id"],
          "name" => block["name"],
          "arguments" => block["arguments"] || %{},
          "step" => state.step
        }))
      end

      policy = state.agent_def.tool_policy

      append(state.run, Events.build("tool_call_denied", %{
        "requesting_agent_id" => state.agent_id,
        "requesting_agent_name" => (state.agent && state.agent.name) || "",
        "mode" => to_string(policy.mode),
        "tool_name" => block["name"],
        "reason" => "not_allowlisted",
        "step" => state.step
      }))

      make_system_result(state, block, block["name"], "tool_denied", %{"tool_name" => block["name"]}, "", true)
    end)
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

      policy = state.agent_def.subagents

      case SubagentPolicy.authorize_list(policy) do
        {:error, reason} ->
          append_subagent_decision(state, "subagent_list_denied", policy, nil, reason)

          make_system_result(state, block, "list_agents", "subagent_list_denied", %{}, "", true)

        :ok ->
          append_subagent_decision(state, "subagent_list_allowed", policy, nil, nil)

          agents =
            state.tenant_id
            |> Agents.list_agents()
            |> Enum.reject(&(&1.id == state.agent_id))
            |> Enum.map(fn a -> %{"name" => a.name, "purpose" => a.purpose || ""} end)

          make_system_result(state, block, "list_agents", "list_agents", %{"agents" => agents}, "", false)
      end
    end)
  end

  # Audit trail for every subagent permission decision, allowed or denied.
  defp append_subagent_decision(state, event_type, policy, target_name, reason) do
    payload = %{
      "requesting_agent_id" => state.agent_id,
      "requesting_agent_name" => (state.agent && state.agent.name) || "",
      "mode" => to_string(policy.mode),
      "step" => state.step
    }

    payload = if target_name, do: Map.put(payload, "target_agent_name", target_name), else: payload
    payload = if reason, do: Map.put(payload, "reason", reason), else: payload

    append(state.run, Events.build(event_type, payload))
  end

  defp resolve_launch_agents(state, blocks, log_calls?) do
    Enum.reduce(blocks, {[], [], state}, fn block, acc ->
      case block["child_run_id"] do
        nil -> launch_subagent(block, log_calls?, acc)
        child_run_id -> reattach_subagent(block, child_run_id, acc)
      end
    end)
  end

  # Replay tagged this call with the run it already started, so the child exists
  # and may well have finished. Relaunching would pay for its work a second time
  # and orphan the run the parent's own event log points at.
  defp reattach_subagent(block, child_run_id, {results, pending, st}) do
    case Runs.get_run(child_run_id) do
      nil ->
        result = make_system_result(st, block, "launch_agent", "subagent_missing", %{"run_id" => child_run_id}, "", true)
        {results ++ [result], pending, st}

      child_run ->
        # Subscribe before reading the status: if the child finishes in the gap
        # the broadcast still reaches us, and if it finished earlier the row
        # tells us. Both firing is harmless — the second finds no pending entry.
        Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{child_run.agent_id}")
        reattach_to_status(block, Runs.get_run!(child_run_id), {results, pending, st})
    end
  end

  defp reattach_to_status(block, %{status: "completed"} = child_run, {results, pending, st}) do
    {kind, data, content} = subagent_outcome(child_run.id, "completed", child_run.output)
    {results ++ [make_system_result(st, block, "launch_agent", kind, data, content, false)], pending, st}
  end

  defp reattach_to_status(block, %{status: "failed"} = child_run, {results, pending, st}) do
    error = get_in(child_run.failure_metadata, ["error"]) || "sub-agent run failed"
    {kind, data, content} = subagent_outcome(child_run.id, "failed", error)
    {results ++ [make_system_result(st, block, "launch_agent", kind, data, content, true)], pending, st}
  end

  defp reattach_to_status(block, child_run, {results, pending, st}) do
    ensure_child_running(child_run)
    task_id = "subagent_#{block["id"]}"

    st =
      put_in(st.pending_subagents[child_run.id], %{
        task_id: task_id,
        run_id: child_run.id,
        tool_call_id: block["id"]
      })

    {results, pending ++ [{task_id, block}], st}
  end

  # A partial crash can leave the parent resumed and the child not. Nothing else
  # will restart it, so the parent would wait out the task timeout for a result
  # no process is going to produce.
  defp ensure_child_running(child_run) do
    conversation_key = (child_run.conversation && child_run.conversation.key) || "default"

    if Norns.Agents.Registry.alive?(child_run.tenant_id, child_run.agent_id, conversation_key) do
      :ok
    else
      Norns.Agents.Registry.resume_agent(child_run.id, child_run.agent_id, child_run.tenant_id,
        conversation_key: conversation_key
      )
    end
  end

  defp launch_subagent(block, log_calls?, {results, pending, st}) do
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
    context = get_in(block, ["arguments", "context"])

    # Lookup is tenant-scoped, so a cross-tenant target reads as not found.
    child_agent = Agents.get_agent_by_name(st.tenant_id, agent_name)
    policy = st.agent_def.subagents
    authorization = SubagentPolicy.authorize_launch(policy, agent_name)

    # Absolute depth from the root run, not distance from this agent.
    child_depth = (st.run && st.run.depth && st.run.depth + 1) || 1
    depth_authorization = SubagentPolicy.authorize_depth(policy, child_depth)

    cond do
      match?({:error, _}, authorization) ->
        {:error, reason} = authorization
        append_subagent_decision(st, "subagent_launch_denied", policy, agent_name, reason)

        data = %{"agent_name" => agent_name, "reason" => reason}
        result = make_system_result(st, block, "launch_agent", "subagent_denied", data, "", true)
        {results ++ [result], pending, st}

      match?({:error, _}, depth_authorization) ->
        append_subagent_decision(st, "subagent_launch_denied", policy, agent_name, "max_depth")

        data = %{"agent_name" => agent_name, "reason" => "max_depth", "max_depth" => policy.max_depth}
        result = make_system_result(st, block, "launch_agent", "subagent_denied", data, "", true)
        {results ++ [result], pending, st}

      is_nil(child_agent) ->
        data = %{"agent_name" => agent_name}
        result = make_system_result(st, block, "launch_agent", "subagent_not_found", data, "", true)
        {results ++ [result], pending, st}

      child_agent.id == st.agent_id ->
        data = %{"agent_name" => agent_name}
        result = make_system_result(st, block, "launch_agent", "subagent_self", data, "", true)
        {results ++ [result], pending, st}

      true ->
        append_subagent_decision(st, "subagent_launch_allowed", policy, agent_name, nil)

        # Subscribe to child agent events
        Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{child_agent.id}")

        conversation_key = "subagent_#{block["id"]}_#{System.unique_integer([:positive])}"

        # A child working on the same task should see the same filesystem —
        # inherit the parent's gard unless the call names a different one.
        child_gard = get_in(block, ["arguments", "gard_id"]) || st.gard_id

        spawn_opts = [
          conversation_key: conversation_key,
          parent_run_id: st.run && st.run.id,
          depth: child_depth,
          gard_id: child_gard
        ]

        spawn_opts = if context, do: Keyword.put(spawn_opts, :context, context), else: spawn_opts

        case Norns.Agents.Registry.send_message(st.tenant_id, child_agent.id, message, spawn_opts) do
          {:ok, child_run_id} ->
            task_id = "subagent_#{block["id"]}"

            launched_payload = %{
              "tool_call_id" => block["id"],
              "child_agent_name" => agent_name,
              "child_run_id" => to_string(child_run_id),
              "step" => st.step
            }

            launched_payload =
              if context, do: Map.put(launched_payload, "context", context), else: launched_payload

            append(st.run, Events.subagent_launched(launched_payload))

            broadcast(st, :tool_call, %{name: "launch_agent", arguments: block["arguments"]})

            # Synthetic tool_call block for pending task tracking
            synthetic_tc = %{
              "id" => block["id"],
              "name" => "launch_agent",
              "arguments" => block["arguments"]
            }

            st =
              put_in(st.pending_subagents[child_run_id], %{
                task_id: task_id,
                run_id: child_run_id,
                tool_call_id: block["id"]
              })

            {results, pending ++ [{task_id, synthetic_tc}], st}

          {:error, reason} ->
            data = %{"agent_name" => agent_name, "reason" => inspect(reason)}
            result = make_system_result(st, block, "launch_agent", "subagent_launch_failed", data, "", true)
            {results ++ [result], pending, st}
        end
    end
  end

  # A tool result the orchestrator resolves itself. Core writes no prose for
  # the model: the message carries a `kind` and envelope `data`, and the LLM
  # worker renders it (Format.render_message/1). Tenant content on such a
  # result — a child's output, an error a worker raised — stays in `content`.
  defp make_system_result(state, block, name, kind, data, content, is_error?) do
    make_tool_result(state, block, name, content, is_error?, %{"kind" => kind, "data" => data})
  end

  defp make_tool_result(state, block, name, content, is_error?, extra) do
    append(state.run, Events.tool_result(Map.merge(%{
      "tool_call_id" => block["id"],
      "name" => name,
      "content" => content,
      "is_error" => is_error?,
      "step" => state.step
    }, extra)))

    broadcast(state, :tool_result, Map.merge(%{tool_call_id: block["id"], name: name, content: content}, atomize(extra)))

    result = %{role: "tool", tool_call_id: block["id"], name: name, content: content}
    result = Map.merge(result, atomize(extra))
    if is_error?, do: Map.put(result, :is_error, true), else: result
  end

  defp atomize(%{"kind" => kind, "data" => data}), do: %{kind: kind, data: data}
  defp atomize(_), do: %{}

  defp handle_pause_or_continue(state, wait_blocks, ask_blocks, regular_results, log_calls?) do
    cond do
      # Human input outranks a timer: a sleep can always be re-armed after the
      # answer arrives, so carry any co-emitted wait blocks forward.
      ask_blocks != [] ->
        [ask_block | _] = ask_blocks
        question = get_in(ask_block, ["arguments", "question"]) || ""

        if log_calls? do
          append(state.run, Events.tool_call(%{
            "tool_call_id" => ask_block["id"],
            "name" => "ask_human",
            "arguments" => ask_block["arguments"],
            "step" => state.step
          }))
        end

        append(state.run, Events.build("waiting_for_user", %{
          "tool_call_id" => ask_block["id"],
          "question" => question,
          "step" => state.step
        }))

        broadcast(state, :waiting_for_user, %{tool_call_id: ask_block["id"], question: question})

        # Surface the pause on the run itself so polling clients can tell
        # "working" from "waiting on you" without scraping the event log.
        {:ok, run} = Runs.update_run(state.run, %{status: "waiting"})

        {:noreply,
         %{state
           | run: run,
             status: :waiting,
             pending_human: %{
               tool_call_id: ask_block["id"],
               question: question,
               pending_results: regular_results,
               wait_blocks: wait_blocks,
               log_calls?: log_calls?
             }}}

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
  def handle_info(
        {:task_result, task_id, result},
        %{status: :awaiting_llm, pending_llm_task: task_id, pending_compaction: %{} = compaction} = state
      ) do
    cancel_timer(state.task_timer)
    state = %{state | status: :running, pending_llm_task: nil, task_timer: nil, pending_compaction: nil}

    case result do
      {:ok, %{"content" => summary} = resp} when (is_binary(summary) and summary != "") or is_map(summary) ->
        usage = %{
          "input_tokens" => get_in(resp, ["usage", "input_tokens"]) || 0,
          "output_tokens" => get_in(resp, ["usage", "output_tokens"]) || 0
        }

        state = add_usage(state, usage["input_tokens"], usage["output_tokens"])
        {:noreply, apply_compaction(state, compaction, summary, usage), {:continue, :llm_loop}}

      other ->
        # No summary: carry on uncompacted and try again after the next response.
        Logger.warning("Compaction returned no summary (#{inspect(other, limit: 5)}); continuing uncompacted")
        {:noreply, %{state | last_input_tokens: nil}, {:continue, :llm_loop}}
    end
  end

  def handle_info({:task_result, task_id, result}, %{status: :awaiting_llm, pending_llm_task: task_id} = state) do
    cancel_timer(state.task_timer)
    state = %{state | status: :running, pending_llm_task: nil, task_timer: nil}

    case result do
      {:ok, %{"finish_reason" => finish_reason, "usage" => usage} = resp} ->
        response = %{
          content: resp["content"] || "",
          final_output: resp["final_output"],
          tool_calls: resp["tool_calls"] || [],
          finish_reason: finish_reason,
          usage: %{
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          }
        }

        state =
          %{state | retry_count: 0, last_input_tokens: response.usage.input_tokens}
          |> add_usage(response.usage.input_tokens, response.usage.output_tokens)

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
        # Build the tool result as a neutral message. A sub-agent outcome
        # arrives kinded; a worker result is content, forwarded verbatim.
        {status, content, extra} =
          case result do
            {:ok, {:kind, kind, data, content}} -> {:ok, content, %{"kind" => kind, "data" => data}}
            {:error, {:kind, kind, data, content}} -> {:error, content, %{"kind" => kind, "data" => data}}
            {:ok, content} -> {:ok, content, %{}}
            {:error, reason} -> {:error, if(Content.valid?(reason), do: reason, else: inspect(reason)), %{}}
          end

        tool_msg = %{
          role: "tool",
          tool_call_id: tc["id"],
          name: tc["name"],
          content: content
        }

        tool_msg = Map.merge(tool_msg, atomize(extra))
        tool_msg = if status == :error, do: Map.put(tool_msg, :is_error, true), else: tool_msg

        # Log the result event
        append(
          state.run,
          Events.tool_result(Map.merge(%{
            "tool_call_id" => tc["id"],
            "name" => tc["name"],
            "content" => content,
            "is_error" => status == :error,
            "step" => state.step
          }, extra))
        )

        broadcast(state, :tool_result, Map.merge(%{tool_call_id: tc["id"], name: tc["name"], content: content}, atomize(extra)))

        results = Map.put(pending.results, tc["id"], tool_msg)

        if map_size(remaining_tasks) == 0 do
          # All tools done
          cancel_timer(state.task_timer)
          maybe_invoke_test_hook(state, :after_tool_execution_before_result_persisted, %{results: Map.values(results), step: state.step})

          all_results = Map.values(results)

          state = %{state | pending_tool_tasks: nil, task_timer: nil}

          handle_pause_or_continue(
            state,
            pending.wait_blocks || [],
            pending.ask_blocks || [],
            all_results,
            pending.log_calls?
          )
        else
          # Still waiting for more tools
          updated_pending = %{pending | tasks: remaining_tasks, results: results}
          {:noreply, %{state | pending_tool_tasks: updated_pending}}
        end

    end
  end

  def handle_info({:timer_complete, tool_call_id, pending_results, log_calls?}, %{status: :waiting_timer} = state) do
    # Timer fired — deliver the wait tool result and continue
    wait_result = make_system_result(state, %{"id" => tool_call_id}, "wait", "timer_completed", %{}, "", false)

    all_results = pending_results ++ [wait_result]
    state = %{state | task_timer: nil}

    handle_pause_or_continue(state, [], [], all_results, log_calls?)
  end

  def handle_info({:task_timeout, task_id}, %{pending_llm_task: task_id, pending_compaction: %{}} = state) do
    Logger.warning("Compaction task #{task_id} timed out after #{@task_timeout_ms}ms; continuing uncompacted")
    state = %{state | status: :running, pending_llm_task: nil, task_timer: nil, pending_compaction: nil, last_input_tokens: nil}
    {:noreply, state, {:continue, :llm_loop}}
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
  def handle_info({:completed, %{run_id: child_run_id, output: output}}, %{status: :awaiting_tools} = state) do
    {:noreply,
     resolve_subagent(state, child_run_id, fn ->
       {:ok, {:kind, "subagent_completed", %{"run_id" => child_run_id, "status" => "completed"}, output || ""}}
     end)}
  end

  # Child agent failed — convert to task_result error
  def handle_info({:error, %{run_id: child_run_id, error: error}}, %{status: :awaiting_tools} = state) do
    {:noreply,
     resolve_subagent(state, child_run_id, fn ->
       {:error, {:kind, "subagent_failed", %{"run_id" => child_run_id, "status" => "failed"}, error || ""}}
     end)}
  end

  # Ignore child PubSub events we don't act on. A reattached child is resumed
  # by its parent, so `:agent_resumed` reaches us too.
  def handle_info({event, %{agent_id: _}}, state)
      when event in [
             :completed,
             :error,
             :agent_started,
             :agent_resumed,
             :llm_response,
             :tool_call,
             :tool_result,
             :waiting_timer,
             :waiting_for_user
           ] do
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

  defp dispatch_llm(state) do
    state = %{state | step: state.step + 1}

    # Resolve tools at dispatch time: built-ins + agent_def tools + worker-registered
    # tools, the latter two filtered by the agent's tool policy. Built-ins are
    # orchestrator semantics — launch_agent/list_agents have their own policy.
    policy = state.agent_def.tool_policy
    builtin_tools = Builtins.all()
    agent_tools = ToolPolicy.filter(policy, state.agent_def.tools)

    worker_tools =
      ToolPolicy.filter(
        policy,
        WorkerRegistry.available_tools(state.tenant_id, gard: state.gard_id)
      )
    all_tools = (builtin_tools ++ agent_tools ++ worker_tools) |> Enum.uniq_by(& &1.name)
    tools = Enum.map(all_tools, &Tool.to_api_format/1)

    messages_for_llm = apply_context_strategy(state)

    # The def's prompt goes out verbatim. The conversation summary and the
    # date ride in the envelope; the worker composes the prompt the model
    # sees (Format.compose_system_prompt/1) — core writes no prose.
    system_prompt = state.agent_def.system_prompt
    summary = conversation_summary(state)

    append(state.run, Events.llm_request(%{
      "step" => state.step,
      "message_count" => length(messages_for_llm),
      "messages" => messages_for_llm,
      "system_prompt" => system_prompt,
      "summary" => summary,
      "model" => state.agent_def.model,
      # Names only. Enough to tell later whether the model called something it
      # was never offered, or was offered tools and ignored them — neither of
      # which is recoverable from the log without this. Full schemas would
      # bloat every row for no analytical gain.
      "tools" => Enum.map(all_tools, & &1.name)
    }))

    # Dispatch LLM call to worker — non-blocking, neutral format
    llm_task = %{
      model: state.agent_def.model,
      system_prompt: system_prompt,
      summary: summary,
      date: Date.to_iso8601(Date.utc_today()),
      messages: messages_for_llm,
      tools: tools,
      # Workers skip their own tool-result elision when core manages the
      # context; the policy is envelope, not content.
      context_policy: envelope_context_policy(state.agent_def.context_policy),
      # The cap on this response. nil leaves it to the worker.
      max_tokens: state.agent_def.max_tokens,
      agent_id: state.agent_id,
      run_id: state.run.id,
      step: state.step
    }

    {:ok, task_id} =
      WorkerRegistry.dispatch_llm_task(state.tenant_id, llm_task,
        from_pid: self(),
        gard: state.gard_id
      )

    timer = Process.send_after(self(), {:task_timeout, task_id}, @task_timeout_ms)
    {:noreply, %{state | status: :awaiting_llm, pending_llm_task: task_id, task_timer: timer}}
  end

  # -- Compaction --
  #
  # A `context_policy` on the def folds the older history into a summary once
  # an LLM response reports `compact_at` input tokens. The summarisation is an
  # LLM task like any other (`purpose: "compact"`): the worker writes the
  # prose and the summary comes back as content, which core stores in
  # `context_compacted`, in the next checkpoint, and on the conversation,
  # without reading it.

  defp compaction_needed(%{agent_def: %{context_policy: %{compact_at: at, keep: keep}}, last_input_tokens: tokens} = state)
       when is_integer(tokens) and tokens >= at do
    drop = backtrack_to_pair_boundary(state.messages, max(length(state.messages) - keep, 0))
    if drop > 0, do: %{drop: drop}, else: nil
  end

  defp compaction_needed(_state), do: nil

  defp dispatch_compaction(state, %{drop: drop} = compaction) do
    task = %{
      purpose: "compact",
      model: state.agent_def.model,
      system_prompt: state.agent_def.system_prompt,
      summary: state.summary,
      date: Date.to_iso8601(Date.utc_today()),
      messages: Enum.take(state.messages, drop),
      tools: [],
      agent_id: state.agent_id,
      run_id: state.run.id,
      step: state.step
    }

    {:ok, task_id} =
      WorkerRegistry.dispatch_llm_task(state.tenant_id, task, from_pid: self(), gard: state.gard_id)

    timer = Process.send_after(self(), {:task_timeout, task_id}, @task_timeout_ms)

    {:noreply,
     %{state | status: :awaiting_llm, pending_llm_task: task_id, task_timer: timer, pending_compaction: compaction}}
  end

  defp apply_compaction(state, %{drop: drop}, summary, usage) do
    kept = Enum.drop(state.messages, drop)

    append(state.run, Events.context_compacted(%{
      "step" => state.step,
      "dropped" => drop,
      "kept" => length(kept),
      "summary" => summary,
      "usage" => usage
    }))

    state = %{state | messages: kept, summary: summary, last_input_tokens: nil}

    # A checkpoint right away, whatever the policy: the message base changed.
    append(state.run, Events.checkpoint_saved(%{
      "messages" => kept,
      "step" => state.step,
      "summary" => summary
    }))

    broadcast(state, :context_compacted, %{step: state.step, dropped: drop, kept: length(kept)})
    persist_conversation_messages(state)
  end

  defp envelope_context_policy(%{compact_at: at, keep: keep}), do: %{compact_at: at, keep: keep}
  defp envelope_context_policy(_), do: nil

  defp add_usage(state, input_tokens, output_tokens) do
    state = %{state |
      input_tokens: state.input_tokens + input_tokens,
      output_tokens: state.output_tokens + output_tokens
    }

    {:ok, run} = Runs.update_run(state.run, %{input_tokens: state.input_tokens, output_tokens: state.output_tokens})
    %{state | run: run}
  end

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
        {:noreply, complete_successfully(state, response)}

      "tool_call" ->
        {:noreply, state, {:continue, {:execute_tools, response.tool_calls}}}

      "length" ->
        # The turn hit the output cap. What came back is real, only cut
        # short, so the run completes rather than throwing it away. The
        # truncation rides on the llm_response event as finish_reason,
        # which is how a client knows to say so.
        Logger.warning(
          "run #{state.run.id} step #{state.step}: response truncated at the output limit"
        )

        {:noreply, complete_successfully(state, response)}

      other ->
        Logger.info("Unknown finish_reason #{inspect(other)}, treating as stop")
        {:noreply, complete_successfully(state, response)}
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

  # The worker decides what the run's output is (`final_output`, see
  # Format.final_output/2) because deciding needs to read text. Core stores
  # what it was told; an older worker that reports no final_output gets the
  # last turn's content as-is.
  defp complete_successfully(state, response) do
    output = response.final_output || response.content || ""

    append(state.run, Events.run_completed(%{"output" => output}))

    {:ok, run} =
      Runs.update_run(state.run, %{status: "completed", output: Content.to_column(output), failure_metadata: %{}})

    state = %{state | run: run}
    state = persist_conversation_messages(state)

    broadcast(state, :completed, %{output: output})
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

  defp finish_run(state) do
    %{state | status: :idle, retry_count: 0}
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
        Events.checkpoint_saved(
          %{"messages" => state.messages, "step" => state.step}
          |> maybe_put("summary", state.summary)
        )
      )
    end

    state
  end

  defp conversation_summary(%{summary: summary}) when summary not in [nil, ""], do: summary
  defp conversation_summary(_state), do: nil

  defp load_conversation_state(state) do
    if state.conversation do
      state
    else
      {:ok, conversation} =
        Conversations.find_or_create_conversation(
          state.agent_id,
          state.tenant_id,
          state.conversation_key
        )

      %{state | conversation: conversation, messages: normalize_messages(conversation.messages), summary: conversation.summary}
    end
  end

  defp messages_for_new_run(%{messages: messages}, content, context) do
    context_messages = build_context_messages(context)
    messages ++ context_messages ++ [%{role: "user", content: content}]
  end

  defp build_context_messages(nil), do: []
  defp build_context_messages(context) when is_map(context) do
    inherited_messages = normalize_context_messages(context["messages"] || context[:messages])
    data_messages = build_data_message(context["data"] || context[:data])
    inherited_messages ++ data_messages
  end
  defp build_context_messages(_), do: []

  defp normalize_context_messages(nil), do: []
  defp normalize_context_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} -> %{role: role, content: content}
      %{"role" => role, "content" => content} -> %{role: role, content: content}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end
  defp normalize_context_messages(_), do: []

  # The parent's data is forwarded as it came; the LLM worker renders the
  # preamble the model reads.
  defp build_data_message(nil), do: []
  defp build_data_message(data) when data == %{}, do: []
  defp build_data_message(data) when is_map(data) or is_binary(data) do
    [%{role: "user", kind: "inherited_context", content: data}]
  end
  defp build_data_message(_), do: []

  defp persist_conversation_messages(%{conversation: conversation} = state)
       when not is_nil(conversation) do
    messages = stamp_run_id(state.messages, state.run && state.run.id)

    {:ok, conversation} =
      Conversations.update_conversation(conversation, %{
        messages: messages,
        summary: Content.to_column(state.summary)
      })

    # Kept in state too: a conversation-mode process stays alive between
    # runs, and an unstamped list here would be restamped by the next run.
    %{state | conversation: conversation, messages: messages}
  end

  defp persist_conversation_messages(state), do: state

  # Which run each turn belongs to. Envelope, not content — we neither read
  # nor write what the message says — and it is what lets a client that was
  # not watching draw the same run boundaries as one that was. Turns carried
  # over from earlier runs keep the id they were stamped with.
  defp stamp_run_id(messages, nil), do: messages

  defp stamp_run_id(messages, run_id) do
    Enum.map(messages, fn
      %{run_id: existing} = message when not is_nil(existing) -> message
      message -> Map.put(message, :run_id, run_id)
    end)
  end

  defp apply_context_strategy(%{agent_def: %{context_strategy: :sliding_window}} = state) do
    window = max(state.agent_def.context_window, 1)
    drop = max(length(state.messages) - window, 0)
    drop = backtrack_to_pair_boundary(state.messages, drop)
    Enum.drop(state.messages, drop)
  end

  defp apply_context_strategy(%{messages: messages}), do: messages

  # A tool_use message is always immediately followed by its tool_result
  # message(s) (see handle_wait_or_continue/4), so a window boundary that
  # lands on a "tool" message means the boundary split a pair. Back up
  # until the boundary lands on the owning assistant message instead.
  defp backtrack_to_pair_boundary(messages, drop) when drop > 0 do
    case Enum.at(messages, drop) do
      %{role: "tool"} -> backtrack_to_pair_boundary(messages, drop - 1)
      _ -> drop
    end
  end

  defp backtrack_to_pair_boundary(_messages, drop), do: drop

  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, &normalize_message/1)
  end

  defp normalize_messages(_messages), do: []

  # In-memory messages already carry atom keys and the full neutral shape.
  defp normalize_message(%{role: _role, content: _content} = message), do: message

  # Messages reloaded from Postgres JSONB come back string-keyed. Rebuild them
  # with atom keys while preserving the tool-linkage fields (tool_calls on
  # assistant turns; tool_call_id/name/is_error on tool turns) — without these,
  # Anthropic rejects the replayed history since tool results can't be paired
  # back to their tool_use blocks.
  defp normalize_message(%{"role" => role} = m) do
    %{role: role, content: m["content"]}
    |> maybe_put(:tool_calls, m["tool_calls"])
    |> maybe_put(:tool_call_id, m["tool_call_id"])
    |> maybe_put(:name, m["name"])
    |> maybe_put(:is_error, m["is_error"])
    |> maybe_put(:kind, m["kind"])
    |> maybe_put(:data, m["data"])
    |> maybe_put(:run_id, m["run_id"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # `run_id` identifies *which* run of this agent emitted the event. A parent
  # awaiting two concurrent launches of the same child agent can only tell the
  # results apart by run, and the topic is per-agent.
  defp broadcast(state, event, payload) do
    payload =
      payload
      |> Map.put(:agent_id, state.agent_id)
      |> Map.put(:run_id, state.run && state.run.id)

    Phoenix.PubSub.broadcast(Norns.PubSub, "agent:#{state.agent_id}", {event, payload})
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
      {messages, step, resume_action, summary} = replay_from_events(initial_messages, base_state[:summary], events)
      {input_tokens, output_tokens} = sum_token_usage(events)

      {:ok,
       base_state
       |> Map.put(:run, run)
       |> Map.put(:messages, messages)
       |> Map.put(:summary, summary)
       |> Map.put(:step, step)
       |> Map.put(:status, :running)
       |> Map.put(:resume_action, resume_action)
       |> Map.put(:input_tokens, input_tokens)
       |> Map.put(:output_tokens, output_tokens)
       # The gard rides on the run row — a resumed run must keep its
       # affinity or replayed tool dispatch would leak to no-gard workers.
       |> Map.put(:gard_id, run.gard_id)}
    end
  end

  @doc """
  The history of a run as it stood after `max_step`: the messages, the
  compaction summary, and whether that step left tool calls unanswered.
  Replays the log the way resume does, stopping at the step, from the
  history the run's first LLM request carried. Used by fork.
  """
  def history_at(run, max_step) do
    all_events = Runs.list_events(run.id)

    events =
      Enum.filter(all_events, fn event ->
        case event.payload["step"] do
          step when is_integer(step) -> step <= max_step
          _ -> true
        end
      end)

    # What the run started from is what its first LLM request carried: a
    # conversation's history moves on after the run, so it cannot be read
    # back from the conversation row.
    {initial_messages, initial_summary} =
      case Enum.find(all_events, &(&1.event_type == "llm_request")) do
        %{payload: %{"messages" => msgs} = payload} when is_list(msgs) ->
          {normalize_messages(msgs), payload["summary"]}

        _ ->
          base = restore_conversation_for_run(%{conversation: nil, messages: [], summary: nil}, run)
          {initial_messages_for_replay(base, run), base.summary}
      end

    {messages, _step, resume_action, summary} = replay_from_events(initial_messages, initial_summary, events)

    %{messages: messages, summary: summary, pending_tools?: match?({:resume_tools, _}, resume_action)}
  end

  defp restore_conversation_for_run(state, run) do
    conversation = run.conversation || state.conversation
    messages = if conversation, do: normalize_messages(conversation.messages), else: []
    summary = if conversation, do: conversation.summary, else: nil
    state |> Map.put(:conversation, conversation) |> Map.put(:messages, messages) |> Map.put(:summary, summary)
  end

  defp initial_messages_for_replay(state, run) do
    messages = state.messages
    context = get_in(run.input, ["context"])
    user_message = get_in(run.input, ["user_message"])

    context_messages = build_context_messages(context)

    messages = messages ++ context_messages

    if Content.valid?(user_message) do
      messages ++ [%{role: "user", content: user_message}]
    else
      messages
    end
  end

  defp replay_from_events(initial_messages, initial_summary, events) do
    checkpoint =
      events
      |> Enum.reverse()
      |> Enum.find(fn event -> event.event_type in ["checkpoint_saved", "checkpoint"] end)

    case checkpoint do
      %{payload: %{"messages" => messages, "step" => step} = payload} ->
        post_checkpoint = Enum.drop_while(events, fn event -> event.sequence <= checkpoint.sequence end)
        replay_events_onto(normalize_messages(messages), step, [], payload["summary"] || initial_summary, post_checkpoint)

      nil ->
        replay_events_onto(initial_messages, 0, [], initial_summary, events)
    end
  end

  defp replay_events_onto(messages, step, pending_tool_calls, summary, events) do
    {msgs, current_step, pending_calls, summary} =
      Enum.reduce(events, {messages, step, pending_tool_calls, summary}, fn event,
                                                                             {msgs, current_step, pending_calls, summary} ->
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

            {msgs ++ [assistant_msg], event.payload["step"] || current_step, tool_calls, summary}

          "tool_result" ->
            tool_msg =
              %{
                role: "tool",
                tool_call_id: event.payload["tool_call_id"],
                name: event.payload["name"],
                content: event.payload["content"]
              }
              |> maybe_put(:kind, event.payload["kind"])
              |> maybe_put(:data, event.payload["data"])

            tool_msg =
              if event.payload["is_error"] do
                Map.put(tool_msg, :is_error, true)
              else
                tool_msg
              end

            {msgs ++ [tool_msg], current_step,
             remove_pending_tool_call(pending_calls, event.payload["tool_call_id"]), summary}

          "tool_duplicate" ->
            {msgs, current_step, remove_pending_tool_call(pending_calls, event.payload["tool_call_id"]), summary}

          "subagent_launched" ->
            {msgs, current_step, track_subagent_launch(pending_calls, event.payload), summary}

          # The folded prefix is gone; the summary stands in for it.
          "context_compacted" ->
            {Enum.drop(msgs, event.payload["dropped"] || 0), current_step, pending_calls, event.payload["summary"]}

          # Both pauses are re-derived from the still-pending tool call that
          # caused them, so the event itself replays as a no-op.
          type when type in ["waiting_for_timer", "waiting_for_user"] ->
            {msgs, current_step, pending_calls, summary}

          type when type in ["checkpoint_saved", "checkpoint"] ->
            {normalize_messages(event.payload["messages"]), event.payload["step"], [], event.payload["summary"] || summary}

          _ ->
            {msgs, current_step, pending_calls, summary}
        end
      end)

    resume_action =
      if pending_calls != [], do: {:resume_tools, pending_calls}, else: :llm_loop

    {msgs, current_step, resume_action, summary}
  end

  defp sum_token_usage(events) do
    Enum.reduce(events, {0, 0}, fn event, {in_acc, out_acc} ->
      case event do
        %{event_type: type, payload: %{"usage" => usage}} when type in ["llm_response", "context_compacted"] and is_map(usage) ->
          {in_acc + (usage["input_tokens"] || 0), out_acc + (usage["output_tokens"] || 0)}
        _ ->
          {in_acc, out_acc}
      end
    end)
  end

  defp remove_pending_tool_call(pending_calls, tool_call_id) do
    Enum.reject(pending_calls, fn tc -> tc["id"] == tool_call_id end)
  end

  # Tag the pending launch with the run it already started, so resume reattaches
  # to that child instead of spawning a second one.
  #
  # Under the default `:on_tool_call` checkpoint policy the call is already
  # pending, carried over from the `llm_response` that requested it — appending
  # here as well is what used to dispatch the launch twice. Under `:every_step`
  # a checkpoint lands between the response and the launch and clears the
  # pending list, so there we do have to synthesize the call back. The
  # arguments are lost in that case, but a reattach doesn't need them.
  defp track_subagent_launch(pending_calls, payload) do
    tool_call_id = payload["tool_call_id"]
    child_run_id = parse_run_id(payload["child_run_id"])

    cond do
      is_nil(child_run_id) ->
        pending_calls

      Enum.any?(pending_calls, &(&1["id"] == tool_call_id)) ->
        Enum.map(pending_calls, fn
          %{"id" => ^tool_call_id} = tc -> Map.put(tc, "child_run_id", child_run_id)
          tc -> tc
        end)

      true ->
        pending_calls ++
          [
            %{
              "id" => tool_call_id,
              "name" => "launch_agent",
              "arguments" => %{"agent_name" => payload["child_agent_name"]},
              "child_run_id" => child_run_id
            }
          ]
    end
  end

  # Event payloads stringify the id; a value that doesn't parse means we have no
  # child to reattach to, and the caller falls back to a fresh launch.
  defp parse_run_id(id) when is_integer(id), do: id

  defp parse_run_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {run_id, ""} -> run_id
      _ -> nil
    end
  end

  defp parse_run_id(_), do: nil

  # Keyed by child *run* id, not child agent id: one parent step can launch the
  # same agent twice, and after a crash an abandoned child can still be alive
  # and broadcasting on the same topic.
  #
  # Resolving twice is expected rather than exceptional — a reattached child
  # may be read as terminal from the database and then also broadcast its
  # completion. The first resolution removes the pending entry, so the second
  # finds nothing and is dropped.
  defp resolve_subagent(state, child_run_id, build_result) do
    case Map.pop(state.pending_subagents, child_run_id) do
      {nil, _pending} ->
        state

      {%{task_id: task_id}, remaining} ->
        send(self(), {:task_result, task_id, build_result.()})
        %{state | pending_subagents: remaining}
    end
  end

  # The launch_agent result carries the child's run id in the envelope, not
  # just its text. Without it a parent can see *what* a sub-agent said but has
  # no handle to inspect *how* it got there — which is the point of the log.
  defp subagent_outcome(run_id, "completed", output) do
    {"subagent_completed", %{"run_id" => run_id, "status" => "completed"}, output || ""}
  end

  defp subagent_outcome(run_id, "failed", error) do
    {"subagent_failed", %{"run_id" => run_id, "status" => "failed"}, error || ""}
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
