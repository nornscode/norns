defmodule Norns.Tenants.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :api_keys, :map, default: %{}

    has_many :agents, Norns.Agents.Agent
    has_many :runs, Norns.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :slug, :api_keys])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
