defmodule Automaton.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "agents" do
    field :name, :string
    field :purpose, :string
    field :status, :string, default: "inactive"
    field :system_prompt, :string
    field :model, :string, default: "claude-sonnet-4-20250514"
    field :model_config, :map, default: %{}

    belongs_to :tenant, Automaton.Tenants.Tenant
    has_many :runs, Automaton.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :purpose, :status, :system_prompt, :model, :model_config, :tenant_id])
    |> validate_required([:name, :status, :system_prompt, :tenant_id])
    |> validate_inclusion(:status, ["inactive", "idle", "running"])
    |> unique_constraint([:tenant_id, :name])
    |> foreign_key_constraint(:tenant_id)
  end
end
