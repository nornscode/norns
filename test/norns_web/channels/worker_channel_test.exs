defmodule NornsWeb.WorkerChannelTest do
  use NornsWeb.ChannelCase, async: false

  alias NornsWeb.{WorkerSocket, WorkerChannel}
  alias Norns.Workers.WorkerRegistry

  setup do
    tenant = create_tenant()
    token = tenant.api_keys |> Map.values() |> List.first()

    {:ok, socket} = connect(WorkerSocket, %{"token" => token})

    %{socket: socket, tenant: tenant}
  end

  describe "join" do
    test "worker joins with tools", %{socket: socket} do
      tools = [%{"name" => "my_tool", "description" => "Does stuff", "input_schema" => %{}}]

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
                 "worker_id" => "test-worker",
                 "tools" => tools
               })

      # Cleanup
      WorkerRegistry.unregister_worker(socket.assigns.tenant_id, "test-worker")
    end

    test "worker joins with capabilities and receives llm tasks", %{socket: socket, tenant: tenant} do
      {:ok, _, socket} =
        subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
          "worker_id" => "llm-worker",
          "tools" => [],
          "capabilities" => ["llm"]
        })

      {:ok, task_id} =
        WorkerRegistry.dispatch_llm_task(tenant.id, %{
          api_key: "test-key",
          model: "claude-sonnet-4-20250514",
          system_prompt: "You are helpful.",
          messages: [%{role: "user", content: "hello"}],
          opts: [],
          agent_id: 11,
          run_id: 22,
          step: 1
        }, from_pid: self())

      assert_push "llm_task", task, 1_000
      assert task["task_id"] == task_id
      assert task["model"] == "claude-sonnet-4-20250514"
      assert task["system_prompt"] == "You are helpful."
      assert task["messages"] == [%{"role" => "user", "content" => "hello"}]
      assert task["agent_id"] == 11
      assert task["run_id"] == 22
      assert task["step"] == 1

      WorkerRegistry.unregister_worker(tenant.id, "llm-worker")
    end

    test "rejects join without worker_id", %{socket: socket} do
      assert {:error, %{reason: "invalid_registration", code: "missing_worker_id_or_tools"}} =
               subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{})
    end

    test "rejects join with invalid tool definitions", %{socket: socket} do
      assert {:error, %{reason: "invalid_registration", code: "invalid_tools"}} =
               subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
                 "worker_id" => "bad-worker",
                 "tools" => [%{"name" => "", "description" => "oops", "input_schema" => %{}}]
               })
    end
  end

  describe "tool_result" do
    test "delivers result to waiting process", %{socket: socket, tenant: tenant} do
      tools = [%{"name" => "rpc_tool", "description" => "RPC", "input_schema" => %{}}]

      {:ok, _, socket} =
        subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
          "worker_id" => "rpc-worker",
          "tools" => tools
        })

      # Dispatch a task from a test "agent"
      {:ok, task_id} =
        WorkerRegistry.dispatch_task(tenant.id, "rpc_tool", %{"arg" => "val"}, from_pid: self())

      # Simulate worker responding
      push(socket, "tool_result", %{
        "task_id" => task_id,
        "status" => "ok",
        "result" => "rpc done"
      })

      # Wait a bit for the message to be processed
      Process.sleep(100)

      assert {:ok, "rpc done"} = WorkerRegistry.await_result(task_id, 1000)

      WorkerRegistry.unregister_worker(tenant.id, "rpc-worker")
    end

    test "normalizes llm result payloads for waiting processes", %{socket: socket, tenant: tenant} do
      {:ok, _, socket} =
        subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
          "worker_id" => "llm-result-worker",
          "tools" => [],
          "capabilities" => ["llm"]
        })

      {:ok, task_id} =
        WorkerRegistry.dispatch_llm_task(tenant.id, %{
          api_key: "test-key",
          model: "claude-sonnet-4-20250514",
          system_prompt: "You are helpful.",
          messages: [%{role: "user", content: "hello"}],
          opts: []
        }, from_pid: self())

      assert_push "llm_task", _task, 1_000

      push(socket, "tool_result", %{
        "task_id" => task_id,
        "status" => "ok",
        "content" => [%{"type" => "text", "text" => "done"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })

      assert {:ok,
              %{
                "content" => [%{"type" => "text", "text" => "done"}],
                "stop_reason" => "end_turn",
                "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
              }} = WorkerRegistry.await_result(task_id, 1_000)

      WorkerRegistry.unregister_worker(tenant.id, "llm-result-worker")
    end
  end

  describe "socket authentication" do
    test "rejects connection without token" do
      assert :error = connect(WorkerSocket, %{})
    end

    test "rejects connection with invalid token" do
      assert :error = connect(WorkerSocket, %{"token" => "bad"})
    end
  end
end
