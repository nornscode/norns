defmodule Norns.Repo.Migrations.AddArchivedAtToConversations do
  use Ecto.Migration

  @moduledoc """
  A session you are done with, without deleting it.

  Between closing a tab (which comes back next time) and deleting the
  conversation (which is gone) there was nothing. Archiving is the middle:
  it leaves the session list and does not return on restart, and every
  message, run, and event stays exactly where it was.
  """

  def change do
    alter table(:conversations) do
      add :archived_at, :utc_datetime_usec
    end

    create index(:conversations, [:tenant_id, :archived_at])
  end
end
