defmodule Norns.Tenants do
  @moduledoc "Tenant CRUD."

  alias Norns.Repo
  alias Norns.Tenants.Tenant

  def get_tenant!(id), do: Repo.get!(Tenant, id)

  def get_tenant_by_slug(slug), do: Repo.get_by(Tenant, slug: slug)

  def list_tenants, do: Repo.all(Tenant)

  @doc "Find the tenant whose api_keys map contains the given token as a value."
  def get_tenant_by_api_key(token) when is_binary(token) do
    case Enum.find(list_tenants(), fn t -> token in Map.values(t.api_keys) end) do
      %Tenant{} = t -> {:ok, t}
      nil -> :error
    end
  end

  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Generate a random API key."
  def generate_api_key do
    "nrn_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
  end

  @doc "Find or create the default tenant, using ANTHROPIC_API_KEY from config."
  def ensure_default_tenant do
    case get_tenant_by_slug("default") do
      %Tenant{} = t ->
        {:ok, t}

      nil ->
        api_key = Application.get_env(:norns, :default_anthropic_api_key) || ""

        create_tenant(%{
          name: "Default",
          slug: "default",
          api_keys: %{"anthropic" => api_key}
        })
    end
  end
end
