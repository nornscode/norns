defmodule Norns.TelemetryEvents do
  @moduledoc """
  Records anonymous telemetry events (e.g. first-run pings from nornsctl).
  """

  alias Norns.Repo

  def record(source, version) do
    Repo.insert_all("telemetry_events", [
      %{
        source: source || "unknown",
        version: version || "unknown",
        inserted_at: DateTime.utc_now()
      }
    ])
  end
end
