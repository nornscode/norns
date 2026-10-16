defmodule Norns.Repo.Migrations.CreateRunWebhooks do
  use Ecto.Migration

  def change do
    create table(:run_webhooks) do
      add :tenant_id, references(:tenants), null: false
      add :url, :string, null: false
      add :secret, :string, null: false

      add :events, {:array, :string},
        null: false,
        default: ["run.waiting", "run.completed", "run.failed"]

      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:run_webhooks, [:tenant_id])
  end
end
