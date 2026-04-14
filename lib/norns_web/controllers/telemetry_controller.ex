defmodule NornsWeb.TelemetryController do
  use NornsWeb, :controller

  require Logger

  def first_run(conn, params) do
    Logger.info("first-run ping received",
      source: params["source"] || "unknown",
      version: params["version"] || "unknown"
    )

    json(conn, %{status: "recorded"})
  end
end
