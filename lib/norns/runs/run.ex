defmodule Norns.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  schema "runs" do
    field :status, :string, default: "pending"
    field :trigger_type, :string
    field :input, :map, default: %{}
    field :output, :string
    field :failure_metadata, :map, default: %{}
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0

    belongs_to :tenant, Norns.Tenants.Tenant
    belongs_to :agent, Norns.Agents.Agent
    belongs_to :conversation, Norns.Conversations.Conversation
    has_many :events, Norns.Runs.RunEvent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:tenant_id, :agent_id, :conversation_id, :status, :trigger_type, :input, :output, :failure_metadata, :input_tokens, :output_tokens])
    |> validate_required([:tenant_id, :agent_id, :status, :trigger_type])
    |> validate_inclusion(:status, ["pending", "running", "waiting", "completed", "failed"])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:tenant_id)
  end
end
