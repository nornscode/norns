defmodule Norns.Tools.Executor do
  @moduledoc "Matches tool_use blocks to registered tools and executes them."

  alias Norns.Tools.Tool

  @doc """
  Execute a tool call. Finds the matching tool by name and calls its handler.

  Returns `{:ok, result_string}` or `{:error, error_string}`.
  """
  def execute(%{"name" => name, "input" => input}, tools) when is_list(tools) do
    case Enum.find(tools, &(&1.name == name)) do
      %Tool{handler: handler} ->
        try do
          handler.(input)
        rescue
          e -> {:error, "Tool execution error: #{Exception.message(e)}"}
        end

      nil ->
        {:error, "Unknown tool: #{name}"}
    end
  end

  @doc "Execute multiple tool calls, returning a list of tool_result content blocks."
  def execute_all(tool_use_blocks, tools) do
    Enum.map(tool_use_blocks, fn %{"id" => id} = block ->
      {status, content} =
        case execute(block, tools) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      result = %{
        "type" => "tool_result",
        "tool_use_id" => id,
        "content" => content
      }

      if status == :error do
        Map.put(result, "is_error", true)
      else
        result
      end
    end)
  end
end
