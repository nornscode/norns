defmodule Norns.Tenants.ApiKey do
  @moduledoc """
  A bearer token that can do one narrow thing.

  A tenant's keys in `tenants.api_keys` all carry the tenant's full power. A
  worker running inside a gard needs a key to join, and a command the agent
  runs on that machine as the worker's user can read it from
  `/proc/<pid>/environ`, so whatever that key can do, the agent can do. A
  scoped key bounds it: `scope` says what the key is for, and everything
  else answers 403.

  The one scope today is `worker`: `%{"kind" => "worker", "gard_id" => id,
  "capabilities" => [...]}`. Such a key may open the worker socket, claim
  only that gard (the claim token is still required), declare capabilities
  no wider than listed, serve tasks and deliver results. Reading it from
  inside the gard gains an attacker the ability to serve tools into a gard
  they are already in.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(worker)
  @capabilities ~w(llm tools)

  schema "api_keys" do
    field :name, :string
    field :token, :string
    field :scope, :map

    belongs_to :tenant, Norns.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:tenant_id, :name, :scope])
    |> validate_required([:tenant_id, :name, :scope])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_scope()
    |> put_token()
    |> unique_constraint([:tenant_id, :name], message: "a key with this name already exists")
    |> unique_constraint(:token)
  end

  @doc "The gard a worker-scoped key is bound to."
  def gard_id(%__MODULE__{scope: %{"gard_id" => gard_id}}), do: gard_id
  def gard_id(_key), do: nil

  @doc "The capabilities a worker-scoped key may declare, as atoms."
  def capabilities(%__MODULE__{scope: %{"capabilities" => caps}}) do
    Enum.map(caps, &String.to_existing_atom/1)
  end

  def capabilities(_key), do: []

  defp validate_scope(changeset) do
    case get_change(changeset, :scope) do
      nil ->
        changeset

      scope when is_map(scope) ->
        scope = normalize_scope(scope)

        cond do
          scope["kind"] not in @kinds ->
            add_error(changeset, :scope, "kind must be one of: #{Enum.join(@kinds, ", ")}")

          not is_integer(scope["gard_id"]) ->
            add_error(changeset, :scope, "gard_id is required")

          not (is_list(scope["capabilities"]) and scope["capabilities"] != [] and
                   Enum.all?(scope["capabilities"], &(&1 in @capabilities))) ->
            add_error(changeset, :scope, "capabilities must be a non-empty list from: #{Enum.join(@capabilities, ", ")}")

          true ->
            put_change(changeset, :scope, Map.take(scope, ["kind", "gard_id", "capabilities"]))
        end

      _other ->
        add_error(changeset, :scope, "must be a map")
    end
  end

  # Accept atom or string keys and a gard id given as a string, the way a
  # JSON client or an Elixir caller would each naturally send them.
  defp normalize_scope(scope) do
    scope = Map.new(scope, fn {k, v} -> {to_string(k), v} end)

    gard_id =
      case scope["gard_id"] do
        id when is_integer(id) -> id
        id when is_binary(id) -> with {parsed, ""} <- Integer.parse(id), do: parsed
        other -> other
      end

    capabilities =
      case scope["capabilities"] do
        caps when is_list(caps) -> caps |> Enum.map(&to_string/1) |> Enum.uniq()
        other -> other
      end

    scope
    |> Map.put("gard_id", gard_id)
    |> Map.put("capabilities", capabilities)
  end

  # Tokens are generated server-side, never supplied. The prefix tells an
  # operator at a glance that a token in a log or an env file is a scoped
  # worker key and not a tenant key.
  defp put_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, "nrnw_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)))
      _ -> changeset
    end
  end
end
