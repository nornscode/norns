defmodule NornsWeb.ConversationControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.Agents.Registry, as: AgentRegistry
  alias Norns.Conversations

  setup %{conn: conn} do
    tenant = create_tenant()
    agent = create_agent(tenant)
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant, agent: agent}
  end

  describe "DELETE /api/v1/agents/:id/conversations/:key" do
    # Issue #8: the row went away and the process holding it did not. Its
    # cached conversation then pointed at a deleted row, so the next message
    # on that thread 500'd and stayed wedged until the process aged out on
    # its own. A deleted conversation should have no live process.
    test "evicts the running process for that conversation", %{conn: conn, tenant: tenant, agent: agent} do
      key = "slack:C123:thread-1"
      {:ok, _conversation} = Conversations.find_or_create_conversation(agent.id, tenant.id, key)
      {:ok, _pid} = AgentRegistry.start_conversation(agent.id, tenant.id, key)

      assert AgentRegistry.alive?(tenant.id, agent.id, key)

      conn = delete(conn, "/api/v1/agents/#{agent.id}/conversations/#{key}")
      assert json_response(conn, 200)["status"] == "deleted"

      refute AgentRegistry.alive?(tenant.id, agent.id, key)
    end

    test "a thread can be used again after its conversation is deleted", %{conn: conn, tenant: tenant, agent: agent} do
      key = "slack:C123:thread-2"
      {:ok, _conversation} = Conversations.find_or_create_conversation(agent.id, tenant.id, key)
      {:ok, _pid} = AgentRegistry.start_conversation(agent.id, tenant.id, key)

      delete(conn, "/api/v1/agents/#{agent.id}/conversations/#{key}")

      # The next message starts a fresh process and re-creates the row,
      # rather than routing into one holding a conversation that is gone.
      {:ok, _pid} = AgentRegistry.start_conversation(agent.id, tenant.id, key)
      assert AgentRegistry.alive?(tenant.id, agent.id, key)
    end

    test "deleting a conversation with no live process still deletes it", %{conn: conn, tenant: tenant, agent: agent} do
      key = "no-process"
      {:ok, _conversation} = Conversations.find_or_create_conversation(agent.id, tenant.id, key)

      conn = delete(conn, "/api/v1/agents/#{agent.id}/conversations/#{key}")

      assert json_response(conn, 200)["status"] == "deleted"
      assert Conversations.get_conversation_by_agent_key(agent.id, key) == nil
    end
  end
end
