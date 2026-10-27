defmodule NornsWeb.SignOutController do
  @moduledoc "Ends the dashboard browser session."

  use NornsWeb, :controller

  def create(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end
end
