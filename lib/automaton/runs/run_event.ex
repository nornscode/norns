defmodule Automaton.Runs.RunEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "run_events" do
    field :sequence, :integer
    field :event_type, :string
    field :payload, :map, default: %{}
    field :source, :string, default: "system"
    field :metadata, :map, default: %{}

    belongs_to :tenant, Automaton.Tenants.Tenant
    belongs_to :run, Automaton.Runs.Run

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:tenant_id, :run_id, :sequence, :event_type, :payload, :source, :metadata])
    |> validate_required([:tenant_id, :run_id, :sequence, :event_type, :source])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:run_id, :sequence])
  end
end
