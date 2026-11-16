defmodule Norns.Repo.Migrations.AddTenantIndexesToRuns do
  use Ecto.Migration

  # The runs screen lists a tenant's runs newest first, optionally narrowed
  # by status. The single-column indexes on tenant_id and inserted_at can't
  # serve both the filter and the order at once.
  def change do
    create index(:runs, [:tenant_id, :inserted_at])
    create index(:runs, [:tenant_id, :status, :inserted_at])
  end
end
