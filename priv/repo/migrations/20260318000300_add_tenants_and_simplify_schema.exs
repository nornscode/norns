defmodule Norns.Repo.Migrations.AddTenantsAndSimplifySchema do
  use Ecto.Migration

  def change do
    # --- Tenants ---
    create table(:tenants) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :api_keys, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:slug])

    # --- Agents: add tenant_id, system_prompt, model fields; drop premature columns ---
    alter table(:agents) do
      add :tenant_id, references(:tenants, on_delete: :delete_all)
      add :system_prompt, :text
      add :model, :string, null: false, default: "claude-sonnet-4-20250514"
      add :model_config, :map, null: false, default: %{}
      remove :current_agent_version, :integer, default: 1
      remove :metadata, :map, default: %{}
    end

    drop unique_index(:agents, [:name])
    create unique_index(:agents, [:tenant_id, :name])
    create index(:agents, [:tenant_id])

    # Backfill will be needed before setting NOT NULL — handled by seed/mix task.
    # For a fresh DB this is fine; for existing data you'd do a two-step migration.
    execute "ALTER TABLE agents ALTER COLUMN tenant_id SET NOT NULL",
            "ALTER TABLE agents ALTER COLUMN tenant_id DROP NOT NULL"

    # --- Runs: add tenant_id, output; drop version-pinning columns ---
    alter table(:runs) do
      add :tenant_id, references(:tenants, on_delete: :delete_all)
      add :output, :text
      remove :agent_version, :integer
      remove :policy_version, :integer
      remove :prompt_bundle_version, :integer
      remove :model_config_version, :string
      remove :tooling_config_version, :string
    end

    create index(:runs, [:tenant_id])

    execute "ALTER TABLE runs ALTER COLUMN tenant_id SET NOT NULL",
            "ALTER TABLE runs ALTER COLUMN tenant_id DROP NOT NULL"

    # --- Run Events: add tenant_id ---
    alter table(:run_events) do
      add :tenant_id, references(:tenants, on_delete: :delete_all)
    end

    create index(:run_events, [:tenant_id])

    execute "ALTER TABLE run_events ALTER COLUMN tenant_id SET NOT NULL",
            "ALTER TABLE run_events ALTER COLUMN tenant_id DROP NOT NULL"

    # --- Drop run_decisions ---
    drop table(:run_decisions)
  end
end
