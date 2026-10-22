defmodule NornsWeb.ApiKeyController do
  use NornsWeb, :controller

  alias Norns.Tenants

  # Only a tenant key reaches this controller: the Auth plug turns scoped
  # keys away from every REST route, this one included, so a scoped key
  # cannot mint another.

  def index(conn, _params) do
    tenant = conn.assigns.current_tenant
    json(conn, %{data: Enum.map(Tenants.list_api_keys(tenant.id), &NornsWeb.JSON.api_key/1)})
  end

  def create(conn, params) do
    tenant = conn.assigns.current_tenant

    case Tenants.create_api_key(tenant.id, Map.take(params, ["name", "scope"])) do
      {:ok, key} ->
        # The token is returned exactly once, here. List never includes it.
        data = key |> NornsWeb.JSON.api_key() |> Map.put(:token, key.token)
        conn |> put_status(201) |> json(%{data: data})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def delete(conn, %{"name" => name}) do
    tenant = conn.assigns.current_tenant

    case Tenants.revoke_api_key(tenant.id, name) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
