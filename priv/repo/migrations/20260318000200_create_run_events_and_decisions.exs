defmodule Norns.Repo.Migrations.CreateRunEventsAndDecisions do
  use Ecto.Migration

  def change do
    create table(:run_events) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :sequence, :integer, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :source, :string, null: false, default: "system"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:run_events, [:run_id, :sequence])
    create index(:run_events, [:run_id, :inserted_at])
    create index(:run_events, [:event_type])

    create table(:run_decisions) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :run_event_id, references(:run_events, on_delete: :nilify_all)
      add :decision_point, :string, null: false
      add :decision, :string, null: false
      add :reason_codes, {:array, :string}, null: false, default: []
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:run_decisions, [:run_id, :inserted_at])
    create index(:run_decisions, [:decision_point])
    create index(:run_decisions, [:decision])
  end
end
