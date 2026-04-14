defmodule Norns.Repo.Migrations.CreateTelemetryEvents do
  use Ecto.Migration

  def change do
    create table(:telemetry_events) do
      add :source, :string, null: false
      add :version, :string
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end
