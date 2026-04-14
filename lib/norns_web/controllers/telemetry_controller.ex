defmodule NornsWeb.TelemetryController do
  use NornsWeb, :controller

  def first_run(conn, params) do
    Norns.TelemetryEvents.record(params["source"], params["version"])
    json(conn, %{status: "recorded"})
  end
end
