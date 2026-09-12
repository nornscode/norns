defmodule Norns.Repo.Migrations.AddArchivedAtToAgents do
  use Ecto.Migration

  @moduledoc """
  Agents archive rather than delete: their runs are an event log, and the log
  must outlive the definition that produced it.

  The name uniqueness index becomes partial, so archiving `smoke-test` frees
  the name for the next one. An archived agent keeps its row, its runs, and
  its conversations.
  """

  def change do
    alter table(:agents) do
      add :archived_at, :utc_datetime_usec
    end

    drop unique_index(:agents, [:tenant_id, :name])
    create unique_index(:agents, [:tenant_id, :name], where: "archived_at IS NULL", name: :agents_tenant_id_name_index)

    create index(:agents, [:tenant_id, :archived_at])
  end
end
