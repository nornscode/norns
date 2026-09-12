defmodule Norns.Repo.Migrations.AddTitleToConversations do
  use Ecto.Migration

  @moduledoc """
  A name the user gave a session.

  Clients title a session from its first message, which is a good guess and
  sometimes a bad one — "test" is not what that session turned out to be
  about. The name belongs here rather than in a client's own file so it is
  the same name in every window on every machine.

  It is not `summary`: that is compaction's, written by a model.
  """

  def change do
    alter table(:conversations) do
      add :title, :string
    end
  end
end
