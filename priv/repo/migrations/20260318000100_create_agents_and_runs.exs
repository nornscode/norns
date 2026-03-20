defmodule Norns.Repo.Migrations.CreateAgentsAndRuns do
  use Ecto.Migration

  def change do
    create table(:agents) do
      add :name, :string, null: false
      add :purpose, :text
      add :status, :string, null: false, default: "inactive"
      add :current_agent_version, :integer, null: false, default: 1
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:name])
    create index(:agents, [:status])

    create table(:runs) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :trigger_type, :string, null: false
      add :input, :map, null: false, default: %{}
      add :state, :map, null: false, default: %{}
      add :agent_version, :integer, null: false
      add :policy_version, :integer
      add :prompt_bundle_version, :integer
      add :model_config_version, :string
      add :tooling_config_version, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:agent_id])
    create index(:runs, [:status])
    create index(:runs, [:inserted_at])
  end
end
