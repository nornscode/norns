defmodule NornsWeb.Plugs.Auth do
  @moduledoc """
  Bearer token auth for the REST API.

  A tenant key gets the tenant. A scoped key (`Norns.Tenants.ApiKey`) is
  recognised and refused: its one job is the worker socket, and every REST
  route — runs, agents, conversations, triggers, messages, key management —
  answers 403 so that a key read out of a gard's process environment is
  worth nothing here.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, tenant, scope} <- Norns.Tenants.authenticate(token) do
      case scope do
        nil ->
          assign(conn, :current_tenant, tenant)

        _scoped ->
          conn
          |> put_status(403)
          |> Phoenix.Controller.json(%{error: "forbidden", reason: "this key is scoped to a gard worker and cannot use the API"})
          |> halt()
      end
    else
      _ ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
