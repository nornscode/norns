defmodule Automaton.TenantsTest do
  use Automaton.DataCase, async: true

  alias Automaton.Tenants

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
end
