defmodule Norns.Repo.Migrations.CreateServerlessWorkers do
  use Ecto.Migration

  def change do
    create table(:serverless_workers) do
      add :tenant_id, references(:tenants), null: false
      add :worker_id, :string, null: false
      add :wake_url, :string, null: false
      add :secret, :string, null: false
      add :tools, {:array, :map}, null: false, default: []
      add :capabilities, {:array, :string}, null: false, default: ["tools"]
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:serverless_workers, [:tenant_id, :worker_id])
    create index(:serverless_workers, [:tenant_id])
  end
end
