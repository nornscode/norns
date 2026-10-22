defmodule Norns.Workers.WorkerRegistryGardTest do
  use Norns.DataCase, async: false

  alias Norns.Workers.WorkerRegistry

  # Unique tenant ids per test keep the shared registry from cross-talking.
  defp tenant_id, do: System.unique_integer([:positive]) + 100_000

  defp tool_def(name), do: %{"name" => name, "description" => name, "input_schema" => %{}}

  describe "available_tools/2 gard filter" do
    # A gard is not an island: the tenant-wide service workers run with no
    # gard, and a run whose shell lives in a gard still needs their tools.
    # The reverse does not hold — a no-gard run never sees a gard's tools.
    test "a gard caller sees its gard's tools and the no-gard tools, each tagged with its gard" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("plain_tool")])
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("gard_tool")], gard: 42)
      :ok = WorkerRegistry.register_worker(tid, "other", self(), [tool_def("other_tool")], gard: 99)

      assert [%{name: "plain_tool", gard: nil}] = WorkerRegistry.available_tools(tid)

      tools = WorkerRegistry.available_tools(tid, gard: 42)
      assert Enum.map(tools, &{&1.name, &1.gard}) == [{"gard_tool", 42}, {"plain_tool", nil}]

      assert [%{name: "plain_tool", gard: nil}] = WorkerRegistry.available_tools(tid, gard: 7)

      WorkerRegistry.unregister_worker(tid, "plain")
      WorkerRegistry.unregister_worker(tid, "garded")
      WorkerRegistry.unregister_worker(tid, "other")
    end

    test "on a name collision the gard wins, so affinity holds for the gard's own tools" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("read_file")])
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("read_file")], gard: 42)

      assert [%{name: "read_file", gard: 42}] = WorkerRegistry.available_tools(tid, gard: 42)
      assert [%{name: "read_file", gard: nil}] = WorkerRegistry.available_tools(tid)

      WorkerRegistry.unregister_worker(tid, "plain")
      WorkerRegistry.unregister_worker(tid, "garded")
    end
  end

  describe "dispatch_task/4 gard strictness" do
    # Dispatch stays strict on the task's gard. A gard-bound run reaching a
    # no-gard tool is the agent process dispatching that call with gard nil,
    # as the offered list told it to — not the registry reaching past the
    # gard. That is what keeps a gard's `read_file` off a service worker
    # with the same tool name while the gard's worker is reconnecting.
    test "a gard-bound task never reaches a no-gard worker (it queues instead)" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("shared_tool")])

      {:ok, _} = WorkerRegistry.dispatch_task(tid, "shared_tool", %{}, from_pid: self(), gard: 42)
      refute_receive {:push_tool_task, _}, 100

      WorkerRegistry.unregister_worker(tid, "plain")
    end

    test "a no-gard task never reaches a gard-bound worker (no stolen dispatch)" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("shared_tool")], gard: 42)

      {:ok, _} = WorkerRegistry.dispatch_task(tid, "shared_tool", %{}, from_pid: self())
      refute_receive {:push_tool_task, _}, 100

      WorkerRegistry.unregister_worker(tid, "garded")
    end

    test "a gard-bound task reaches the matching gard worker" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("shared_tool")], gard: 42)

      {:ok, task_id} = WorkerRegistry.dispatch_task(tid, "shared_tool", %{}, from_pid: self(), gard: 42)
      assert_receive {:push_tool_task, %{task_id: ^task_id}}, 500

      WorkerRegistry.unregister_worker(tid, "garded")
    end
  end

  describe "queued task flush is gard-aware" do
    test "a queued gard task waits for a matching-gard worker" do
      tid = tenant_id()

      # No worker yet — both tasks queue.
      {:ok, gard_task} = WorkerRegistry.dispatch_task(tid, "late_tool", %{}, from_pid: self(), gard: 42)
      {:ok, plain_task} = WorkerRegistry.dispatch_task(tid, "late_tool", %{}, from_pid: self())

      # A no-gard worker connects: only the no-gard task flushes to it.
      :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("late_tool")])
      assert_receive {:push_tool_task, %{task_id: ^plain_task}}, 500
      refute_receive {:push_tool_task, _}, 100

      # The gard worker connects: the gard task flushes to it.
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("late_tool")], gard: 42)
      assert_receive {:push_tool_task, %{task_id: ^gard_task}}, 500

      WorkerRegistry.unregister_worker(tid, "plain")
      WorkerRegistry.unregister_worker(tid, "garded")
    end
  end

  describe "LLM dispatch gard strictness" do
    # LLM calls are stateless but the worker's LLM credentials are not: a
    # gard deployment's API key must not silently serve other runs, and a
    # lone gard worker half-serving a plain run (LLM works, tools hang) is
    # worse than queueing the run whole.
    test "a no-gard LLM task never reaches a gard-bound worker (it queues)" do
      tid = tenant_id()

      :ok =
        WorkerRegistry.register_worker(tid, "garded-llm", self(), [],
          capabilities: [:llm],
          gard: 42
        )

      {:ok, _, _} = WorkerRegistry.dispatch_llm_task(tid, %{model: "m"}, from_pid: self())
      refute_receive {:llm_task, _}, 100

      WorkerRegistry.unregister_worker(tid, "garded-llm")
    end

    test "a gard-bound LLM task reaches only its gard's worker" do
      tid = tenant_id()

      :ok = WorkerRegistry.register_worker(tid, "plain-llm", self(), [], capabilities: [:llm])

      {:ok, _, _} = WorkerRegistry.dispatch_llm_task(tid, %{model: "m"}, from_pid: self(), gard: 42)
      refute_receive {:llm_task, _}, 100

      :ok =
        WorkerRegistry.register_worker(tid, "garded-llm", self(), [],
          capabilities: [:llm],
          gard: 42
        )

      {:ok, task_id, _} = WorkerRegistry.dispatch_llm_task(tid, %{model: "m"}, from_pid: self(), gard: 42)
      assert_receive {:llm_task, %{task_id: ^task_id}}, 500

      WorkerRegistry.unregister_worker(tid, "plain-llm")
      WorkerRegistry.unregister_worker(tid, "garded-llm")
    end

    test "a queued gard LLM task flushes only to a matching-gard worker" do
      # No-gard LLM tasks can't be part of this scenario: the global
      # :default-tenant test worker absorbs them before they ever queue.
      tid = tenant_id()

      {:ok, gard_task, _} = WorkerRegistry.dispatch_llm_task(tid, %{model: "m"}, from_pid: self(), gard: 42)

      :ok = WorkerRegistry.register_worker(tid, "plain-llm", self(), [], capabilities: [:llm])
      refute_receive {:llm_task, _}, 100

      :ok =
        WorkerRegistry.register_worker(tid, "garded-llm", self(), [],
          capabilities: [:llm],
          gard: 42
        )

      assert_receive {:llm_task, %{task_id: ^gard_task}}, 500

      WorkerRegistry.unregister_worker(tid, "plain-llm")
      WorkerRegistry.unregister_worker(tid, "garded-llm")
    end
  end

  describe "gard status follows the worker connection" do
    test "unregistering a gard worker marks the gard disconnected" do
      tenant = create_tenant()
      {:ok, gard} = Norns.Gards.create_gard(%{tenant_id: tenant.id, name: "g"})
      :ok = Norns.Gards.claim(tenant.id, gard.id, gard.claim_token)

      :ok = WorkerRegistry.register_worker(tenant.id, "gw", self(), [], gard: gard.id)
      WorkerRegistry.unregister_worker(tenant.id, "gw")
      Process.sleep(100)

      assert Norns.Gards.get_gard(tenant.id, gard.id).status == "disconnected"
    end
  end
end
