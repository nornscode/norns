defmodule NornsWeb.RunWebhookController do
  use NornsWeb, :controller

  alias Norns.Runs.RunWebhooks

  def index(conn, _params) do
    tenant = conn.assigns.current_tenant
    data = tenant.id |> RunWebhooks.list_run_webhooks() |> Enum.map(&NornsWeb.JSON.run_webhook/1)
    json(conn, %{data: data})
  end

  # The secret appears in this response and nowhere else afterwards.
  def create(conn, params) do
    tenant = conn.assigns.current_tenant
    attrs = params |> Map.drop(["secret"]) |> Map.put("tenant_id", tenant.id)

    case RunWebhooks.create_run_webhook(attrs) do
      {:ok, webhook} ->
        conn
        |> put_status(201)
        |> json(%{data: NornsWeb.JSON.run_webhook(webhook, secret: true)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, webhook} <- fetch(tenant.id, id) do
      json(conn, %{data: NornsWeb.JSON.run_webhook(webhook)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant

    with {:ok, webhook} <- fetch(tenant.id, id) do
      attrs = Map.drop(params, ["id", "tenant_id", "secret"])

      case RunWebhooks.update_run_webhook(webhook, attrs) do
        {:ok, webhook} ->
          json(conn, %{data: NornsWeb.JSON.run_webhook(webhook)})

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, webhook} <- fetch(tenant.id, id) do
      {:ok, _} = RunWebhooks.delete_run_webhook(webhook)
      send_resp(conn, 204, "")
    end
  end

  # Deliver a sample event now, synchronously, and report what the receiver
  # answered. For checking a deployment end to end.
  def test(conn, %{"run_webhook_id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, webhook} <- fetch(tenant.id, id) do
      case RunWebhooks.deliver(webhook, "run.test", RunWebhooks.test_body()) do
        :ok ->
          json(conn, %{data: %{status: "delivered"}})

        {:error, {:status, status}} ->
          conn
          |> put_status(502)
          |> json(%{data: %{status: "rejected", http_status: status}})

        {:error, exception} ->
          conn
          |> put_status(502)
          |> json(%{data: %{status: "unreachable", error: Exception.message(exception)}})
      end
    end
  end

  defp fetch(tenant_id, id) do
    case RunWebhooks.get_run_webhook(tenant_id, id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
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
