defmodule Norns.Workers.WorkerRegistry do
  @moduledoc """
  Tracks connected workers and their capabilities. Dispatches LLM tasks
  and tool tasks to workers, routes results back to waiting agent processes.

  Also holds the declarations of serverless workers (`Norns.Workers.ServerlessWorker`):
  workers that are asleep until woken. Their declared tools are advertised
  alongside connected workers' tools, and a task that finds no connected
  worker is queued as usual and then wakes the sleeping worker that
  declared it. The woken worker joins the channel like any other, and the
  queue flushes to it on register.
  """

  use GenServer

  require Logger

  alias Norns.Tools.Tool
  alias Norns.Workers.{ServerlessWorker, TaskQueue, Wake}

  # Total tries for one tool call, across every worker that takes it. A task
  # that outlives three of them is more likely to be the reason they died
  # than a victim of it.
  @max_tool_attempts 3

  # A woken worker gets this long to connect before the queue is checked and
  # it is woken again. Long enough for a cold start, short enough that a
  # dropped wake does not cost the task much of its 5-minute queue life.
  # Overridable (`:norns, :wake_cooldown_ms`) so tests need not wait.
  defp wake_cooldown_ms, do: Application.get_env(:norns, :wake_cooldown_ms, 30_000)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- Public API --

  @doc """
  Register a worker with its tool definitions, capabilities, and optional gard.

  `features` are protocol options the worker supports beyond what it can
  serve; today only `:message_cache` (it keeps the history it was last sent
  per run, so LLM tasks can carry the change instead of the list).
  """
  def register_worker(tenant_id, worker_id, channel_pid, tools, opts \\ []) do
    capabilities = Keyword.get(opts, :capabilities, [:tools])
    gard = Keyword.get(opts, :gard)
    features = Keyword.get(opts, :features, [])

    GenServer.call(
      __MODULE__,
      {:register, tenant_id, worker_id, channel_pid, tools, capabilities, gard, features}
    )
  end

  @doc """
  Remove a worker. Pass the terminating `channel_pid` so a late `terminate`
  from a connection that has already been replaced by a reconnect is ignored
  instead of evicting the healthy new worker.
  """
  def unregister_worker(tenant_id, worker_id, channel_pid \\ nil) do
    GenServer.cast(__MODULE__, {:unregister, tenant_id, worker_id, channel_pid})
  end

  @doc """
  Get all tools from connected workers for a tenant, as %Tool{} structs.

  Gard-filtered with strict equality: without `gard:`, only no-gard workers'
  tools are returned; with it, only that gard's. The tool list advertised to
  the LLM must only contain tools dispatch could actually reach.
  """
  def available_tools(tenant_id, opts \\ []) do
    GenServer.call(__MODULE__, {:available_tools, tenant_id, Keyword.get(opts, :gard)})
  end

  @doc """
  Mark a worker as draining: it keeps the tasks already in flight to it and
  is expected to finish them, but is skipped by dispatch from now on. A
  worker sends this when it is shutting down cleanly, then leaves once its
  in-flight tasks are done. New tasks that would have gone to it queue
  (or go to another matching worker), so a connector restarted under a
  supervisor loses nothing.
  """
  def drain_worker(tenant_id, worker_id) do
    GenServer.cast(__MODULE__, {:drain, tenant_id, worker_id})
  end

  @doc """
  Declare a serverless worker: what it offers and where to wake it. Its
  tools are advertised from now on, and tasks for them wake it. Re-declaring
  the same worker replaces the declaration.
  """
  def register_serverless_worker(%ServerlessWorker{} = worker) do
    GenServer.call(__MODULE__, {:register_serverless, worker})
  end

  @doc "Withdraw a serverless declaration. A connected incarnation is untouched."
  def unregister_serverless_worker(tenant_id, worker_id) do
    GenServer.cast(__MODULE__, {:unregister_serverless, tenant_id, worker_id})
  end

  @doc """
  Every serverless worker declared for a tenant, awake or not, as
  `%{worker_id:, capabilities:, tools:, tool_count:, awake:, last_woken_at:}`.

  The complement of `connected_workers/1`: a declared worker that is asleep
  holds no connection, so it appears only here. `awake` says whether a
  dispatchable incarnation is connected right now; `last_woken_at` is when
  this node last sent it a wake, or nil if it never has.
  """
  def serverless_workers(tenant_id) do
    GenServer.call(__MODULE__, {:serverless_workers, tenant_id})
  end

  @doc "Kick every worker claiming `gard_id` — used when the gard is destroyed."
  def kick_gard_workers(tenant_id, gard_id) do
    GenServer.cast(__MODULE__, {:kick_gard_workers, tenant_id, gard_id})
  end

  @doc "Check if any worker with LLM capability is available for a tenant (or :default)."
  def llm_available?(tenant_id) do
    GenServer.call(__MODULE__, {:llm_available?, tenant_id})
  end

  @doc """
  Workers currently connected for a tenant, as
  `%{worker_id:, capabilities:, tools:, tool_count:, gard:, draining:, serverless:, connected_at:}`.

  Lets a caller tell "no tools because nothing is connected" apart from "no
  tools because none were registered" — different problems with different fixes.
  """
  def connected_workers(tenant_id) do
    GenServer.call(__MODULE__, {:connected_workers, tenant_id})
  end

  @doc """
  Dispatch an LLM task to a worker with LLM capability.

  Gard-strict like tool dispatch: LLM calls are stateless, but the
  worker's LLM credentials are not — a gard deployment's API key must
  not silently serve other runs, and a lone gard worker half-serving a
  plain run (LLM works, tools hang) is worse than queueing it whole.

  `delta: {channel_pid, delta}` offers the change since the last task in
  place of `task.messages`; it is used only if the worker chosen is that
  connection and it caches history (`Norns.Agents.HistoryDelta`).

  Returns `{:ok, task_id, %{worker: pid | nil, caches?: boolean}}`: which
  connection took the task (nil when queued) and whether it keeps history,
  so the caller knows what to offer next time.
  """
  def dispatch_llm_task(tenant_id, task, opts \\ []) do
    from_pid = Keyword.get(opts, :from_pid, self())
    gard = Keyword.get(opts, :gard)
    delta = Keyword.get(opts, :delta)
    GenServer.call(__MODULE__, {:dispatch_llm, tenant_id, task, from_pid, gard, delta})
  end

  @doc "Dispatch a tool task to a connected worker."
  def dispatch_task(tenant_id, tool_name, input, opts \\ []) do
    GenServer.call(__MODULE__, {:dispatch, tenant_id, tool_name, input, opts})
  end

  @doc "Block until a result arrives for a task."
  def await_result(task_id, timeout \\ 300_000) do
    receive do
      {:task_result, ^task_id, result} -> result
      # Backward compat
      {:tool_result, ^task_id, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Deliver a result from a worker."
  def deliver_result(task_id, payload) do
    GenServer.cast(__MODULE__, {:deliver_result, task_id, payload})
  end

  # -- Callbacks --

  @impl true
  def init(_opts) do
    state = %{
      workers: %{},
      pending: %{},
      # {tenant_id, worker_id} => %{worker: %ServerlessWorker{}, last_wake_at: monotonic ms | nil}
      serverless: %{},
      # {tenant_id, tool_name} => how many tasks for that tool the tenant has
      # dispatched. Drives round-robin selection among the workers that take
      # it, so a fleet shares the load instead of the first-registered
      # worker taking everything.
      rotation: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_serverless, worker}, _from, state) do
    key = {worker.tenant_id, worker.worker_id}
    # A re-declaration (edit, boot replay) keeps the wake bookkeeping: the
    # cooldown still applies, and "last woken" is still true. On a fresh
    # boot there is no previous entry, so the row's persisted value seeds it.
    previous = Map.get(state.serverless, key, %{})

    entry = %{
      worker: worker,
      last_wake_at: previous[:last_wake_at],
      last_woken_at: previous[:last_woken_at] || worker.last_woken_at
    }
    state = put_in(state.serverless[key], entry)

    # Work may already be waiting for what this worker declares — a task
    # dispatched before the declaration, or one left over from a boot.
    {:reply, :ok, wake_if_queued(state, key)}
  end

  @impl true
  def handle_call({:register, tenant_id, worker_id, channel_pid, tools, capabilities, gard, features}, _from, state) do
    key = {tenant_id, worker_id}

    # A registration under a key that already holds a worker means a reconnect
    # (the worker crashed and came back). Stop monitoring the dead incarnation;
    # the fresh connection has no memory of what was in flight to it.
    state = demonitor_existing(state, key)

    ref = Process.monitor(channel_pid)

    worker = %{
      channel_pid: channel_pid,
      tools: tools,
      capabilities: capabilities,
      features: features,
      monitor_ref: ref,
      tenant_id: tenant_id,
      gard: gard,
      draining: false,
      connected_at: DateTime.utc_now()
    }

    state = put_in(state.workers[key], worker)

    # Reclaim *after* the new incarnation is registered, so the tasks its
    # predecessor was holding can be re-dispatched to it rather than queued
    # behind a worker that is already here.
    state = reclaim_worker_tasks(state, key)

    state =
      tools
      |> Enum.map(&tool_name/1)
      |> Enum.reduce(state, fn name, acc ->
        tenant_id
        # Gard-strict flush: a queued gard-bound task must never flush to a
        # worker in a different gard (or no gard) — that would silently break
        # the affinity invariant right when the run resumes.
        |> TaskQueue.flush(name, gard: gard)
        |> Enum.reduce(acc, fn task, pending_state ->
          push_to_worker(channel_pid, {:push_tool_task, task_payload(task)})

          put_in(pending_state.pending[task.task_id], %{
            from_pid: task.from_pid,
            tenant_id: tenant_id,
            type: :tool,
            worker_key: key,
            task: Map.merge(%{tenant_id: tenant_id, attempts: 1}, task)
          })
        end)
      end)

    state =
      if :llm in capabilities do
        tenant_id
        |> TaskQueue.flush("__llm__", gard: gard)
        |> Enum.reduce(state, fn task, pending_state ->
          push_to_worker(channel_pid, {:llm_task, llm_task_payload(task)})
          put_in(pending_state.pending[task.task_id], %{from_pid: task.from_pid, tenant_id: tenant_id, type: :llm, worker_key: key})
        end)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:available_tools, tenant_id, gard}, _from, state) do
    # Only return tools from tenant-specific workers, not the default worker.
    # Strict gard equality (nil == nil): without it, a gard-bound run would be
    # offered tools from other gards that dispatch would then fail to reach.
    connected =
      state.workers
      |> Enum.filter(fn {{tid, _}, w} -> tid == tenant_id and w.gard == gard end)
      |> Enum.flat_map(fn {_, worker} -> worker.tools end)

    # A sleeping worker's declared tools are as real as a connected one's:
    # a call to one wakes it. Serverless workers have no gard, so they only
    # serve no-gard runs. Dedup by name so a worker that is awake right now
    # does not list its tools twice.
    declared =
      if gard == nil do
        state.serverless
        |> Enum.filter(fn {{tid, _}, _} -> tid == tenant_id end)
        |> Enum.flat_map(fn {_, %{worker: w}} -> w.tools end)
      else
        []
      end

    tools =
      (connected ++ declared)
      |> Enum.uniq_by(&tool_name/1)
      |> Enum.map(fn tool_def ->
        %Tool{
          name: tool_name(tool_def),
          description: tool_def["description"] || "",
          input_schema: tool_def["input_schema"] || %{},
          source: {:remote, tenant_id},
          side_effect?: tool_def["side_effect"] || false
        }
      end)

    {:reply, tools, state}
  end

  def handle_call({:connected_workers, tenant_id}, _from, state) do
    workers =
      state.workers
      |> Enum.filter(fn {{tid, _}, w} -> tid == tenant_id and Process.alive?(w.channel_pid) end)
      |> Enum.map(fn {{_tid, worker_id} = key, w} ->
        %{
          worker_id: worker_id,
          capabilities: w.capabilities,
          tools: Enum.map(w.tools, &tool_name/1),
          tool_count: length(w.tools),
          gard: w.gard,
          draining: w.draining,
          serverless: Map.has_key?(state.serverless, key),
          connected_at: w.connected_at
        }
      end)

    {:reply, workers, state}
  end

  def handle_call({:serverless_workers, tenant_id}, _from, state) do
    workers =
      state.serverless
      |> Enum.filter(fn {{tid, _}, _} -> tid == tenant_id end)
      |> Enum.map(fn {key, %{worker: w, last_woken_at: woken}} ->
        %{
          worker_id: w.worker_id,
          capabilities: Enum.map(w.capabilities, &String.to_existing_atom/1),
          tools: ServerlessWorker.tool_names(w),
          tool_count: length(w.tools),
          awake: connected?(state, key),
          last_woken_at: woken
        }
      end)

    {:reply, workers, state}
  end

  def handle_call({:llm_available?, tenant_id}, _from, state) do
    available =
      Enum.any?(state.workers, fn {{tid, _}, w} ->
        (tid == tenant_id or tid == :default) and :llm in w.capabilities
      end) or
        Enum.any?(state.serverless, fn {{tid, _}, %{worker: w}} ->
          tid == tenant_id and "llm" in w.capabilities
        end)

    {:reply, available, state}
  end

  def handle_call({:dispatch_llm, tenant_id, task, from_pid, gard, delta}, _from, state) do
    {worker, state} =
      pick_worker(state, tenant_id, "__llm__", preferred_worker(delta), fn w ->
        :llm in w.capabilities and w.gard == gard and dispatchable?(w)
      end)

    case worker do
      {key, w} ->
        task_id = generate_task_id()
        payload = task |> Map.put(:task_id, task_id) |> with_delta(delta, w)

        push_to_worker(w.channel_pid, {:llm_task, payload})

        pending = %{from_pid: from_pid, tenant_id: tenant_id, type: :llm, worker_key: key}
        state = put_in(state.pending[task_id], pending)

        {:reply, {:ok, task_id, %{worker: w.channel_pid, caches?: caches_history?(w)}}, state}

      nil ->
        # No LLM worker available — queue it, and wake one that could take it
        task_id = generate_task_id()

        TaskQueue.enqueue(tenant_id, %{
          task_id: task_id,
          tool_name: "__llm__",
          input: task,
          from_pid: from_pid,
          gard: gard
        })

        {:reply, {:ok, task_id, %{worker: nil, caches?: false}}, wake_for(state, tenant_id, gard, "__llm__")}
    end
  end

  def handle_call({:dispatch, tenant_id, tool_name, input, opts}, _from, state) do
    task = %{
      task_id: generate_task_id(),
      tenant_id: tenant_id,
      tool_name: tool_name,
      input: input,
      from_pid: Keyword.get(opts, :from_pid, self()),
      agent_id: Keyword.get(opts, :agent_id),
      run_id: Keyword.get(opts, :run_id),
      gard: Keyword.get(opts, :gard),
      # The same call re-dispatched after a worker dies carries the same key.
      # A worker that has already done the side effect answers from what it
      # kept instead of doing it again.
      idempotency_key: Keyword.get(opts, :idempotency_key),
      attempts: 1
    }

    {:reply, {:ok, task.task_id}, place_tool_task(state, task)}
  end

  @impl true
  def handle_cast({:unregister, tenant_id, worker_id, channel_pid}, state) do
    key = {tenant_id, worker_id}

    case state.workers[key] do
      %{channel_pid: stored_pid, monitor_ref: ref} = worker
      when is_nil(channel_pid) or stored_pid == channel_pid ->
        Process.demonitor(ref, [:flush])
        Logger.info("Worker #{worker_id} unregistered from tenant #{tenant_id}")
        mark_gard_disconnected(worker)

        state = %{state | workers: Map.delete(state.workers, key)}
        # Fail this worker's in-flight tasks so agents retry instead of hanging
        # until the task timeout. Precise per-worker reclaim leaves any other
        # worker on the same tenant untouched.
        {:noreply, reclaim_worker_tasks(state, key)}

      _stale_or_missing ->
        # No worker under this key, or a late terminate from a connection that
        # has already been replaced by a reconnect — don't evict the new worker.
        {:noreply, state}
    end
  end

  def handle_cast({:unregister_serverless, tenant_id, worker_id}, state) do
    {:noreply, %{state | serverless: Map.delete(state.serverless, {tenant_id, worker_id})}}
  end

  def handle_cast({:drain, tenant_id, worker_id}, state) do
    key = {tenant_id, worker_id}

    case state.workers[key] do
      nil ->
        {:noreply, state}

      worker ->
        Logger.info("Worker #{worker_id} draining (tenant #{tenant_id})")
        {:noreply, put_in(state.workers[key], %{worker | draining: true})}
    end
  end

  def handle_cast({:deliver_result, task_id, payload}, state) do
    case Map.pop(state.pending, task_id) do
      {%{from_pid: pid}, pending} ->

        result =
          case payload do
            # LLM result — pass through the full map
            %{"status" => "ok", "content" => _} = full -> {:ok, full}
            # Tool result. `duplicate` is the worker saying it recognised the
            # idempotency key and answered from the result it kept, rather
            # than doing the side effect a second time.
            %{"status" => "ok", "result" => result, "duplicate" => true} -> {:ok, result, :duplicate}
            %{"status" => "ok", "result" => result} -> {:ok, result}
            %{"status" => "error", "error" => error} -> {:error, error}
            _ -> {:error, "invalid result payload"}
          end

        send(pid, {:task_result, task_id, result})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        Logger.warning("Received result for unknown task: #{task_id}")
        {:noreply, state}
    end
  end

  def handle_cast({:kick_gard_workers, tenant_id, gard_id}, state) do
    state.workers
    |> Enum.filter(fn {{tid, _}, w} -> tid == tenant_id and w.gard == gard_id end)
    |> Enum.each(fn {_, w} -> send(w.channel_pid, :gard_destroyed) end)

    # The channel stops itself, which runs its terminate → unregister → the
    # normal disconnect cascade (task reclaim, mark_disconnected no-op since
    # the gard is already destroyed).
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.workers, fn {_, w} -> w.monitor_ref == ref end) do
      {{tenant_id, worker_id} = key, worker} ->
        Logger.info("Worker #{worker_id} disconnected from tenant #{tenant_id}")
        mark_gard_disconnected(worker)
        state = %{state | workers: Map.delete(state.workers, key)}

        # Fail this worker's in-flight tasks — the agent retry policy re-dispatches
        {:noreply, reclaim_worker_tasks(state, key)}

      nil ->
        {:noreply, state}
    end
  end

  # The cooldown after a wake has passed. If the worker still is not here and
  # work is still queued for it, wake it again; the queue's own stale sweep
  # is what ends this if the worker never comes.
  def handle_info({:rewake, key}, state) do
    {:noreply, wake_if_queued(state, key)}
  end

  # -- Helpers --

  # A task found no connected worker and was queued. Wake a sleeping worker
  # that declared the tool (or `"__llm__"` capability) for this tenant, if
  # one exists, is not already connected, and was not woken moments ago.
  defp wake_for(state, tenant_id, gard, tool_name) do
    state.serverless
    |> Enum.filter(fn {{tid, _}, %{worker: w}} ->
      tid == tenant_id and gard == nil and serves?(w, tool_name)
    end)
    |> Enum.reduce(state, fn {key, _}, acc -> maybe_wake(acc, key) end)
  end

  # Wake `key` if anything in its tenant's queue is for it.
  defp wake_if_queued(state, key) do
    case state.serverless[key] do
      nil ->
        state

      %{worker: w} ->
        {tenant_id, _} = key

        queued? =
          tenant_id
          |> TaskQueue.peek()
          |> Enum.any?(fn task -> Map.get(task, :gard) == nil and serves?(w, task.tool_name) end)

        if queued?, do: maybe_wake(state, key), else: state
    end
  end

  defp maybe_wake(state, key) do
    %{worker: w, last_wake_at: last} = state.serverless[key]
    now = System.monotonic_time(:millisecond)

    cond do
      connected?(state, key) ->
        state

      last != nil and now - last < wake_cooldown_ms() ->
        state

      true ->
        Logger.info("Waking serverless worker #{w.worker_id} (tenant #{w.tenant_id})")
        Wake.wake_async(w)
        Process.send_after(self(), {:rewake, key}, wake_cooldown_ms())

        # Monotonic for the cooldown, wall clock for whoever asks when. The
        # wall-clock time is also written to the row so it outlives a restart.
        woken_at = DateTime.utc_now()
        persist_woken_at(w, woken_at)

        update_in(state.serverless[key], fn entry ->
          %{entry | last_wake_at: now, last_woken_at: woken_at}
        end)
    end
  end

  # Best-effort, off the registry process, like mark_gard_disconnected: the
  # registry holds every worker connection and must not die on a database
  # hiccup. The in-memory copy is already updated; this is the durable one.
  defp persist_woken_at(%ServerlessWorker{} = w, at) do
    Task.start(fn ->
      try do
        Norns.Workers.ServerlessWorkers.mark_woken(w.tenant_id, w.worker_id, at)
      rescue
        e -> Logger.warning("failed to record wake of #{w.worker_id}: #{Exception.message(e)}")
      catch
        :exit, reason -> Logger.warning("failed to record wake of #{w.worker_id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp connected?(state, key) do
    case state.workers[key] do
      nil -> false
      worker -> dispatchable?(worker)
    end
  end

  defp serves?(%ServerlessWorker{} = w, "__llm__"), do: "llm" in w.capabilities
  defp serves?(%ServerlessWorker{} = w, tool_name), do: tool_name in ServerlessWorker.tool_names(w)

  # Put a tool task on a worker, or in the queue if none can take it.
  #
  # One function for all three ways a task is placed — first dispatch, flush
  # after a worker connects, and re-dispatch after one dies — so a task keeps
  # its identity across every one of them. The `task_id` is what the waiting
  # agent process correlates on, and the `idempotency_key` is what lets a
  # worker recognise a call it already ran.
  #
  # Strict gard equality (nil == nil, "a" == "a"): no-gard runs never grab a
  # gard-bound worker (stolen dispatch), gard runs never fall through to a
  # no-gard worker (filesystem state leakage). The :default-tenant fallback
  # in pick_worker only ever holds no-gard workers, so it can only fire when
  # gard is nil — a gard-bound run never falls back to a generic worker.
  defp place_tool_task(state, task) do
    {worker, state} =
      pick_worker(state, task.tenant_id, task.tool_name, nil, fn w ->
        dispatchable?(w) and w.gard == task.gard and
          Enum.any?(w.tools, &(tool_name(&1) == task.tool_name))
      end)

    case worker do
      {key, w} ->
        push_to_worker(w.channel_pid, {:push_tool_task, task_payload(task)})

        put_in(state.pending[task.task_id], %{
          from_pid: task.from_pid,
          tenant_id: task.tenant_id,
          type: :tool,
          worker_key: key,
          task: task
        })

      nil ->
        TaskQueue.enqueue(task.tenant_id, task)
        wake_for(state, task.tenant_id, task.gard, task.tool_name)
    end
  end

  # Stop monitoring the previous incarnation registered under `key`, if any.
  # `:flush` drops a possibly-already-queued :DOWN for it so a later handler
  # can't act on a stale ref that no longer identifies the current worker.
  defp demonitor_existing(state, key) do
    case state.workers[key] do
      %{monitor_ref: ref} -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    state
  end

  # A worker died holding tasks. Re-dispatch its tool calls; only give up on
  # one after `@max_tool_attempts` tries.
  #
  # The alternative — telling the agent the tool failed — sounds safer and is
  # worse. Core cannot know whether the side effect happened, so the model
  # gets "worker disconnected" and retries, and that retry is a *new* call at
  # a new step with a new idempotency key, which no worker can recognise. The
  # effect then happens twice, reliably. Re-dispatching the same call with
  # the same key is what gives the worker something to recognise, and it is
  # the only version of this where "exactly once" means anything.
  #
  # The attempt cap is for the task that kills whatever runs it: after three
  # workers die holding it, the model is told, and it can decide.
  defp reclaim_worker_tasks(state, worker_key) do
    {lost, remaining} =
      Map.split_with(state.pending, fn {_task_id, info} ->
        Map.get(info, :worker_key) == worker_key
      end)

    state = %{state | pending: remaining}

    Enum.reduce(lost, state, fn {task_id, info}, acc ->
      case redispatchable(info) do
        {:ok, task} ->
          Logger.info(
            "Re-dispatching #{task.tool_name} (task #{task_id}, attempt #{task.attempts + 1}) " <>
              "after its worker disconnected"
          )

          place_tool_task(acc, %{task | attempts: task.attempts + 1})

        :no ->
          send(info.from_pid, {:task_result, task_id, {:error, "worker disconnected"}})
          acc
      end
    end)
  end

  defp redispatchable(%{type: :tool, task: %{attempts: attempts} = task})
       when attempts < @max_tool_attempts,
       do: {:ok, task}

  defp redispatchable(_info), do: :no

  # Both the unregister and DOWN paths can fire on the same disconnect;
  # Gards.mark_disconnected is idempotent, so calling it from both is safe.
  #
  # Isolated in an unlinked task: the registry holds every worker connection,
  # so a database hiccup must not crash it. The status write is best-effort
  # bookkeeping — a reconnecting worker re-claims the gard regardless.
  defp mark_gard_disconnected(%{gard: gard, tenant_id: tenant_id}) when not is_nil(gard) do
    Task.start(fn ->
      try do
        Norns.Gards.mark_disconnected(tenant_id, gard)
      rescue
        e -> Logger.warning("failed to mark gard #{gard} disconnected: #{Exception.message(e)}")
      catch
        :exit, reason -> Logger.warning("failed to mark gard #{gard} disconnected: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp mark_gard_disconnected(_worker), do: :ok

  defp tool_name(%{"name" => name}), do: name
  defp tool_name(name) when is_binary(name), do: name

  defp generate_task_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp task_payload(task) do
    Map.take(task, [:task_id, :tool_name, :input, :agent_id, :run_id, :idempotency_key])
  end

  defp llm_task_payload(task) do
    task
    |> Map.get(:input, %{})
    |> Map.put(:task_id, task.task_id)
  end

  defp caches_history?(worker), do: :message_cache in Map.get(worker, :features, [])

  # The delta was computed against what one connection holds; it replaces
  # the history only on that connection. Anyone else gets the list.
  defp with_delta(task, {pid, delta}, %{channel_pid: pid} = worker) do
    if caches_history?(worker),
      do: task |> Map.delete(:messages) |> Map.put(:messages_delta, delta),
      else: task
  end

  defp with_delta(task, _delta, _worker), do: task

  # A worker takes new tasks while its channel is alive and it has not
  # announced it is shutting down. In-flight tasks are unaffected either way.
  defp dispatchable?(worker), do: Process.alive?(worker.channel_pid) and not worker.draining

  # Pick a worker for one task, rotating through every worker that matches
  # so consecutive tasks for the same tool land on different workers. The
  # tenant's own workers are preferred; the `:default` pool is only
  # consulted when the tenant has none that match. Candidates are ordered by
  # key so the rotation is stable across calls, and the cursor advances
  # only on a hit so an idle period does not skew the next pick.
  #
  # A run whose last LLM step went to a worker that still holds its history
  # (`preferred`, the channel pid behind a pending delta) stays on that
  # worker when it still matches, so the delta applies instead of a full
  # resend. Such a pick leaves the cursor alone: it is affinity, not a turn.
  defp pick_worker(state, tenant_id, tool_name, preferred, matcher) do
    candidates =
      matching_workers(state, tenant_id, matcher)
      |> case do
        [] -> matching_workers(state, :default, matcher)
        own -> own
      end

    preferred = Enum.find(candidates, fn {_key, w} -> w.channel_pid == preferred end)

    cond do
      candidates == [] ->
        {nil, state}

      preferred ->
        {preferred, state}

      true ->
        cursor = Map.get(state.rotation, {tenant_id, tool_name}, 0)
        picked = Enum.at(candidates, rem(cursor, length(candidates)))
        {picked, put_in(state.rotation[{tenant_id, tool_name}], cursor + 1)}
    end
  end

  defp preferred_worker({pid, _delta}) when is_pid(pid), do: pid
  defp preferred_worker(_), do: nil

  defp matching_workers(state, tenant_id, matcher) do
    state.workers
    |> Enum.filter(fn {{tid, _}, worker} -> tid == tenant_id and matcher.(worker) end)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  defp push_to_worker(channel_pid, message) do
    send(channel_pid, message)
  end
end
