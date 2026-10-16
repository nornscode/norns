defmodule Norns.Workers.ServerlessWorkers do
  @moduledoc """
  Serverless workers: tenant-scoped CRUD, kept in step with the registry.

  A row here is a standing declaration. Creating or enabling one tells
  `Norns.Workers.WorkerRegistry` what the worker offers and where to wake it;
  deleting or disabling one withdraws that. `load_all/0` replays every
  enabled row into the registry at boot, since the registry's state is in
  memory.
  """

  import Ecto.Query

  require Logger

  alias Norns.Repo
  alias Norns.Workers.{ServerlessWorker, WorkerRegistry}

  def list_serverless_workers(tenant_id) do
    Repo.all(from w in ServerlessWorker, where: w.tenant_id == ^tenant_id, order_by: w.id)
  end

  def get_serverless_worker(tenant_id, id) do
    Repo.get_by(ServerlessWorker, id: id, tenant_id: tenant_id)
  end

  def create_serverless_worker(attrs) do
    %ServerlessWorker{}
    |> ServerlessWorker.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&sync_registry/1)
  end

  def update_serverless_worker(%ServerlessWorker{} = worker, attrs) do
    worker
    |> ServerlessWorker.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&sync_registry/1)
  end

  def delete_serverless_worker(%ServerlessWorker{} = worker) do
    worker
    |> Repo.delete()
    |> tap_ok(&WorkerRegistry.unregister_serverless_worker(&1.tenant_id, &1.worker_id))
  end

  @doc """
  Record that the registry woke this worker at `at`.

  The registry keeps its own copy for the page and the API; this one is so
  the fact survives a restart. Idempotent and quiet: a missing row (deleted
  while the wake was in flight) updates nothing.
  """
  def mark_woken(tenant_id, worker_id, %DateTime{} = at) do
    from(w in ServerlessWorker, where: w.tenant_id == ^tenant_id and w.worker_id == ^worker_id)
    |> Repo.update_all(set: [last_woken_at: at])

    :ok
  end

  @doc "Register every enabled serverless worker. Called on boot; safe to repeat."
  def load_all do
    ServerlessWorker
    |> where([w], w.enabled == true)
    |> Repo.all()
    |> Enum.each(&WorkerRegistry.register_serverless_worker/1)
  rescue
    e -> Logger.warning("Could not load serverless workers: #{Exception.message(e)}")
  end

  defp sync_registry(%ServerlessWorker{enabled: true} = worker),
    do: WorkerRegistry.register_serverless_worker(worker)

  defp sync_registry(%ServerlessWorker{} = worker),
    do: WorkerRegistry.unregister_serverless_worker(worker.tenant_id, worker.worker_id)

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end
