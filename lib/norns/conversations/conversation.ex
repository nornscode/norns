defmodule Norns.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Norns.Types.JsonList

  schema "conversations" do
    field :key, :string
    field :messages, JsonList, default: []
    field :summary, :string
    # The name a user gave this session, if they gave it one. Distinct from
    # `summary`, which compaction writes.
    field :title, :string
    field :message_count, :integer, default: 0
    field :token_estimate, :integer, default: 0
    # Set when the session is put away: out of the list, history intact.
    field :archived_at, :utc_datetime_usec

    belongs_to :agent, Norns.Agents.Agent
    belongs_to :tenant, Norns.Tenants.Tenant
    has_many :runs, Norns.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :agent_id,
      :tenant_id,
      :key,
      :messages,
      :summary,
      :title,
      :message_count,
      :token_estimate,
      :archived_at
    ])
    |> validate_required([:agent_id, :tenant_id, :key])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:agent_id, :key])
  end
end
