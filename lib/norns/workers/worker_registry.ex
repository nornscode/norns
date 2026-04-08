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

  @doc "Register a worker with its tool definitions and capabilities."
  def register_worker(tenant_id, worker_id, channel_pid, tools, opts \\ []) do
    capabilities = Keyword.get(opts, :capabilities, [:tools])
    GenServer.call(__MODULE__, {:register, tenant_id, worker_id, channel_pid, tools, capabilities})
  end

  @doc "Remove a worker."
  def unregister_worker(tenant_id, worker_id) do
    GenServer.cast(__MODULE__, {:unregister, tenant_id, worker_id})
  end

  @doc "Get all tools from connected workers for a tenant, as %Tool{} structs."
  def available_tools(tenant_id) do
    GenServer.call(__MODULE__, {:available_tools, tenant_id})
  end

  @doc "Check if any worker with LLM capability is available for a tenant (or :default)."
  def llm_available?(tenant_id) do
    GenServer.call(__MODULE__, {:llm_available?, tenant_id})
  end

  @doc "Dispatch an LLM task to a worker with LLM capability."
  def dispatch_llm_task(tenant_id, task, opts \\ []) do
    from_pid = Keyword.get(opts, :from_pid, self())
    GenServer.call(__MODULE__, {:dispatch_llm, tenant_id, task, from_pid})
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
  def handle_call({:register, tenant_id, worker_id, channel_pid, tools, capabilities}, _from, state) do
    ref = Process.monitor(channel_pid)
    key = {tenant_id, worker_id}

    worker = %{
      channel_pid: channel_pid,
      tools: tools,
      capabilities: capabilities,
      monitor_ref: ref,
      tenant_id: tenant_id
    }

    state = put_in(state.workers[key], worker)

    state =
      tools
      |> Enum.map(&tool_name/1)
      |> Enum.reduce(state, fn name, acc ->
        tenant_id
        |> TaskQueue.flush(name)
        |> Enum.reduce(acc, fn task, pending_state ->
          push_to_worker(channel_pid, {:push_tool_task, task_payload(task)})
          put_in(pending_state.pending[task.task_id], %{from_pid: task.from_pid, tenant_id: tenant_id, type: :tool})
        end)
      end)

    state =
      if :llm in capabilities do
        tenant_id
        |> TaskQueue.flush("__llm__")
        |> Enum.reduce(state, fn task, pending_state ->
          push_to_worker(channel_pid, {:llm_task, llm_task_payload(task)})
          put_in(pending_state.pending[task.task_id], %{from_pid: task.from_pid, tenant_id: tenant_id, type: :llm})
        end)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:available_tools, tenant_id}, _from, state) do
    # Only return tools from tenant-specific workers, not the default worker.
    # Default worker tools are in Tools.Registry (local).
    tools =
      state.workers
      |> Enum.filter(fn {{tid, _}, _} -> tid == tenant_id end)
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

  def handle_call({:llm_available?, tenant_id}, _from, state) do
    available =
      Enum.any?(state.workers, fn {{tid, _}, w} ->
        (tid == tenant_id or tid == :default) and :llm in w.capabilities
      end)

    {:reply, available, state}
  end

  def handle_call({:dispatch_llm, tenant_id, task, from_pid}, _from, state) do
    worker = find_worker(state, tenant_id, fn w -> :llm in w.capabilities and Process.alive?(w.channel_pid) end)

    case worker do
      {_key, w} ->
        task_id = generate_task_id()
        full_task = Map.put(task, :task_id, task_id)

        push_to_worker(w.channel_pid, {:llm_task, full_task})

        pending = %{from_pid: from_pid, tenant_id: tenant_id, type: :llm}
        state = put_in(state.pending[task_id], pending)

        {:reply, {:ok, task_id}, state}

      nil ->
        # No LLM worker available — queue it
        task_id = generate_task_id()

        TaskQueue.enqueue(tenant_id, %{
          task_id: task_id,
          tool_name: "__llm__",
          input: task,
          from_pid: from_pid
        })

        {:reply, {:ok, task_id}, state}
    end
  end

  def handle_call({:dispatch, tenant_id, tool_name, input, opts}, _from, state) do
    agent_id = Keyword.get(opts, :agent_id)
    run_id = Keyword.get(opts, :run_id)
    from_pid = Keyword.get(opts, :from_pid, self())

    worker = find_worker(state, tenant_id, fn w -> Process.alive?(w.channel_pid) and Enum.any?(w.tools, &(tool_name(&1) == tool_name)) end)

    case worker do
      {_key, w} ->
        task_id = generate_task_id()

        push_to_worker(w.channel_pid, {:push_tool_task, %{
          task_id: task_id,
          tool_name: tool_name,
          input: input,
          agent_id: agent_id,
          run_id: run_id
        }})

        pending = %{from_pid: from_pid, tenant_id: tenant_id, type: :tool}
        state = put_in(state.pending[task_id], pending)

        {:reply, {:ok, task_id}, state}

      nil ->
        task = %{
          task_id: generate_task_id(),
          tool_name: tool_name,
          input: input,
          from_pid: from_pid,
          agent_id: agent_id,
          run_id: run_id
        }

        TaskQueue.enqueue(tenant_id, task)
        {:reply, {:ok, task.task_id}, state}
    end
  end

  @impl true
  def handle_cast({:unregister, tenant_id, worker_id}, state) do
    key = {tenant_id, worker_id}

    case Map.pop(state.workers, key) do
      {%{monitor_ref: ref}, workers} ->
        Process.demonitor(ref, [:flush])
        Logger.info("Worker #{worker_id} unregistered from tenant #{tenant_id}")

        # Fail pending tasks so agents can retry instead of waiting for timeout
        {failed, remaining} =
          Map.split_with(state.pending, fn {_task_id, info} ->
            info.tenant_id == tenant_id
          end)

        Enum.each(failed, fn {task_id, %{from_pid: pid}} ->
          send(pid, {:task_result, task_id, {:error, "worker disconnected"}})
        end)

        {:noreply, %{state | workers: workers, pending: remaining}}

      {nil, _} ->
        {:noreply, state}
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

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.workers, fn {_, w} -> w.monitor_ref == ref end) do
      {{tenant_id, worker_id} = key, _worker} ->
        Logger.info("Worker #{worker_id} disconnected from tenant #{tenant_id}")
        workers = Map.delete(state.workers, key)

        # Fail all pending tasks — agent retry policy will re-dispatch
        {failed, remaining} =
          Map.split_with(state.pending, fn {_task_id, info} ->
            info.tenant_id == tenant_id
          end)

        Enum.each(failed, fn {task_id, %{from_pid: pid}} ->
          send(pid, {:task_result, task_id, {:error, "worker disconnected"}})
        end)

        {:noreply, %{state | workers: workers, pending: remaining}}

      nil ->
        {:noreply, state}
    end
  end

  # -- Helpers --

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

  defp find_worker(state, tenant_id, matcher) do
    Enum.find(state.workers, fn {{tid, _}, worker} -> tid == tenant_id and matcher.(worker) end) ||
      Enum.find(state.workers, fn {{tid, _}, worker} -> tid == :default and matcher.(worker) end)
  end

  defp push_to_worker(channel_pid, message) do
    send(channel_pid, message)
  end
end
