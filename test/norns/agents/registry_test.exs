defmodule Norns.Agents.RegistryTest do
  use Norns.DataCase, async: false

  alias Norns.Agents.Registry
  alias Norns.LLM.Fake

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)

    Fake.set_responses([
      %{content: [%{"type" => "text", "text" => "ok"}], stop_reason: "end_turn"}
    ])

    %{tenant: tenant, agent: agent}
  end

  describe "start_agent/3" do
    test "starts a process under DynamicSupervisor", %{tenant: tenant, agent: agent} do
      assert {:ok, pid} = Registry.start_agent(agent.id, tenant.id)
      assert Process.alive?(pid)
    end

    test "prevents duplicate processes for same agent", %{tenant: tenant, agent: agent} do
      {:ok, _pid} = Registry.start_agent(agent.id, tenant.id)
      assert {:error, {:already_started, _}} = Registry.start_agent(agent.id, tenant.id)
    end

    test "allows separate processes per conversation key", %{tenant: tenant, agent: agent} do
      assert {:ok, pid1} = Registry.start_agent(agent.id, tenant.id, conversation_key: "conv-1")
      assert {:ok, pid2} = Registry.start_agent(agent.id, tenant.id, conversation_key: "conv-2")
      assert pid1 != pid2
    end
  end

  describe "lookup/2" do
    test "finds running process", %{tenant: tenant, agent: agent} do
      {:ok, pid} = Registry.start_agent(agent.id, tenant.id)
      assert {:ok, ^pid} = Registry.lookup(tenant.id, agent.id)
    end

    test "returns error for unknown agent", %{tenant: tenant} do
      assert :error = Registry.lookup(tenant.id, -1)
    end
  end

  describe "send_message/4" do
    test "delivers message and starts the agent if needed", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "hi back"}], stop_reason: "end_turn"}
      ])

      assert {:ok, run_id} = Registry.send_message(tenant.id, agent.id, "hello")
      assert is_integer(run_id)
    end
  end

  describe "stop_agent/2" do
    test "stops a running process", %{tenant: tenant, agent: agent} do
      {:ok, pid} = Registry.start_agent(agent.id, tenant.id)
      assert :ok = Registry.stop_agent(tenant.id, agent.id)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for unknown agent", %{tenant: tenant} do
      assert {:error, :not_found} = Registry.stop_agent(tenant.id, -1)
    end
  end

  describe "stop_all/2" do
    test "stops every conversation of one agent and leaves the others", %{tenant: tenant, agent: agent} do
      {:ok, one} = Registry.start_agent(agent.id, tenant.id, conversation_key: "one")
      {:ok, two} = Registry.start_agent(agent.id, tenant.id, conversation_key: "two")

      bystander = create_agent(tenant)
      {:ok, other} = Registry.start_agent(bystander.id, tenant.id)

      assert Registry.stop_all(tenant.id, agent.id) == 2
      Process.sleep(50)

      refute Process.alive?(one)
      refute Process.alive?(two)
      assert Process.alive?(other)
    end

    test "an agent with nothing running stops nothing", %{tenant: tenant, agent: agent} do
      assert Registry.stop_all(tenant.id, agent.id) == 0
    end
  end

  describe "alive?/2" do
    test "returns true for running agent", %{tenant: tenant, agent: agent} do
      {:ok, _pid} = Registry.start_agent(agent.id, tenant.id)
      assert Registry.alive?(tenant.id, agent.id)
    end

    test "returns false for stopped agent", %{tenant: tenant, agent: agent} do
      refute Registry.alive?(tenant.id, agent.id)
    end
  end
end
