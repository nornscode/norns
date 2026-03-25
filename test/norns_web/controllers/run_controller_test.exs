defmodule NornsWeb.RunControllerTest do
  use NornsWeb.ConnCase, async: false

  setup %{conn: conn} do
    tenant = create_tenant()
    agent = create_agent(tenant)
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant, agent: agent}
  end

  describe "GET /api/v1/runs/:id" do
    test "shows a run", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"msg" => "hi"},
          status: "completed",
          output: "hello"
        })

      conn = get(conn, "/api/v1/runs/#{run.id}")
      assert %{"data" => %{"id" => id, "status" => "completed"}} = json_response(conn, 200)
      assert id == run.id
    end

    test "returns 404 for non-existent run", %{conn: conn} do
      conn = get(conn, "/api/v1/runs/999999")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/runs/:id/events" do
    test "returns event log", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{},
          status: "running"
        })

      Norns.Runs.append_event(run, %{event_type: "run_started", source: "system"})

      Norns.Runs.append_event(run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => 1, "message_count" => 1}
      })

      conn = get(conn, "/api/v1/runs/#{run.id}/events")
      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 2
      assert Enum.map(events, & &1["event_type"]) == ["run_started", "llm_request"]
    end
  end
end
