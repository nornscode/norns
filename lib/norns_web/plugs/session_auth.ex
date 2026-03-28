defmodule NornsWeb.Plugs.SessionAuth do
  @moduledoc """
  Session-based auth for the browser UI.

  - ?token=<api_key> in query params authenticates and stores in session
  - Session tenant_id is loaded on subsequent requests
  - If no tenants exist, redirects to /setup
  - If not authenticated, assigns current_tenant: nil (LiveViews show auth prompt)
  """

  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      # Token in query params — authenticate and store in session
      token = conn.params["token"] ->
        case Norns.Tenants.get_tenant_by_api_key(token) do
          {:ok, tenant} ->
            conn
            |> put_session(:tenant_id, tenant.id)
            |> assign(:current_tenant, tenant)
            |> redirect(to: conn.request_path)
            |> halt()

          _ ->
            conn |> assign(:current_tenant, nil)
        end

      # Tenant ID in session — load it (clear stale sessions if tenant was deleted)
      tenant_id = get_session(conn, :tenant_id) ->
        try do
          tenant = Norns.Tenants.get_tenant!(tenant_id)
          assign(conn, :current_tenant, tenant)
        rescue
          _ ->
            conn
            |> delete_session(:tenant_id)
            |> assign(:current_tenant, nil)
        end

      # No auth — check if any tenants exist
      true ->
        if conn.request_path != "/setup" and Norns.Tenants.list_tenants() == [] do
          conn
          |> redirect(to: "/setup")
          |> halt()
        else
          assign(conn, :current_tenant, nil)
        end
    end
  end
end
