defmodule Norns.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  schema "runs" do
    field :status, :string, default: "pending"
    field :trigger_type, :string
    field :input, :map, default: %{}
    field :state, :map, default: %{}
    field :output, :string
    field :resumed_from_event_id, :integer

    belongs_to :tenant, Norns.Tenants.Tenant
    belongs_to :agent, Norns.Agents.Agent
    has_many :events, Norns.Runs.RunEvent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:tenant_id, :agent_id, :status, :trigger_type, :input, :state, :output, :resumed_from_event_id])
    |> validate_required([:tenant_id, :agent_id, :status, :trigger_type])
    |> validate_inclusion(:status, ["pending", "running", "completed", "failed"])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:tenant_id)
  end
end
