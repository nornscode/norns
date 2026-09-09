defmodule Norns.Workers.WorkerRegistryDrainTest do
  use ExUnit.Case, async: false

  alias Norns.Workers.WorkerRegistry

  @tenant 7_301
  # Gard-bound so LLM dispatch cannot fall through to the test suite's
  # default LLM worker; the gard row does not exist, which only costs a
  # warning when the worker unregisters.
  @gard 7_301
  @tools [%{"name" => "drain_tool", "description" => "D", "input_schema" => %{}}]

  setup do
    on_exit(fn ->
      WorkerRegistry.unregister_worker(@tenant, "d1")
      WorkerRegistry.unregister_worker(@tenant, "d2")
      Process.sleep(20)
    end)

    :ok
  end

  test "a draining worker keeps its in-flight task but gets no new ones" do
    :ok = WorkerRegistry.register_worker(@tenant, "d1", self(), @tools, capabilities: [:llm, :tools], gard: @gard)

    {:ok, in_flight} = WorkerRegistry.dispatch_task(@tenant, "drain_tool", %{}, from_pid: self(), gard: @gard)
    assert_receive {:push_tool_task, %{task_id: ^in_flight}}

    WorkerRegistry.drain_worker(@tenant, "d1")
    assert [%{worker_id: "d1", draining: true}] = WorkerRegistry.connected_workers(@tenant)

    # New work queues instead of reaching the draining worker — tools and LLM alike.
    {:ok, queued_tool} = WorkerRegistry.dispatch_task(@tenant, "drain_tool", %{}, from_pid: self(), gard: @gard)
    {:ok, queued_llm} = WorkerRegistry.dispatch_llm_task(@tenant, %{messages: []}, from_pid: self(), gard: @gard)
    refute_receive {:push_tool_task, %{task_id: ^queued_tool}}, 50
    refute_receive {:llm_task, %{task_id: ^queued_llm}}, 50

    # The in-flight task still completes normally.
    WorkerRegistry.deliver_result(in_flight, %{"status" => "ok", "result" => "done"})
    assert_receive {:task_result, ^in_flight, {:ok, "done"}}

    # The queued work flushes to its replacement.
    :ok = WorkerRegistry.register_worker(@tenant, "d2", self(), @tools, capabilities: [:llm, :tools], gard: @gard)
    assert_receive {:push_tool_task, %{task_id: ^queued_tool}}
    assert_receive {:llm_task, %{task_id: ^queued_llm}}
  end

  test "the drained worker's tools stay advertised until it leaves" do
    :ok = WorkerRegistry.register_worker(@tenant, "d1", self(), @tools)
    WorkerRegistry.drain_worker(@tenant, "d1")
    assert [%{name: "drain_tool"}] = WorkerRegistry.available_tools(@tenant)
  end

  test "draining an unknown worker is a no-op" do
    WorkerRegistry.drain_worker(@tenant, "nobody")
    assert WorkerRegistry.connected_workers(@tenant) == []
  end
end
