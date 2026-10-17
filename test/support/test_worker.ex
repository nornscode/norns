defmodule Norns.TestWorker do
  @moduledoc """
  A worker, for tests: registers with the WorkerRegistry and serves the `llm`
  and `tools` tasks the orchestrator dispatches. Started in test setup, never
  in the application supervisor.

  Everything a worker does — talking to a provider, translating the neutral
  format, executing a tool — lives under `Norns.TestWorker.*` in test support,
  because none of it belongs in `lib/`. The orchestrator has no LLM client and
  no tool executor; that is the whole point of it.
  """

  use GenServer

  alias Norns.TestWorker.Format
  alias Norns.TestWorker.LLM
  alias Norns.TestWorker.Tool
  alias Norns.TestWorker.Tools
  alias Norns.Workers.WorkerRegistry

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    tools = Keyword.get(opts, :tools, [])
    tenant = Keyword.get(opts, :tenant, :default)
    worker_id = Keyword.get(opts, :worker_id, "test-worker")
    capabilities = Keyword.get(opts, :capabilities, [:llm, :tools])
    features = Keyword.get(opts, :features, [])
    gard = Keyword.get(opts, :gard)

    tool_defs = Enum.map(tools, &Tool.to_def/1)

    WorkerRegistry.register_worker(
      tenant,
      worker_id,
      self(),
      tool_defs,
      capabilities: capabilities,
      features: features,
      gard: gard
    )

    # `observer` gets a copy of every llm_task as it arrived, so a test can
    # see whether core sent the history or the change.
    {:ok,
     %{
       tools: tools,
       completed: %{},
       caches?: :message_cache in features,
       history: %{},
       observer: Keyword.get(opts, :observer)
     }}
  end

  @impl true
  def handle_info({:push_tool_task, task}, state) do
    task_id = task[:task_id] || task["task_id"]
    key = task[:idempotency_key] || task["idempotency_key"]

    case key && Map.get(state.completed, key) do
      # Already done in this run, and core is asking again — which means the
      # first result never reached it. Answer from what we kept; doing the
      # side effect a second time is the thing the key exists to prevent.
      # A real worker's memory is its own business (in-process here, durable
      # or provider-side elsewhere); core only sees the flag.
      nil ->
        worker = self()

        Task.start(fn ->
          result = execute_tool(task, state.tools)
          if key, do: send(worker, {:remember, key, result})

          WorkerRegistry.deliver_result(task_id, %{
            "status" => if(match?({:ok, _}, result), do: "ok", else: "error"),
            "result" => elem(result, 1),
            "error" => if(match?({:error, _}, result), do: elem(result, 1))
          })
        end)

      {:ok, content} ->
        WorkerRegistry.deliver_result(task_id, %{"status" => "ok", "result" => content, "duplicate" => true})

      {:error, reason} ->
        WorkerRegistry.deliver_result(task_id, %{"status" => "error", "error" => reason})
    end

    {:noreply, state}
  end

  def handle_info({:remember, key, result}, state) do
    {:noreply, %{state | completed: Map.put(state.completed, key, result)}}
  end

  # With `features: [:message_cache]` this worker keeps the history it was
  # last sent for each run, and core may send the change instead of the list
  # (`messages_delta`; the protocol is `Norns.Agents.HistoryDelta`). A delta
  # on a base this worker does not hold is answered with `message_cache_miss`
  # and core resends in full. A compaction task's messages are a prefix to
  # summarise, not the history, so they leave the cache alone.
  def handle_info({:llm_task, task}, state) do
    if state.observer, do: send(state.observer, {:llm_task, task})

    case resolve_history(task, state) do
      {:ok, task, history} ->
        Task.start(fn ->
          result = execute_llm(task)
          WorkerRegistry.deliver_result(task.task_id, result)
        end)

        {:noreply, %{state | history: history}}

      :miss ->
        WorkerRegistry.deliver_result(task.task_id, %{"status" => "error", "error" => "message_cache_miss"})
        {:noreply, state}
    end
  end

  # What a worker that evicted its cache looks like to core.
  def handle_info(:forget_history, state), do: {:noreply, %{state | history: %{}}}

  def handle_info(_msg, state), do: {:noreply, state}

  defp resolve_history(task, %{caches?: false, history: history}), do: {:ok, task, history}

  defp resolve_history(%{purpose: "compact"} = task, %{history: history}), do: {:ok, task, history}

  defp resolve_history(%{messages_delta: %{base_count: n, drop: d, append: append}} = task, %{history: history}) do
    case Map.get(history, task.run_id) do
      previous when is_list(previous) and length(previous) == n ->
        messages = Enum.drop(previous, d) ++ append
        {:ok, Map.put(task, :messages, messages), Map.put(history, task.run_id, messages)}

      _ ->
        :miss
    end
  end

  defp resolve_history(%{messages: messages, run_id: run_id} = task, %{history: history}),
    do: {:ok, task, Map.put(history, run_id, messages)}

  # Registry tests push bare tasks with neither.
  defp resolve_history(task, %{history: history}), do: {:ok, task, history}

  defp execute_llm(task) do
    # The worker owns the provider key. The orchestrator never sends one.
    api_key = "test-worker-key"
    model = task.model
    compact? = task[:purpose] == "compact"
    system_prompt = if compact?, do: Format.compose_compaction_prompt(task), else: Format.compose_system_prompt(task)
    messages = if compact?, do: Format.compaction_messages(task), else: task.messages
    tools = if compact?, do: [], else: task[:tools] || []

    anthropic_messages = Format.to_anthropic_messages(messages)
    anthropic_tools = if tools != [], do: Format.to_anthropic_tools(tools), else: []
    opts = if anthropic_tools != [], do: [tools: anthropic_tools], else: []

    case LLM.chat(api_key, model, system_prompt, anthropic_messages, opts) do
      {:ok, response} ->
        anthropic_body = %{
          "content" => response.content,
          "stop_reason" => response.stop_reason,
          "usage" => Map.new(response.usage, fn {k, v} -> {to_string(k), v} end),
          "model" => response[:model]
        }

        neutral = Format.from_anthropic_response(anthropic_body)

        neutral
        |> Map.put("status", "ok")
        |> Map.put("final_output", Format.final_output(messages, neutral["content"]))

      {:error, reason} ->
        %{"status" => "error", "error" => reason}
    end
  end

  defp execute_tool(task, tools) do
    tool_name = task[:tool_name] || task["tool_name"]
    input = task[:input] || task["input"]

    block = %{
      "name" => tool_name,
      "input" => input,
      "id" => task[:task_id] || task["task_id"]
    }

    case Tools.execute(block, tools) do
      {:ok, result} -> {:ok, result}
      {:ok, result, _meta} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      {:error, reason, _meta} -> {:error, reason}
    end
  end
end
