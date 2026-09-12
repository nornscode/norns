defmodule NornsWeb.SessionControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.{Conversations, Runs}

  setup %{conn: conn} do
    tenant = create_tenant()
    agent = create_agent(tenant, %{name: "sleipnir"})
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant, agent: agent}
  end

  test "lists every conversation with its agent, latest run, and live state", %{conn: conn, tenant: tenant, agent: agent} do
    {:ok, older} = Conversations.find_or_create_conversation(agent.id, tenant.id, "older")
    {:ok, older} = Conversations.update_conversation(older, %{messages: [%{"role" => "user", "content" => "fix the tests"}], message_count: 1})

    {:ok, _run1} = Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, conversation_id: older.id, trigger_type: "message", input: %{}, status: "completed"})
    {:ok, run2} = Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, conversation_id: older.id, trigger_type: "message", input: %{}, status: "waiting"})
    {:ok, _} = Runs.append_event(run2, %{event_type: "waiting_for_user", source: "system", payload: %{"question" => "Allow bash `rm`?", "tool_call_id" => "c1", "step" => 1}})

    {:ok, newer} = Conversations.find_or_create_conversation(agent.id, tenant.id, "newer")

    other_tenant = create_tenant()
    other_agent = create_agent(other_tenant)
    {:ok, _} = Conversations.find_or_create_conversation(other_agent.id, other_tenant.id, "elsewhere")

    assert %{"data" => [first, second]} = json_response(get(conn, "/api/v1/sessions"), 200)

    assert first["id"] == newer.id
    assert first["run"] == nil
    assert first["status"] == "stopped"
    assert first["agent_name"] == "sleipnir"

    assert second["id"] == older.id
    assert second["first_message"] == "fix the tests"
    assert second["run"]["id"] == run2.id
    assert second["run"]["status"] == "waiting"
    assert second["run"]["waiting_for"]["question"] == "Allow bash `rm`?"
    refute Map.has_key?(second, "messages")

    assert %{"data" => [_]} = json_response(get(conn, "/api/v1/sessions?limit=1"), 200)
  end

  test "shows one session with its messages, and hides other tenants", %{conn: conn, tenant: tenant, agent: agent} do
    {:ok, c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "one")
    {:ok, c} = Conversations.update_conversation(c, %{messages: [%{"role" => "user", "content" => "hi"}, %{"role" => "assistant", "content" => "hello"}]})

    assert %{"data" => %{"id" => id, "messages" => messages}} = json_response(get(conn, "/api/v1/sessions/#{c.id}"), 200)
    assert id == c.id
    assert [%{"role" => "user"}, %{"role" => "assistant", "content" => "hello"}] = messages

    other_tenant = create_tenant()
    other_agent = create_agent(other_tenant)
    {:ok, foreign} = Conversations.find_or_create_conversation(other_agent.id, other_tenant.id, "x")
    assert json_response(get(conn, "/api/v1/sessions/#{foreign.id}"), 404)
    assert json_response(get(conn, "/api/v1/sessions/nope"), 404)
  end

  test "shows how each run of the session ended", %{conn: conn, tenant: tenant, agent: agent} do
    {:ok, c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "boundaries")
    {:ok, done} = Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, conversation_id: c.id, trigger_type: "message", input: %{}, status: "completed"})
    {:ok, broke} = Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, conversation_id: c.id, trigger_type: "message", input: %{}, status: "failed"})

    {:ok, _} = Conversations.update_conversation(c, %{messages: [
      %{"role" => "user", "content" => "hi", "run_id" => done.id},
      %{"role" => "assistant", "content" => "hello", "run_id" => done.id},
      %{"role" => "user", "content" => "again", "run_id" => broke.id}
    ]})

    assert %{"data" => %{"runs" => runs, "messages" => messages}} =
             json_response(get(conn, "/api/v1/sessions/#{c.id}"), 200)

    # The envelope a client needs to draw run boundaries it did not watch.
    assert runs == [%{"id" => done.id, "status" => "completed"}, %{"id" => broke.id, "status" => "failed"}]
    assert Enum.map(messages, & &1["run_id"]) == [done.id, done.id, broke.id]
  end

  test "an archived agent's sessions leave the list but keep their history", %{conn: conn, tenant: tenant, agent: agent} do
    {:ok, c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "leftover")
    {:ok, _} = Conversations.update_conversation(c, %{messages: [%{"role" => "user", "content" => "hi"}]})

    assert %{"data" => [_]} = json_response(get(conn, "/api/v1/sessions"), 200)

    assert response(delete(conn, "/api/v1/agents/#{agent.id}"), 204)

    # Cleared from the sidebar — that is what archiving an agent is for.
    assert %{"data" => []} = json_response(get(conn, "/api/v1/sessions"), 200)

    # But still readable by id: the transcript was not the thing retired.
    assert %{"data" => %{"messages" => [%{"content" => "hi"}]}} =
             json_response(get(conn, "/api/v1/sessions/#{c.id}"), 200)
  end

  test "a session can be given a name, and have it taken away", %{conn: conn, tenant: tenant, agent: agent} do
    {:ok, c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "vague")
    {:ok, _} = Conversations.update_conversation(c, %{messages: [%{"role" => "user", "content" => "test"}]})

    # The guess from the first turn is all a client has to start with.
    assert %{"data" => %{"title" => nil, "first_message" => "test"}} =
             json_response(get(conn, "/api/v1/sessions/#{c.id}"), 200)

    assert %{"data" => %{"title" => "Swift migration"}} =
             json_response(patch(conn, "/api/v1/sessions/#{c.id}", %{"title" => "  Swift migration  "}), 200)

    # The name is on the session itself, so every client sees the same one.
    assert %{"data" => [%{"title" => "Swift migration"}]} = json_response(get(conn, "/api/v1/sessions"), 200)

    # Blank clears it and the guess comes back.
    assert %{"data" => %{"title" => nil}} =
             json_response(patch(conn, "/api/v1/sessions/#{c.id}", %{"title" => "   "}), 200)

    other = create_tenant()
    other_agent = create_agent(other)
    {:ok, theirs} = Conversations.find_or_create_conversation(other_agent.id, other.id, "theirs")
    assert json_response(patch(conn, "/api/v1/sessions/#{theirs.id}", %{"title" => "mine now"}), 404)
    assert json_response(patch(conn, "/api/v1/sessions/nope", %{"title" => "x"}), 404)
  end

  describe "archiving a session" do
    test "takes it out of the list and brings it back, history intact", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "done-with")
      {:ok, c} = Conversations.update_conversation(c, %{messages: [%{"role" => "user", "content" => "ship it"}]})
      {:ok, _} = Conversations.find_or_create_conversation(agent.id, tenant.id, "still-going")

      assert response(delete(conn, "/api/v1/sessions/#{c.id}"), 204)

      # Gone from the list a client draws on every start.
      assert %{"data" => [remaining]} = json_response(get(conn, "/api/v1/sessions"), 200)
      assert remaining["key"] == "still-going"

      # But listed in the archive, and still fully readable by id.
      assert %{"data" => [archived]} = json_response(get(conn, "/api/v1/sessions?archived=true"), 200)
      assert archived["id"] == c.id
      assert archived["archived_at"]
      assert %{"data" => %{"messages" => [%{"content" => "ship it"}]}} = json_response(get(conn, "/api/v1/sessions/#{c.id}"), 200)

      assert %{"data" => %{"archived_at" => nil}} = json_response(post(conn, "/api/v1/sessions/#{c.id}/restore"), 200)
      assert %{"data" => sessions} = json_response(get(conn, "/api/v1/sessions"), 200)
      assert length(sessions) == 2
      assert %{"data" => []} = json_response(get(conn, "/api/v1/sessions?archived=true"), 200)
    end

    test "refuses a session with a run in flight, unless forced", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "busy")
      {:ok, _} = Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, conversation_id: c.id, trigger_type: "message", input: %{}, status: "waiting"})

      assert %{"error" => error} = json_response(delete(conn, "/api/v1/sessions/#{c.id}"), 409)
      assert error =~ "active run"

      assert response(delete(conn, "/api/v1/sessions/#{c.id}?force=true"), 204)
    end

    test "will not archive or restore another tenant's session", %{conn: conn} do
      other = create_tenant()
      agent = create_agent(other)
      {:ok, c} = Conversations.find_or_create_conversation(agent.id, other.id, "theirs")

      assert json_response(delete(conn, "/api/v1/sessions/#{c.id}"), 404)
      assert json_response(post(conn, "/api/v1/sessions/#{c.id}/restore"), 404)
      assert json_response(delete(conn, "/api/v1/sessions/nope"), 404)
    end

    test "an archived session does not keep a process running", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, _pid} = Norns.Agents.Registry.start_conversation(agent.id, tenant.id, "parked")
      {:ok, c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "parked")
      assert {:ok, pid} = Norns.Agents.Registry.lookup(tenant.id, agent.id, "parked")

      assert response(delete(conn, "/api/v1/sessions/#{c.id}"), 204)
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  test "reports the live state of a running process", %{conn: conn, tenant: tenant, agent: agent} do
    {:ok, _pid} = Norns.Agents.Registry.start_conversation(agent.id, tenant.id, "live")
    {:ok, _c} = Conversations.find_or_create_conversation(agent.id, tenant.id, "live")
    assert %{"data" => [%{"key" => "live", "status" => "idle"}]} = json_response(get(conn, "/api/v1/sessions"), 200)
  end
end
