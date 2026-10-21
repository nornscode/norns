defmodule Norns.TenantsTest do
  use Norns.DataCase, async: true

  alias Norns.{Gards, Tenants}
  alias Norns.Tenants.ApiKey

  test "create_tenant/1 with valid attrs" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Acme", slug: "acme", api_keys: %{"anthropic" => "sk-123"}})
    assert tenant.name == "Acme"
    assert tenant.slug == "acme"
    assert tenant.api_keys["anthropic"] == "sk-123"
  end

  test "create_tenant/1 enforces unique slug" do
    {:ok, _} = Tenants.create_tenant(%{name: "A", slug: "dup"})
    {:error, changeset} = Tenants.create_tenant(%{name: "B", slug: "dup"})
    assert {"has already been taken", _} = changeset.errors[:slug]
  end

  test "ensure_default_tenant/0 creates and returns idempotently" do
    {:ok, t1} = Tenants.ensure_default_tenant()
    {:ok, t2} = Tenants.ensure_default_tenant()
    assert t1.id == t2.id
    assert t1.slug == "default"
  end

  describe "scoped keys" do
    setup do
      tenant = create_tenant()
      {:ok, gard} = Gards.create_gard(%{tenant_id: tenant.id, name: "box"})
      %{tenant: tenant, gard: gard}
    end

    defp worker_scope(gard, caps \\ ["tools"]) do
      %{"kind" => "worker", "gard_id" => gard.id, "capabilities" => caps}
    end

    test "a worker key is issued with a server-made token and a normalised scope", %{tenant: tenant, gard: gard} do
      {:ok, key} =
        Tenants.create_api_key(tenant.id, %{
          name: "box-worker",
          scope: %{kind: "worker", gard_id: to_string(gard.id), capabilities: [:tools, "tools"]}
        })

      assert "nrnw_" <> _ = key.token
      assert key.scope == %{"kind" => "worker", "gard_id" => gard.id, "capabilities" => ["tools"]}
      assert ApiKey.gard_id(key) == gard.id
      assert ApiKey.capabilities(key) == [:tools]
    end

    test "the scope must name a kind, a live gard of this tenant, and known capabilities", %{tenant: tenant, gard: gard} do
      {:error, cs} = Tenants.create_api_key(tenant.id, %{name: "k", scope: %{"kind" => "admin", "gard_id" => gard.id, "capabilities" => ["tools"]}})
      assert %{scope: [msg]} = errors_on(cs)
      assert msg =~ "kind"

      {:error, cs} = Tenants.create_api_key(tenant.id, %{name: "k", scope: %{"kind" => "worker", "capabilities" => ["tools"]}})
      assert %{scope: ["gard_id is required"]} = errors_on(cs)

      {:error, cs} = Tenants.create_api_key(tenant.id, %{name: "k", scope: Map.put(worker_scope(gard), "capabilities", ["shell"])})
      assert %{scope: [msg]} = errors_on(cs)
      assert msg =~ "capabilities"

      {:error, cs} = Tenants.create_api_key(tenant.id, %{name: "k", scope: worker_scope(gard, [])})
      assert %{scope: [_]} = errors_on(cs)

      {:error, cs} = Tenants.create_api_key(tenant.id, %{name: "k", scope: Map.put(worker_scope(gard), "gard_id", gard.id + 100_000)})
      assert %{scope: ["gard not found"]} = errors_on(cs)

      other = create_tenant()
      {:error, cs} = Tenants.create_api_key(other.id, %{name: "k", scope: worker_scope(gard)})
      assert %{scope: ["gard not found"]} = errors_on(cs)

      :ok = Gards.destroy(tenant.id, gard.id)
      {:error, cs} = Tenants.create_api_key(tenant.id, %{name: "k", scope: worker_scope(gard)})
      assert %{scope: ["gard is destroyed"]} = errors_on(cs)
    end

    test "names are unique per tenant", %{tenant: tenant, gard: gard} do
      {:ok, _} = Tenants.create_api_key(tenant.id, %{name: "k", scope: worker_scope(gard)})
      {:error, cs} = Tenants.create_api_key(tenant.id, %{name: "k", scope: worker_scope(gard)})
      assert %{tenant_id: [_]} = errors_on(cs)
    end

    test "authenticate/1 tells a tenant key from a scoped one; the tenant lookup knows only tenant keys", %{tenant: tenant, gard: gard} do
      {:ok, key} = Tenants.create_api_key(tenant.id, %{name: "k", scope: worker_scope(gard)})
      [tenant_token] = Map.values(tenant.api_keys)

      assert {:ok, %{id: tid}, nil} = Tenants.authenticate(tenant_token)
      assert tid == tenant.id

      assert {:ok, %{id: ^tid}, %ApiKey{id: key_id}} = Tenants.authenticate(key.token)
      assert key_id == key.id

      assert :error = Tenants.authenticate("nrnw_nope")

      # The dashboard session and the agent socket resolve through this, so a
      # scoped key opens neither without them knowing scoped keys exist.
      assert :error = Tenants.get_tenant_by_api_key(key.token)
    end

    test "revoking a key drops it, tells its connections, and is a 404 the second time", %{tenant: tenant, gard: gard} do
      {:ok, key} = Tenants.create_api_key(tenant.id, %{name: "k", scope: worker_scope(gard)})
      Phoenix.PubSub.subscribe(Norns.PubSub, Tenants.api_key_topic(key))

      assert Tenants.api_key_live?(key)
      assert :ok = Tenants.revoke_api_key(tenant.id, "k")
      assert_receive {:api_key_revoked, id}
      assert id == key.id

      refute Tenants.api_key_live?(key)
      assert :error = Tenants.authenticate(key.token)
      assert {:error, :not_found} = Tenants.revoke_api_key(tenant.id, "k")
    end

    test "destroying the gard revokes every key scoped to it and no other", %{tenant: tenant, gard: gard} do
      {:ok, other_gard} = Gards.create_gard(%{tenant_id: tenant.id, name: "other"})
      {:ok, a} = Tenants.create_api_key(tenant.id, %{name: "a", scope: worker_scope(gard)})
      {:ok, b} = Tenants.create_api_key(tenant.id, %{name: "b", scope: worker_scope(gard, ["llm"])})
      {:ok, c} = Tenants.create_api_key(tenant.id, %{name: "c", scope: worker_scope(other_gard)})
      Phoenix.PubSub.subscribe(Norns.PubSub, Tenants.api_key_topic(a))

      :ok = Gards.destroy(tenant.id, gard.id)

      assert_receive {:api_key_revoked, _}
      assert Enum.map(Tenants.list_api_keys(tenant.id), & &1.name) == ["c"]
      assert :error = Tenants.authenticate(a.token)
      assert :error = Tenants.authenticate(b.token)
      assert {:ok, _, %ApiKey{}} = Tenants.authenticate(c.token)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
