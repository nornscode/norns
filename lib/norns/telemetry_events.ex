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

  def list_events(limit \\ 100) do
    Repo.query!(
      "SELECT id, source, version, inserted_at FROM telemetry_events ORDER BY inserted_at DESC LIMIT $1",
      [limit]
    ).rows
    |> Enum.map(fn [id, source, version, inserted_at] ->
      %{id: id, source: source, version: version, inserted_at: inserted_at}
    end)
  end

  def count do
    Repo.query!("SELECT COUNT(*) FROM telemetry_events").rows |> hd() |> hd()
  end

  def count_by_source do
    Repo.query!(
      "SELECT source, COUNT(*) as count FROM telemetry_events GROUP BY source ORDER BY count DESC"
    ).rows
    |> Enum.map(fn [source, count] -> %{source: source, count: count} end)
  end
end
