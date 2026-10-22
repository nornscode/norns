defmodule Norns.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  # Scoped keys. The tenant's full-power keys stay in `tenants.api_keys`;
  # a row here is a key that can do one narrow thing (today: join the
  # worker socket for one gard) and nothing else.
  def change do
    create table(:api_keys) do
      add :tenant_id, references(:tenants), null: false
      add :name, :string, null: false
      add :token, :string, null: false
      add :scope, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:token])
    create unique_index(:api_keys, [:tenant_id, :name])
  end
end
