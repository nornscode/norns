defmodule Norns.Workers.DefaultWorker do
  @moduledoc """
  Built-in worker that runs in the same BEAM VM as the orchestrator.
  Handles LLM calls and built-in tool execution.

  Receives tasks in neutral format, translates to Anthropic API for LLM calls,
  and returns results in neutral format.
  """

  use GenServer

  require Logger

  alias Norns.LLM
  alias Norns.LLM.Format
  alias Norns.Tools.Executor
  alias Norns.Workers.WorkerRegistry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    tools = Norns.Tools.Registry.all_tools()

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
      :default,
      "default-worker",
      self(),
      tool_defs,
      capabilities: [:llm, :tools]
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

  # -- LLM Execution --
  # Receives neutral format, translates to Anthropic API, returns neutral format

  defp execute_llm(task) do
    api_key = task.api_key
    model = task.model
    system_prompt = task.system_prompt
    messages = task.messages
    tools = task[:tools] || []

    # Translate neutral → Anthropic format for the API call
    anthropic_messages = Format.to_anthropic_messages(messages)
    anthropic_tools = if tools != [], do: Format.to_anthropic_tools(tools), else: []

    opts = if anthropic_tools != [], do: [tools: anthropic_tools], else: []

    case LLM.chat(api_key, model, system_prompt, anthropic_messages, opts) do
      {:ok, response} ->
        # Translate Anthropic response → neutral format
        # LLM.chat returns a struct with .content (list), .stop_reason, .usage
        anthropic_body = %{
          "content" => response.content,
          "stop_reason" => response.stop_reason,
          "usage" => %{
            "input_tokens" => response.usage.input_tokens,
            "output_tokens" => response.usage.output_tokens
          }
        }

        neutral = Format.from_anthropic_response(anthropic_body)
        Map.put(neutral, "status", "ok")

      {:error, reason} ->
        %{"status" => "error", "error" => reason}
    end
  end

  # -- Tool Execution --

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
