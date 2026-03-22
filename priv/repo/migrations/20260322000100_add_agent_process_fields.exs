defmodule Norns.Repo.Migrations.AddAgentProcessFields do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :tools_config, :map, default: %{}
      add :max_steps, :integer, default: 50
    end

    alter table(:runs) do
      add :resumed_from_event_id, :integer, null: true
    end
  end
end
