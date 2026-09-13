defmodule Norns.Runtime.TenantIsolationTest do
  @moduledoc "Gate 4: Tenant/auth boundary stability."
  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.TestWorker.LLM
  alias Norns.Workers.WorkerRegistry

  describe "secret path validation" do
    test "orchestrator never holds a provider API key in agent state" do
      tenant = create_tenant(%{api_keys: %{"norns" => "nrn_test123", "anthropic" => "sk-should-be-ignored"}})
      agent = create_agent(tenant)

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle
      refute Map.has_key?(state, :api_key)
    end

    test "LLM tasks never carry a provider API key; the worker supplies its own" do
      tenant = create_tenant(%{api_keys: %{"norns" => "nrn_test123", "anthropic" => "sk-should-be-ignored"}})
      agent = create_agent(tenant)

      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      AgentProcess.send_message(pid, "test")

      receive do
        {:completed, _} -> :ok
      after
        5000 -> flunk("Did not complete")
      end

      # The test worker calls the fake with its own key, never the tenant's
      [call] = LLM.calls()
      assert call.api_key == "test-worker-key"
      refute call.api_key == "sk-should-be-ignored"
    end

    test "tenant-scoped workers only receive tasks for their tenant" do
      tools = [%{"name" => "t1_tool", "description" => "T1", "input_schema" => %{}}]

      :ok = WorkerRegistry.register_worker(1, "tenant-1-worker", self(), tools)
      :ok = WorkerRegistry.register_worker(2, "tenant-2-worker", spawn(fn -> Process.sleep(:infinity) end), tools)

      # Dispatch to tenant 1
      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "t1_tool", %{}, from_pid: self())

      # Should be received by tenant 1's worker (this process)
      assert_receive {:push_tool_task, %{task_id: ^task_id}}, 1000

      WorkerRegistry.unregister_worker(1, "tenant-1-worker")
      WorkerRegistry.unregister_worker(2, "tenant-2-worker")
    end

    test "tenant 2 worker does not receive tenant 1 tasks" do
      test_pid = self()
      tenant_2_pid = spawn(fn ->
        receive do
          {:push_tool_task, _task} -> send(test_pid, :tenant_2_got_task)
        after
          500 -> send(test_pid, :tenant_2_clean)
        end
      end)

      tools = [%{"name" => "shared_tool", "description" => "Shared", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "w1", self(), tools)
      :ok = WorkerRegistry.register_worker(2, "w2", tenant_2_pid, tools)

      {:ok, _} = WorkerRegistry.dispatch_task(1, "shared_tool", %{}, from_pid: self())

      assert_receive {:push_tool_task, _}, 1000
      assert_receive :tenant_2_clean, 1000

      WorkerRegistry.unregister_worker(1, "w1")
      WorkerRegistry.unregister_worker(2, "w2")
    end
  end
end
