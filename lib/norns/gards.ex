defmodule Norns.Gards do
  @moduledoc """
  Gard registry: CRUD, worker claims, and port registration.

  Concurrency invariants (see `docs/gards.md` § Concurrency Invariants):
  `claim/3` is an atomic conditional UPDATE — of N simultaneous claimants
  exactly one wins; `mark_disconnected/2` is idempotent because both the
  unregister and DOWN paths can fire on the same disconnect; gards are
  soft-deleted only, keeping the runs FK valid.
  """

  import Ecto.Query

  alias Norns.Repo
  alias Norns.Gards.{Gard, GardPort}

  # -- CRUD --

  def list_gards(tenant_id) do
    Repo.all(from g in Gard, where: g.tenant_id == ^tenant_id, order_by: g.id)
  end

  def get_gard(tenant_id, id) when is_integer(id) do
    Repo.get_by(Gard, id: id, tenant_id: tenant_id)
  end

  def get_gard(tenant_id, id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> get_gard(tenant_id, parsed)
      _ -> nil
    end
  end

  def get_gard(_tenant_id, _id), do: nil

  def create_gard(attrs) do
    %Gard{}
    |> Gard.changeset(attrs)
    |> Repo.insert()
  end

  def update_gard(%Gard{} = gard, attrs) do
    gard
    |> Gard.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Soft-destroy a gard: status → `destroyed`, ports removed, and the worker
  currently claiming it kicked (which fails its in-flight tasks through the
  existing disconnect path). Refuses if the gard has an active run unless
  `force: true`.
  """
  def destroy(tenant_id, gard_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if not force and has_active_run?(gard_id) do
      {:error, :active_run}
    else
      query =
        from g in Gard,
          where: g.id == ^gard_id and g.tenant_id == ^tenant_id and g.status != "destroyed"

      case Repo.update_all(query, set: [status: "destroyed", updated_at: DateTime.utc_now()]) do
        {1, _} ->
          Repo.delete_all(from p in GardPort, where: p.gard_id == ^gard_id)
          Norns.Workers.WorkerRegistry.kick_gard_workers(tenant_id, gard_id)
          :ok

        {0, _} ->
          {:error, :not_found}
      end
    end
  end

  defp has_active_run?(gard_id) do
    Repo.exists?(
      from r in Norns.Runs.Run,
        where: r.gard_id == ^gard_id and r.status in ["pending", "running", "waiting"]
    )
  end

  # -- Worker claims --

  @doc """
  Claim a gard for a connecting worker.

  Atomic conditional update — prevents the TOCTOU race when two workers
  connect simultaneously: only one wins, the other gets a classified error.
  Claimable from `pending` (first connect) and `disconnected` (reconnect).
  """
  def claim(tenant_id, gard_id, claim_token) when is_binary(claim_token) do
    query =
      from g in Gard,
        where:
          g.id == ^gard_id and g.tenant_id == ^tenant_id and
            g.claim_token == ^claim_token and
            g.status in ["pending", "disconnected"]

    case Repo.update_all(query, set: [status: "ready", updated_at: DateTime.utc_now()]) do
      {1, _} -> :ok
      {0, _} -> classify_claim_failure(tenant_id, gard_id, claim_token)
    end
  end

  def claim(_tenant_id, _gard_id, _claim_token), do: {:error, :invalid_claim_token}

  defp classify_claim_failure(tenant_id, gard_id, claim_token) do
    case Repo.get_by(Gard, id: gard_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      %{status: "destroyed"} -> {:error, :gard_destroyed}
      %{status: "ready"} -> {:error, :already_claimed}
      %{claim_token: ^claim_token} -> {:error, :already_claimed}
      _ -> {:error, :invalid_claim_token}
    end
  end

  @doc """
  Mark a gard's worker as gone. Idempotent — both the unregister and DOWN
  paths can fire on the same disconnect; only `ready` transitions, so a
  second call (or a call after destroy) writes nothing.
  """
  def mark_disconnected(tenant_id, gard_id) do
    query =
      from g in Gard,
        where: g.id == ^gard_id and g.tenant_id == ^tenant_id and g.status == "ready"

    Repo.update_all(query, set: [status: "disconnected", updated_at: DateTime.utc_now()])
    :ok
  end

  # -- Ports --

  def list_ports(gard_id) do
    Repo.all(from p in GardPort, where: p.gard_id == ^gard_id, order_by: p.internal_port)
  end

  def register_port(gard_id, attrs) do
    %GardPort{}
    |> GardPort.changeset(Map.put(attrs, "gard_id", gard_id))
    |> Repo.insert()
  end
end
