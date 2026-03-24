defmodule Norns.Repo.Migrations.AddConversationsAndMemories do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :messages, :map, null: false, default: fragment("'[]'::jsonb")
      add :summary, :text
      add :message_count, :integer, null: false, default: 0
      add :token_estimate, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversations, [:agent_id, :key])
    create index(:conversations, [:tenant_id])

    create table(:memories) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :content, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memories, [:agent_id, :key])
    create index(:memories, [:tenant_id])

    alter table(:runs) do
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
    end

    create index(:runs, [:conversation_id])
  end
end
