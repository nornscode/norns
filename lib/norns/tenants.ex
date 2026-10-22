defmodule Norns.Tenants do
  @moduledoc "Tenant CRUD and API keys."

  import Ecto.Query

  alias Norns.Repo
  alias Norns.Tenants.{ApiKey, Tenant}

  def get_tenant!(id), do: Repo.get!(Tenant, id)

  def get_tenant_by_slug(slug), do: Repo.get_by(Tenant, slug: slug)

  def list_tenants, do: Repo.all(Tenant)

  @doc """
  Find the tenant whose api_keys map contains the given token as a value.

  Full-power keys only. A scoped key (`ApiKey`) is not a tenant credential
  and does not resolve here, so every caller of this function — the
  dashboard session, the agent socket — turns one away without knowing
  scoped keys exist. `authenticate/1` is the lookup that accepts both.
  """
  def get_tenant_by_api_key(token) when is_binary(token) do
    case Enum.find(list_tenants(), fn t -> token in Map.values(t.api_keys) end) do
      %Tenant{} = t -> {:ok, t}
      nil -> :error
    end
  end

  @doc """
  Resolve a bearer token to its tenant and its scope.

  `{:ok, tenant, nil}` is a full-power key; `{:ok, tenant, %ApiKey{}}` is
  a scoped one, and the caller decides what that scope permits.
  """
  def authenticate(token) when is_binary(token) do
    case get_tenant_by_api_key(token) do
      {:ok, tenant} ->
        {:ok, tenant, nil}

      :error ->
        case Repo.one(from k in ApiKey, where: k.token == ^token, preload: :tenant) do
          %ApiKey{tenant: tenant} = key -> {:ok, tenant, key}
          nil -> :error
        end
    end
  end

  def authenticate(_token), do: :error

  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Generate a random API key."
  def generate_api_key do
    "nrn_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
  end

  @doc "Find or create the default tenant."
  def ensure_default_tenant do
    case get_tenant_by_slug("default") do
      %Tenant{} = t ->
        {:ok, t}

      nil ->
        create_tenant(%{name: "Default", slug: "default", api_keys: %{}})
    end
  end

  # -- Scoped keys --

  @doc """
  Issue a scoped key. The token is on the returned struct and nowhere
  else afterwards; list and show never include it.

  A worker scope must name a gard of this tenant that is not destroyed:
  a key for a gard that cannot be claimed could never be used.
  """
  def create_api_key(tenant_id, attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("tenant_id", tenant_id)
    changeset = ApiKey.changeset(%ApiKey{}, attrs)

    with %{valid?: true} <- changeset,
         :ok <- check_scope_target(tenant_id, Ecto.Changeset.get_change(changeset, :scope)) do
      Repo.insert(changeset)
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, message} -> {:error, Ecto.Changeset.add_error(changeset, :scope, message)}
    end
  end

  defp check_scope_target(tenant_id, %{"kind" => "worker", "gard_id" => gard_id}) do
    case Norns.Gards.get_gard(tenant_id, gard_id) do
      nil -> {:error, "gard not found"}
      %{status: "destroyed"} -> {:error, "gard is destroyed"}
      _gard -> :ok
    end
  end

  def list_api_keys(tenant_id) do
    Repo.all(from k in ApiKey, where: k.tenant_id == ^tenant_id, order_by: k.id)
  end

  def get_api_key(tenant_id, name) when is_binary(name) do
    Repo.get_by(ApiKey, tenant_id: tenant_id, name: name)
  end

  @doc "Whether a scoped key is still issued. A revoked key's open connections check this before doing anything further."
  def api_key_live?(%ApiKey{id: id}), do: Repo.exists?(from k in ApiKey, where: k.id == ^id)

  @doc """
  Revoke a scoped key by name. A worker connected on it is told and its
  channel closes (`NornsWeb.WorkerChannel`), which fails its in-flight
  tasks through the ordinary disconnect path.
  """
  def revoke_api_key(tenant_id, name) do
    case get_api_key(tenant_id, name) do
      nil ->
        {:error, :not_found}

      key ->
        {:ok, _} = Repo.delete(key)
        broadcast_revoked(key)
        :ok
    end
  end

  @doc "Revoke every key scoped to a gard. Part of destroying the gard: a key for a gard that no longer exists is a key for nothing."
  def revoke_gard_keys(tenant_id, gard_id) do
    keys =
      Repo.all(
        from k in ApiKey,
          where: k.tenant_id == ^tenant_id and fragment("(?->>'gard_id')::bigint = ?", k.scope, ^gard_id)
      )

    Enum.each(keys, fn key ->
      Repo.delete(key)
      broadcast_revoked(key)
    end)

    :ok
  end

  @doc "The PubSub topic a connection authenticated with `key` listens on for its revocation."
  def api_key_topic(%ApiKey{id: id}), do: "api_key:#{id}"

  defp broadcast_revoked(key) do
    Phoenix.PubSub.broadcast(Norns.PubSub, api_key_topic(key), {:api_key_revoked, key.id})
  end
end
