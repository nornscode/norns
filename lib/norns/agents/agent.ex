defmodule Norns.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "agents" do
    field :name, :string
    field :purpose, :string
    field :status, :string, default: "inactive"
    field :system_prompt, :string
    field :model, :string, default: "claude-sonnet-5"
    field :model_config, :map, default: %{}
    field :tools_config, :map, default: %{}
    field :max_steps, :integer, default: 50
    # Set when the agent is retired. The row stays: its runs are the log.
    field :archived_at, :utc_datetime_usec

    belongs_to :tenant, Norns.Tenants.Tenant
    has_many :runs, Norns.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :purpose, :status, :system_prompt, :model, :model_config, :tools_config, :max_steps, :tenant_id, :archived_at])
    |> validate_required([:name, :status, :system_prompt, :tenant_id])
    |> validate_inclusion(:status, ["inactive", "idle", "running"])
    |> unique_constraint([:tenant_id, :name])
    |> foreign_key_constraint(:tenant_id)
  end
end
