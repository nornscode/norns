defmodule Norns.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias Norns.Tools.{Executor, Tool}

  describe "execute/2" do
    test "calls the matching tool handler" do
      tool = %Tool{
        name: "greet",
        description: "Say hello",
        input_schema: %{},
        handler: fn %{"name" => name} -> {:ok, "Hello, #{name}!"} end
      }

      assert {:ok, "Hello, World!"} =
               Executor.execute(%{"name" => "greet", "input" => %{"name" => "World"}}, [tool])
    end

    test "returns error for unknown tool" do
      assert {:error, "Unknown tool: nope"} =
               Executor.execute(%{"name" => "nope", "input" => %{}}, [])
    end

    test "catches handler exceptions" do
      tool = %Tool{
        name: "boom",
        description: "Explode",
        input_schema: %{},
        handler: fn _ -> raise "kaboom" end
      }

      assert {:error, "Tool execution error: kaboom"} =
               Executor.execute(%{"name" => "boom", "input" => %{}}, [tool])
    end
  end

  describe "execute_all/2" do
    test "returns tool_result blocks for each tool call" do
      tool = %Tool{
        name: "echo",
        description: "Echo input",
        input_schema: %{},
        handler: fn %{"msg" => msg} -> {:ok, "echo: #{msg}"} end
      }

      blocks = [
        %{"id" => "call_1", "type" => "tool_use", "name" => "echo", "input" => %{"msg" => "hello"}},
        %{"id" => "call_2", "type" => "tool_use", "name" => "echo", "input" => %{"msg" => "world"}}
      ]

      results = Executor.execute_all(blocks, [tool])
      assert length(results) == 2

      assert Enum.all?(results, fn r ->
               r["type"] == "tool_result" && is_binary(r["content"])
             end)
    end

    test "marks errors with is_error flag" do
      blocks = [%{"id" => "call_1", "type" => "tool_use", "name" => "missing", "input" => %{}}]

      [result] = Executor.execute_all(blocks, [])
      assert result["is_error"] == true
      assert result["content"] =~ "Unknown tool"
    end
  end
end
