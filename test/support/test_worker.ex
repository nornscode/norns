defmodule Norns.TestWorker do
  @moduledoc """
  Test worker that registers with WorkerRegistry and handles LLM + tool tasks
  using the Fake LLM. Started in test setup, not in the application supervisor.
  """

  use GenServer

  alias Norns.LLM
  alias Norns.LLM.Format
  alias Norns.Tools.Executor
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
    gard = Keyword.get(opts, :gard)

    tool_defs =
      Enum.map(tools, fn tool ->
        %{
          "name" => tool.name,
          "description" => tool.description,
          "input_schema" => tool.input_schema,
          "side_effect" => Map.get(tool, :side_effect?, false)
        }
      end)

    WorkerRegistry.register_worker(
      tenant,
      worker_id,
      self(),
      tool_defs,
      capabilities: capabilities,
      gard: gard
    )

    {:ok, %{tools: tools}}
  end

  @impl true
  def handle_info({:push_tool_task, task}, state) do
    Task.start(fn ->
      result = execute_tool(task, state.tools)

      WorkerRegistry.deliver_result(task[:task_id] || task["task_id"], %{
        "status" => if(match?({:ok, _}, result), do: "ok", else: "error"),
        "result" => elem(result, 1),
        "error" => if(match?({:error, _}, result), do: elem(result, 1))
      })
    end)

    {:noreply, state}
  end

  def handle_info({:llm_task, task}, state) do
    Task.start(fn ->
      result = execute_llm(task)
      WorkerRegistry.deliver_result(task.task_id, result)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
          "usage" => %{
            "input_tokens" => response.usage.input_tokens,
            "output_tokens" => response.usage.output_tokens
          }
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

    case Executor.execute(block, tools) do
      {:ok, result} -> {:ok, result}
      {:ok, result, _meta} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      {:error, reason, _meta} -> {:error, reason}
    end
  end
end
