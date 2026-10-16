defmodule NornsWeb.ServerlessWorkerController do
  use NornsWeb, :controller

  alias Norns.Workers.{ServerlessWorkers, WorkerRegistry}

  def index(conn, _params) do
    tenant = conn.assigns.current_tenant
    awake = awake_ids(tenant.id)

    data =
      tenant.id
      |> ServerlessWorkers.list_serverless_workers()
      |> Enum.map(&NornsWeb.JSON.serverless_worker(&1, awake: &1.worker_id in awake))

    json(conn, %{data: data})
  end

  # The secret appears in this response and nowhere else afterwards.
  def create(conn, params) do
    tenant = conn.assigns.current_tenant
    attrs = params |> Map.drop(["secret"]) |> Map.put("tenant_id", tenant.id)

    case ServerlessWorkers.create_serverless_worker(attrs) do
      {:ok, worker} ->
        conn
        |> put_status(201)
        |> json(%{data: NornsWeb.JSON.serverless_worker(worker, secret: true, awake: false)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, worker} <- fetch(tenant.id, id) do
      json(conn, %{
        data:
          NornsWeb.JSON.serverless_worker(worker, awake: worker.worker_id in awake_ids(tenant.id))
      })
    end
  end

  def update(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant

    with {:ok, worker} <- fetch(tenant.id, id) do
      attrs = Map.drop(params, ["id", "tenant_id", "secret"])

      case ServerlessWorkers.update_serverless_worker(worker, attrs) do
        {:ok, worker} ->
          json(conn, %{
            data:
              NornsWeb.JSON.serverless_worker(worker,
                awake: worker.worker_id in awake_ids(tenant.id)
              )
          })

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, worker} <- fetch(tenant.id, id) do
      {:ok, _} = ServerlessWorkers.delete_serverless_worker(worker)
      send_resp(conn, 204, "")
    end
  end

  # Send the wake now, outside dispatch. For checking a deployment end to
  # end: the worker should appear in GET /workers shortly after.
  def wake(conn, %{"serverless_worker_id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, worker} <- fetch(tenant.id, id) do
      :ok = Norns.Workers.Wake.wake_async(worker)
      conn |> put_status(202) |> json(%{data: %{worker_id: worker.worker_id, status: "waking"}})
    end
  end

  defp awake_ids(tenant_id) do
    tenant_id |> WorkerRegistry.connected_workers() |> MapSet.new(& &1.worker_id)
  end

  defp fetch(tenant_id, id) do
    case ServerlessWorkers.get_serverless_worker(tenant_id, id) do
      nil -> {:error, :not_found}
      worker -> {:ok, worker}
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  def action(conn, _) do
    case apply(__MODULE__, action_name(conn), [conn, conn.params]) do
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
      conn -> conn
    end
  end
end
