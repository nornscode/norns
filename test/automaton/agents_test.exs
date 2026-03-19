defmodule Automaton.AgentsTest do
  use Automaton.DataCase, async: true

  alias Automaton.Agents

  test "create_agent/1 and get_agent_by_name/2" do
    tenant = create_tenant()

    {:ok, agent} =
      Agents.create_agent(%{
        tenant_id: tenant.id,
        name: "my-agent",
        system_prompt: "You help.",
        status: "idle"
      })

    assert agent.name == "my-agent"
    assert agent.system_prompt == "You help."
    assert Agents.get_agent_by_name(tenant.id, "my-agent").id == agent.id
    assert Agents.get_agent_by_name(tenant.id, "nonexistent") == nil
  end

  test "agent name is unique per tenant" do
    tenant = create_tenant()

    {:ok, _} =
      Agents.create_agent(%{tenant_id: tenant.id, name: "dup", system_prompt: "a", status: "idle"})

    {:error, changeset} =
      Agents.create_agent(%{tenant_id: tenant.id, name: "dup", system_prompt: "b", status: "idle"})

    assert {"has already been taken", _} = changeset.errors[:tenant_id_name] || changeset.errors[:tenant_id]

    # But a different tenant can use the same name
    tenant2 = create_tenant()

    {:ok, agent2} =
      Agents.create_agent(%{tenant_id: tenant2.id, name: "dup", system_prompt: "c", status: "idle"})

    assert agent2.name == "dup"
  end
end
