defmodule Norns.TestWorker.ToolsTest do
  use Norns.DataCase, async: false

  alias Norns.TestWorker.{Tool, Tools}

  describe "execute/2" do
    test "calls the matching tool handler" do
      tool = %Tool{
        name: "greet",
        description: "Say hello",
        input_schema: %{},
        handler: fn %{"name" => name} -> {:ok, "Hello, #{name}!"} end
      }

      assert {:ok, "Hello, World!"} =
               Tools.execute(%{"name" => "greet", "input" => %{"name" => "World"}}, [tool])
    end

    test "returns error for unknown tool" do
      assert {:error, "Unknown tool: nope"} =
               Tools.execute(%{"name" => "nope", "input" => %{}}, [])
    end

    test "catches handler exceptions" do
      tool = %Tool{
        name: "boom",
        description: "Explode",
        input_schema: %{},
        handler: fn _ -> raise "kaboom" end
      }

      assert {:error, "Tool execution error: kaboom"} =
               Tools.execute(%{"name" => "boom", "input" => %{}}, [tool])
    end

    test "adds idempotency context for side-effecting tools" do
      tenant = create_tenant()
      agent = create_agent(tenant)
      {:ok, run} = Norns.Runs.create_run(%{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "message", status: "running"})

      tool = %Tool{
        name: "side_effect",
        description: "Records idempotency context",
        input_schema: %{},
        side_effect?: true,
        handler: fn _ ->
          context = Process.get(:norns_tool_context)
          {:ok, context.idempotency_key}
        end
      }

      expected_key = "run:#{run.id}:step:2:tool:call_1:name:side_effect"

      assert {:ok, ^expected_key, %{"idempotency_key" => ^expected_key}} =
               Tools.execute(%{"id" => "call_1", "name" => "side_effect", "input" => %{}}, [tool], run: run, step: 2)
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

      results = Tools.execute_all(blocks, [tool])
      assert length(results) == 2

      assert Enum.all?(results, fn r ->
               r["type"] == "tool_result" && is_binary(r["content"])
             end)
    end

    test "marks errors with is_error flag" do
      blocks = [%{"id" => "call_1", "type" => "tool_use", "name" => "missing", "input" => %{}}]

      [result] = Tools.execute_all(blocks, [])
      assert result["is_error"] == true
      assert result["content"] =~ "Unknown tool"
    end

    test "reuses persisted result for duplicate side-effect key" do
      tenant = create_tenant()
      agent = create_agent(tenant)
      {:ok, run} = Norns.Runs.create_run(%{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "message", status: "running"})

      Norns.Runs.append_event(run, %{
        event_type: "tool_result",
        payload: %{
          "tool_call_id" => "call_1",
          "name" => "side_effect",
          "content" => "stored-once",
          "is_error" => false,
          "step" => 1,
          "idempotency_key" => "run:#{run.id}:step:1:tool:call_1:name:side_effect"
        }
      })

      tool = %Tool{
        name: "side_effect",
        description: "Should not run twice",
        input_schema: %{},
        side_effect?: true,
        handler: fn _ -> flunk("expected persisted result reuse") end
      }

      [result] =
        Tools.execute_all(
          [%{"id" => "call_1", "type" => "tool_use", "name" => "side_effect", "input" => %{}}],
          [tool],
          run: run,
          step: 1
        )

      assert result["content"] == "stored-once"
      assert result["idempotency_key"] == "run:#{run.id}:step:1:tool:call_1:name:side_effect"
      assert result["duplicate_detected"] == true
      assert result["duplicate_original_event_sequence"] == 1
      refute result["is_error"]
    end
  end
end
