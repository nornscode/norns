defmodule Norns.Runs.IntrospectionTest do
  use Norns.DataCase, async: true

  alias Norns.Runs
  alias Norns.Runs.Introspection

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant, %{name: "watched-agent"})
    %{tenant: tenant, agent: agent}
  end

  defp run(tenant, agent, attrs) do
    {:ok, run} =
      Runs.create_run(
        Map.merge(%{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "message", status: "running"}, attrs)
      )

    run
  end

  describe "list_runs/2" do
    test "lists the tenant's runs with agent, task and outcome", %{tenant: tenant, agent: agent} do
      run(tenant, agent, %{status: "completed", input: %{"user_message" => "sum the numbers"}, output: "42"})
      run(tenant, agent, %{status: "failed", failure_metadata: %{"error" => "worker gone"}})

      {:ok, runs} = Introspection.list_runs(tenant.id, %{})

      assert length(runs) == 2
      completed = Enum.find(runs, &(&1["status"] == "completed"))
      assert completed["agent"] == "watched-agent"
      assert completed["task"] == "sum the numbers"
      assert completed["output"] == "42"

      failed = Enum.find(runs, &(&1["status"] == "failed"))
      assert failed["output"] == "error: worker gone"
    end

    test "filters by agent name and status", %{tenant: tenant, agent: agent} do
      other = create_agent(tenant, %{name: "other-agent"})
      run(tenant, agent, %{status: "completed"})
      run(tenant, other, %{status: "completed"})
      run(tenant, other, %{status: "running"})

      {:ok, runs} = Introspection.list_runs(tenant.id, %{"agent_name" => "other-agent", "status" => "completed"})

      assert [%{"agent" => "other-agent", "status" => "completed"}] = runs
    end

    test "shows the question a waiting run is parked on", %{tenant: tenant, agent: agent} do
      waiting = run(tenant, agent, %{status: "waiting"})

      {:ok, _} =
        Runs.append_event(waiting, %{
          event_type: "waiting_for_user",
          payload: %{"question" => "ship it?", "tool_call_id" => "c1", "step" => 1}
        })

      {:ok, [entry]} = Introspection.list_runs(tenant.id, %{"status" => "waiting"})
      assert entry["pending_question"] == "ship it?"
    end

    test "does not see other tenants", %{tenant: tenant} do
      other_tenant = create_tenant()
      run(other_tenant, create_agent(other_tenant), %{})

      assert {:ok, []} = Introspection.list_runs(tenant.id, %{})
    end

    test "truncates long tasks", %{tenant: tenant, agent: agent} do
      run(tenant, agent, %{input: %{"user_message" => String.duplicate("a", 500)}})

      {:ok, [entry]} = Introspection.list_runs(tenant.id, %{})
      assert entry["task"] =~ "(truncated)"
      assert String.length(entry["task"]) < 250
    end

    test "rejects an unknown agent or status", %{tenant: tenant} do
      assert {:error, "unknown_agent"} = Introspection.list_runs(tenant.id, %{"agent_name" => "nobody"})
      assert {:error, "invalid_status"} = Introspection.list_runs(tenant.id, %{"status" => "exploded"})
    end
  end

  describe "inspect_run/2" do
    test "returns the trace summary with task and outcome", %{tenant: tenant, agent: agent} do
      r = run(tenant, agent, %{status: "completed", input: %{"user_message" => "do the thing"}, output: "done"})

      {:ok, summary} = Introspection.inspect_run(tenant.id, r.id)

      assert summary.run_id == r.id
      assert summary.verdict == "completed"
      assert summary.task == "do the thing"
      assert summary.output == "done"
      assert summary.pending_question == nil
    end

    test "accepts a string id", %{tenant: tenant, agent: agent} do
      r = run(tenant, agent, %{})
      assert {:ok, %{run_id: id}} = Introspection.inspect_run(tenant.id, to_string(r.id))
      assert id == r.id
    end

    test "reports another tenant's run as not found", %{tenant: tenant} do
      other_tenant = create_tenant()
      foreign = run(other_tenant, create_agent(other_tenant), %{})

      assert {:error, "run_not_found"} = Introspection.inspect_run(tenant.id, foreign.id)
      assert {:error, "run_not_found"} = Introspection.inspect_run(tenant.id, -1)
      assert {:error, "run_not_found"} = Introspection.inspect_run(tenant.id, "abc")
    end
  end
end
