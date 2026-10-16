defmodule Norns.Workers.WorkerRegistryServerlessTest do
  use ExUnit.Case, async: false

  alias Norns.Workers.{HttpSignature, ServerlessWorker, TaskQueue, WorkerRegistry}

  @tool %{"name" => "sl_search", "description" => "Search", "input_schema" => %{}}

  # The registry and queue are the application's own, shared across tests, so
  # each test gets a tenant of its own: nothing queued by one can wake another.
  # Wakes are matched on this test's worker_id (a re-wake timer from an
  # earlier test can still fire), and the tenant's queue is emptied on exit.
  setup do
    Norns.WakeStub.install()
    tenant = 100_000 + System.unique_integer([:positive])
    worker_id = "fn-#{System.unique_integer([:positive])}"

    worker = %ServerlessWorker{
      tenant_id: tenant,
      worker_id: worker_id,
      wake_url: "http://worker.test/wake",
      secret: "wake-secret",
      tools: [@tool],
      capabilities: ["llm", "tools"],
      enabled: true
    }

    :ok = WorkerRegistry.register_serverless_worker(worker)

    on_exit(fn ->
      WorkerRegistry.unregister_serverless_worker(tenant, worker_id)
      WorkerRegistry.unregister_worker(tenant, worker_id)
      TaskQueue.flush(tenant, "sl_search")
      TaskQueue.flush(tenant, "something_else")
      TaskQueue.flush(tenant, "__llm__")
    end)

    %{worker: worker, tenant: tenant, wid: worker_id}
  end

  test "a sleeping worker's declared tools and LLM capability are advertised", %{
    worker: worker,
    tenant: tenant
  } do
    assert [%{name: "sl_search", source: {:remote, ^tenant}}] =
             WorkerRegistry.available_tools(tenant)

    assert WorkerRegistry.llm_available?(tenant)
    # Gard-bound runs cannot reach it: it has no filesystem to be affine to.
    assert [] = WorkerRegistry.available_tools(tenant, gard: 1)

    WorkerRegistry.unregister_serverless_worker(tenant, worker.worker_id)
    Process.sleep(20)
    assert [] = WorkerRegistry.available_tools(tenant)
  end

  test "serverless_workers/1 reports the declaration, whether it is awake, and when it was woken",
       %{tenant: tenant, wid: wid} do
    assert [%{worker_id: ^wid, awake: false, last_woken_at: nil, tools: ["sl_search"], tool_count: 1} = entry] =
             WorkerRegistry.serverless_workers(tenant)

    assert Enum.sort(entry.capabilities) == [:llm, :tools]

    {:ok, _} = WorkerRegistry.dispatch_task(tenant, "sl_search", %{}, from_pid: self())
    assert_receive {:wake, %{worker_id: ^wid}}, 1_000

    assert [%{awake: false, last_woken_at: %DateTime{}}] = WorkerRegistry.serverless_workers(tenant)

    :ok = WorkerRegistry.register_worker(tenant, wid, self(), [@tool])
    assert [%{awake: true, last_woken_at: %DateTime{}}] = WorkerRegistry.serverless_workers(tenant)
  end

  test "a tool task with no connected worker queues, wakes the declarer, and flushes when it joins",
       %{worker: worker, tenant: tenant, wid: wid} do
    {:ok, task_id} =
      WorkerRegistry.dispatch_task(tenant, "sl_search", %{"q" => "x"}, from_pid: self())

    assert_receive {:wake, %{worker_id: ^wid, body: body, signature: signature}}, 1_000
    assert %{"type" => "wake", "worker_id" => ^wid} = Jason.decode!(body)
    assert :ok = HttpSignature.verify(worker.secret, body, signature)

    # The function came up and joined as an ordinary worker: the queued task
    # flushes to it, and its answer reaches the agent.
    :ok =
      WorkerRegistry.register_worker(tenant, wid, self(), [@tool], capabilities: [:llm, :tools])

    assert_receive {:push_tool_task, %{task_id: ^task_id, tool_name: "sl_search"}}, 1_000

    WorkerRegistry.deliver_result(task_id, %{"status" => "ok", "result" => "found"})
    assert {:ok, "found"} = WorkerRegistry.await_result(task_id, 1_000)
  end

  # LLM dispatch falls back to the :default-tenant worker, which the test
  # suite always has, so an LLM task never queues here. Queue one by hand to
  # exercise the llm half of the declaration: a re-declaration finds it and
  # wakes, and the join flushes it.
  test "queued LLM work wakes a declarer with the llm capability", %{
    worker: worker,
    tenant: tenant,
    wid: wid
  } do
    task_id = "llm-#{System.unique_integer([:positive])}"

    TaskQueue.enqueue(tenant, %{
      task_id: task_id,
      tool_name: "__llm__",
      input: %{model: "m"},
      from_pid: self(),
      gard: nil
    })

    # enqueue is a cast; a call from the same process guarantees it landed
    # before the registry peeks at the queue.
    assert [_] = TaskQueue.peek(tenant)

    :ok = WorkerRegistry.register_serverless_worker(worker)
    assert_receive {:wake, %{worker_id: ^wid}}, 1_000

    :ok =
      WorkerRegistry.register_worker(tenant, wid, self(), [@tool], capabilities: [:llm, :tools])

    assert_receive {:llm_task, %{task_id: ^task_id}}, 1_000
  end

  test "a connected incarnation is dispatched to directly, with no wake", %{
    tenant: tenant,
    wid: wid
  } do
    :ok = WorkerRegistry.register_worker(tenant, wid, self(), [@tool])

    {:ok, task_id} = WorkerRegistry.dispatch_task(tenant, "sl_search", %{}, from_pid: self())
    assert_receive {:push_tool_task, %{task_id: ^task_id}}, 1_000
    refute_receive {:wake, %{worker_id: ^wid}}, 200

    assert [%{serverless: true}] = WorkerRegistry.connected_workers(tenant)
  end

  test "one wake per cooldown, then again while work is still queued", %{tenant: tenant, wid: wid} do
    {:ok, _} = WorkerRegistry.dispatch_task(tenant, "sl_search", %{}, from_pid: self())
    {:ok, _} = WorkerRegistry.dispatch_task(tenant, "sl_search", %{}, from_pid: self())

    assert_receive {:wake, %{worker_id: ^wid}}, 1_000
    refute_receive {:wake, %{worker_id: ^wid}}, 100

    # Cooldown (150ms in test) passes with the worker still absent and the
    # tasks still queued: it is woken again.
    assert_receive {:wake, %{worker_id: ^wid}}, 1_000
  end

  test "a worker that is not declared for the tool is left asleep", %{tenant: tenant, wid: wid} do
    {:ok, _} = WorkerRegistry.dispatch_task(tenant, "something_else", %{}, from_pid: self())
    refute_receive {:wake, %{worker_id: ^wid}}, 200
  end

  test "a failed wake is logged, not raised, and the task stays queued", %{
    tenant: tenant,
    wid: wid
  } do
    Norns.WakeStub.install(503)

    {:ok, task_id} = WorkerRegistry.dispatch_task(tenant, "sl_search", %{}, from_pid: self())
    assert_receive {:wake, %{worker_id: ^wid}}, 1_000

    :ok = WorkerRegistry.register_worker(tenant, wid, self(), [@tool])
    assert_receive {:push_tool_task, %{task_id: ^task_id}}, 1_000
  end
end
