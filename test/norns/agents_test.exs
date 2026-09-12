defmodule Norns.AgentsTest do
  use Norns.DataCase, async: true

  alias Norns.Agents

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

  describe "archive/3" do
    test "hides the agent and frees its name, keeping the row" do
      tenant = create_tenant()
      agent = create_agent(tenant, %{name: "smoke"})

      assert :ok = Agents.archive(tenant.id, agent.id)

      assert Agents.list_agents(tenant.id) == []
      assert Agents.get_agent_by_name(tenant.id, "smoke") == nil

      # By id it is still there — a run page has to name the agent that made it.
      assert Agents.get_agent!(agent.id).archived_at

      {:ok, reused} = Agents.create_agent(%{tenant_id: tenant.id, name: "smoke", system_prompt: "a", status: "idle"})
      assert reused.id != agent.id
    end

    test "refuses while a run is pending, running, or waiting" do
      tenant = create_tenant()

      for status <- ["pending", "running", "waiting"] do
        agent = create_agent(tenant)
        {:ok, _} = Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: status})

        assert {:error, :active_run} = Agents.archive(tenant.id, agent.id)
        assert :ok = Agents.archive(tenant.id, agent.id, force: true)
      end
    end

    test "a finished run does not hold an agent open" do
      tenant = create_tenant()
      agent = create_agent(tenant)
      {:ok, _} = Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed"})

      assert :ok = Agents.archive(tenant.id, agent.id)
    end

    test "archiving twice, or across tenants, is not found" do
      tenant = create_tenant()
      agent = create_agent(tenant)

      assert {:error, :not_found} = Agents.archive(create_tenant().id, agent.id)
      assert :ok = Agents.archive(tenant.id, agent.id)
      assert {:error, :not_found} = Agents.archive(tenant.id, agent.id)
    end
  end
end
