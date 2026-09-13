defmodule NornsWeb.TriggerControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.TestWorker.LLM

  setup %{conn: conn} do
    tenant = create_tenant()
    agent = create_agent(tenant)
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant, agent: agent}
  end

  defp valid_params(agent, attrs \\ %{}) do
    Map.merge(
      %{
        "agent_id" => agent.id,
        "name" => "trigger-#{System.unique_integer([:positive])}",
        "cron" => "0 9 * * 5",
        "message" => "post the weekly report"
      },
      attrs
    )
  end

  describe "POST /api/v1/triggers" do
    test "creates a trigger", %{conn: conn, agent: agent} do
      conn = post(conn, "/api/v1/triggers", valid_params(agent, %{"name" => "friday-report"}))

      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "friday-report"
      assert data["cron"] == "0 9 * * 5"
      assert data["enabled"] == true
      assert data["agent_id"] == agent.id
    end

    test "rejects an invalid cron expression", %{conn: conn, agent: agent} do
      conn = post(conn, "/api/v1/triggers", valid_params(agent, %{"cron" => "whenever"}))
      assert %{"error" => %{"cron" => _}} = json_response(conn, 422)
    end

    test "rejects missing fields", %{conn: conn, agent: agent} do
      conn = post(conn, "/api/v1/triggers", %{"agent_id" => agent.id})
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/triggers" do
    test "lists tenant triggers, optionally filtered by agent", %{conn: conn, tenant: tenant, agent: agent} do
      other_agent = create_agent(tenant)
      post(conn, "/api/v1/triggers", valid_params(agent))
      post(conn, "/api/v1/triggers", valid_params(other_agent))

      assert %{"data" => all} = json_response(get(conn, "/api/v1/triggers"), 200)
      assert length(all) == 2

      assert %{"data" => [only]} =
               json_response(get(conn, "/api/v1/triggers?agent_id=#{agent.id}"), 200)

      assert only["agent_id"] == agent.id
    end

    test "does not leak another tenant's triggers", %{conn: conn} do
      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)

      {:ok, other_trigger} =
        Norns.Triggers.create_trigger(%{
          tenant_id: other_tenant.id,
          agent_id: other_agent.id,
          name: "theirs",
          cron: "@daily",
          message: "hi"
        })

      assert %{"data" => []} = json_response(get(conn, "/api/v1/triggers"), 200)
      assert json_response(get(conn, "/api/v1/triggers/#{other_trigger.id}"), 404)
    end
  end

  describe "PATCH /api/v1/triggers/:id" do
    test "updates and can disable a trigger", %{conn: conn, agent: agent} do
      %{"data" => %{"id" => id}} =
        json_response(post(conn, "/api/v1/triggers", valid_params(agent)), 201)

      conn = patch(conn, "/api/v1/triggers/#{id}", %{"enabled" => false, "cron" => "@hourly"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["enabled"] == false
      assert data["cron"] == "@hourly"
    end
  end

  describe "DELETE /api/v1/triggers/:id" do
    test "deletes a trigger", %{conn: conn, agent: agent} do
      %{"data" => %{"id" => id}} =
        json_response(post(conn, "/api/v1/triggers", valid_params(agent)), 201)

      assert response(delete(conn, "/api/v1/triggers/#{id}"), 204)
      assert json_response(get(conn, "/api/v1/triggers/#{id}"), 404)
    end
  end

  describe "POST /api/v1/triggers/:id/fire" do
    test "starts a run immediately", %{conn: conn, agent: agent} do
      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
      ])

      %{"data" => %{"id" => id}} =
        json_response(post(conn, "/api/v1/triggers", valid_params(agent)), 201)

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      conn = post(conn, "/api/v1/triggers/#{id}/fire")

      assert %{"status" => "accepted", "run_id" => run_id} = json_response(conn, 202)

      receive do
        {:completed, _} -> :ok
      after
        5000 -> flunk("run did not complete")
      end

      run = Norns.Runs.get_run!(run_id)
      assert run.trigger_type == "schedule"
    end
  end
end
