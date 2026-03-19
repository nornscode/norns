defmodule Automaton.Tenants do
  @moduledoc "Tenant CRUD."

  alias Automaton.Repo
  alias Automaton.Tenants.Tenant

  def get_tenant!(id), do: Repo.get!(Tenant, id)

  def get_tenant_by_slug(slug), do: Repo.get_by(Tenant, slug: slug)

  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Find or create the default tenant, using ANTHROPIC_API_KEY from config."
  def ensure_default_tenant do
    case get_tenant_by_slug("default") do
      %Tenant{} = t ->
        {:ok, t}

      nil ->
        api_key = Application.get_env(:automaton, :default_anthropic_api_key) || ""

        create_tenant(%{
          name: "Default",
          slug: "default",
          api_keys: %{"anthropic" => api_key}
        })
    end
  end
end
