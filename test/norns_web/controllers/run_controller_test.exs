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

    test "includes failure inspector for failed runs", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"msg" => "hi"},
          status: "failed",
          failure_metadata: %{
            "error_class" => "internal",
            "error_code" => "runtime_failure",
            "retry_decision" => "terminal"
          }
        })

      Norns.Runs.append_event(run, %{
        event_type: "checkpoint_saved",
        payload: %{"messages" => [%{role: "user", content: "hi"}], "step" => 1}
      })

      Norns.Runs.append_event(run, %{
        event_type: "run_failed",
        payload: %{
          "error" => "boom",
          "error_class" => "internal",
          "error_code" => "runtime_failure",
          "retry_decision" => "terminal"
        }
      })

      conn = get(conn, "/api/v1/runs/#{run.id}")
      assert %{"data" => %{"failure_inspector" => inspector, "failure_metadata" => metadata}} = json_response(conn, 200)
      assert Enum.sort(Map.keys(inspector)) == ["error_class", "error_code", "last_checkpoint", "last_event", "retry_decision"]
      assert inspector["error_class"] == "internal"
      assert inspector["error_code"] == "runtime_failure"
      assert inspector["retry_decision"] == "terminal"
      assert inspector["last_checkpoint"]["event_type"] == "checkpoint_saved"
      assert Enum.sort(Map.keys(inspector["last_checkpoint"])) == ["event_type", "inserted_at", "payload", "sequence"]
      assert inspector["last_event"]["event_type"] == "run_failed"
      assert Enum.sort(Map.keys(inspector["last_event"])) == ["event_type", "inserted_at", "payload", "sequence"]
      assert metadata["error_code"] == "runtime_failure"
    end

    test "returns 404 for non-existent run", %{conn: conn} do
      conn = get(conn, "/api/v1/runs/999999")
      assert json_response(conn, 404)
    end

    test "returns 404 for a run from another tenant", %{conn: conn, agent: agent} do
      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)

      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: other_agent.id,
          tenant_id: other_tenant.id,
          trigger_type: "message",
          input: %{},
          status: "completed"
        })

      conn = get(conn, "/api/v1/runs/#{run.id}")
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

  describe "authentication" do
    test "returns 401 without token" do
      conn = build_conn() |> get("/api/v1/runs/123")
      assert json_response(conn, 401)
    end

    test "returns 401 with invalid token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer invalid-token")
        |> get("/api/v1/runs/123")

      assert json_response(conn, 401)
    end
  end
end
