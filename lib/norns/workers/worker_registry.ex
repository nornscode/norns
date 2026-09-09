defmodule Norns.Workers.WorkerRegistry do
  @moduledoc """
  Tracks connected workers and their capabilities. Dispatches LLM tasks
  and tool tasks to workers, routes results back to waiting agent processes.
  """

  use GenServer

  require Logger

  alias Norns.Tools.Tool
  alias Norns.Workers.TaskQueue

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- Public API --

  @doc "Register a worker with its tool definitions, capabilities, and optional gard."
  def register_worker(tenant_id, worker_id, channel_pid, tools, opts \\ []) do
    capabilities = Keyword.get(opts, :capabilities, [:tools])
    gard = Keyword.get(opts, :gard)
    GenServer.call(__MODULE__, {:register, tenant_id, worker_id, channel_pid, tools, capabilities, gard})
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

  @doc "Kick every worker claiming `gard_id` — used when the gard is destroyed."
  def kick_gard_workers(tenant_id, gard_id) do
    GenServer.cast(__MODULE__, {:kick_gard_workers, tenant_id, gard_id})
  end

  @doc "Check if any worker with LLM capability is available for a tenant (or :default)."
  def llm_available?(tenant_id) do
    GenServer.call(__MODULE__, {:llm_available?, tenant_id})
  end

  @doc """
  Workers currently connected for a tenant, as `%{worker_id:, capabilities:, tool_count:}`.

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
  """
  def dispatch_llm_task(tenant_id, task, opts \\ []) do
    from_pid = Keyword.get(opts, :from_pid, self())
    gard = Keyword.get(opts, :gard)
    GenServer.call(__MODULE__, {:dispatch_llm, tenant_id, task, from_pid, gard})
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
      pending: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, tenant_id, worker_id, channel_pid, tools, capabilities, gard}, _from, state) do
    key = {tenant_id, worker_id}

    # A registration under a key that already holds a worker means a reconnect
    # (the worker crashed and came back). Stop monitoring the dead incarnation
    # and reclaim any tasks that were in flight to it — the fresh connection has
    # no memory of them, so they must fail and let the agent retry/redispatch.
    state = demonitor_existing(state, key)
    state = reclaim_worker_tasks(state, key)

    ref = Process.monitor(channel_pid)

    worker = %{
      channel_pid: channel_pid,
      tools: tools,
      capabilities: capabilities,
      monitor_ref: ref,
      tenant_id: tenant_id,
      gard: gard,
      draining: false
    }

    state = put_in(state.workers[key], worker)

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
          put_in(pending_state.pending[task.task_id], %{from_pid: task.from_pid, tenant_id: tenant_id, type: :tool, worker_key: key})
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
    # Default worker tools are in Tools.Registry (local).
    # Strict gard equality (nil == nil): without it, a gard-bound run would be
    # offered tools from other gards that dispatch would then fail to reach.
    tools =
      state.workers
      |> Enum.filter(fn {{tid, _}, w} -> tid == tenant_id and w.gard == gard end)
      |> Enum.flat_map(fn {_, worker} -> worker.tools end)
      |> Enum.map(fn tool_def ->
        %Tool{
          name: tool_name(tool_def),
          description: tool_def["description"] || "",
          input_schema: tool_def["input_schema"] || %{},
          handler: fn _ -> {:error, "remote tool — use dispatch"} end,
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
      |> Enum.map(fn {{_tid, worker_id}, w} ->
        %{
          worker_id: worker_id,
          capabilities: w.capabilities,
          tool_count: length(w.tools),
          gard: w.gard,
          draining: w.draining
        }
      end)

    {:reply, workers, state}
  end

  def handle_call({:llm_available?, tenant_id}, _from, state) do
    available =
      Enum.any?(state.workers, fn {{tid, _}, w} ->
        (tid == tenant_id or tid == :default) and :llm in w.capabilities
      end)

    {:reply, available, state}
  end

  def handle_call({:dispatch_llm, tenant_id, task, from_pid, gard}, _from, state) do
    worker =
      find_worker(state, tenant_id, fn w ->
        :llm in w.capabilities and w.gard == gard and dispatchable?(w)
      end)

    case worker do
      {key, w} ->
        task_id = generate_task_id()
        full_task = Map.put(task, :task_id, task_id)

        push_to_worker(w.channel_pid, {:llm_task, full_task})

        pending = %{from_pid: from_pid, tenant_id: tenant_id, type: :llm, worker_key: key}
        state = put_in(state.pending[task_id], pending)

        {:reply, {:ok, task_id}, state}

      nil ->
        # No LLM worker available — queue it
        task_id = generate_task_id()

        TaskQueue.enqueue(tenant_id, %{
          task_id: task_id,
          tool_name: "__llm__",
          input: task,
          from_pid: from_pid,
          gard: gard
        })

        {:reply, {:ok, task_id}, state}
    end
  end

  def handle_call({:dispatch, tenant_id, tool_name, input, opts}, _from, state) do
    agent_id = Keyword.get(opts, :agent_id)
    run_id = Keyword.get(opts, :run_id)
    from_pid = Keyword.get(opts, :from_pid, self())
    gard = Keyword.get(opts, :gard)

    # Strict gard equality (nil == nil, "a" == "a"): no-gard runs never grab a
    # gard-bound worker (stolen dispatch), gard runs never fall through to a
    # no-gard worker (filesystem state leakage). The :default-tenant fallback
    # in find_worker only ever holds no-gard workers, so it can only fire when
    # gard is nil — a gard-bound run never falls back to a generic worker.
    worker =
      find_worker(state, tenant_id, fn w ->
        dispatchable?(w) and w.gard == gard and
          Enum.any?(w.tools, &(tool_name(&1) == tool_name))
      end)

    case worker do
      {key, w} ->
        task_id = generate_task_id()

        push_to_worker(w.channel_pid, {:push_tool_task, %{
          task_id: task_id,
          tool_name: tool_name,
          input: input,
          agent_id: agent_id,
          run_id: run_id
        }})

        pending = %{from_pid: from_pid, tenant_id: tenant_id, type: :tool, worker_key: key}
        state = put_in(state.pending[task_id], pending)

        {:reply, {:ok, task_id}, state}

      nil ->
        task = %{
          task_id: generate_task_id(),
          tool_name: tool_name,
          input: input,
          from_pid: from_pid,
          agent_id: agent_id,
          run_id: run_id,
          gard: gard
        }

        TaskQueue.enqueue(tenant_id, task)
        {:reply, {:ok, task.task_id}, state}
    end
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
            # Tool result
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

  # -- Helpers --

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

  # Fail every pending task owned by `worker_key`, notifying the waiting agent
  # process so its retry policy re-dispatches to a healthy worker (or queues).
  defp reclaim_worker_tasks(state, worker_key) do
    {failed, remaining} =
      Map.split_with(state.pending, fn {_task_id, info} ->
        Map.get(info, :worker_key) == worker_key
      end)

    Enum.each(failed, fn {task_id, %{from_pid: pid}} ->
      send(pid, {:task_result, task_id, {:error, "worker disconnected"}})
    end)

    %{state | pending: remaining}
  end

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
    Map.take(task, [:task_id, :tool_name, :input, :agent_id, :run_id])
  end

  defp llm_task_payload(task) do
    task
    |> Map.get(:input, %{})
    |> Map.put(:task_id, task.task_id)
  end

  # A worker takes new tasks while its channel is alive and it has not
  # announced it is shutting down. In-flight tasks are unaffected either way.
  defp dispatchable?(worker), do: Process.alive?(worker.channel_pid) and not worker.draining

  defp find_worker(state, tenant_id, matcher) do
    Enum.find(state.workers, fn {{tid, _}, worker} -> tid == tenant_id and matcher.(worker) end) ||
      Enum.find(state.workers, fn {{tid, _}, worker} -> tid == :default and matcher.(worker) end)
  end

  defp push_to_worker(channel_pid, message) do
    send(channel_pid, message)
  end
end
