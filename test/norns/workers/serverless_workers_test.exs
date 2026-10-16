defmodule Norns.Workers.ServerlessWorkersTest do
  use Norns.DataCase, async: false

  alias Norns.Workers.{ServerlessWorkers, WorkerRegistry}

  @tool %{"name" => "sl_persist", "description" => "Search", "input_schema" => %{}}

  setup do
    tenant = create_tenant()
    worker_id = "fn-#{System.unique_integer([:positive])}"

    {:ok, worker} =
      ServerlessWorkers.create_serverless_worker(%{
        tenant_id: tenant.id,
        worker_id: worker_id,
        wake_url: "http://worker.test/wake",
        tools: [@tool]
      })

    on_exit(fn -> WorkerRegistry.unregister_serverless_worker(tenant.id, worker_id) end)

    %{tenant: tenant, worker: worker}
  end

  test "a recorded wake survives the registry forgetting the declaration", %{
    tenant: tenant,
    worker: worker
  } do
    assert [%{last_woken_at: nil}] = WorkerRegistry.serverless_workers(tenant.id)

    woken_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    :ok = ServerlessWorkers.mark_woken(tenant.id, worker.worker_id, woken_at)

    # What a restart does: the in-memory entry is gone, the row is replayed.
    WorkerRegistry.unregister_serverless_worker(tenant.id, worker.worker_id)
    Process.sleep(20)
    assert [] = WorkerRegistry.serverless_workers(tenant.id)

    ServerlessWorkers.load_all()
    assert [%{last_woken_at: ^woken_at}] = WorkerRegistry.serverless_workers(tenant.id)
  end

  test "marking a worker that no longer exists is a no-op", %{tenant: tenant} do
    assert :ok = ServerlessWorkers.mark_woken(tenant.id, "gone", DateTime.utc_now())
  end
end
