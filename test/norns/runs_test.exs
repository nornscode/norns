defmodule Norns.RunsTest do
  use Norns.DataCase, async: true

  alias Norns.Runs
  alias Norns.Runtime.Events

  test "create_run/1 and append_event/2 with sequencing" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Runs.create_run(%{
        tenant_id: tenant.id,
        agent_id: agent.id,
        trigger_type: "external",
        status: "pending"
      })

    assert run.status == "pending"

    {:ok, e1} = Runs.append_event(run, elem(Events.run_started(), 1))

    {:ok, e2} =
      Runs.append_event(
        run,
        elem(
          Events.llm_response(%{
            "content" => "hi",
            "finish_reason" => "stop",
            "usage" => %{},
            "step" => 1
          }),
          1
        )
      )

    assert e1.sequence == 1
    assert e2.sequence == 2

    events = Runs.list_events(run.id)
    assert length(events) == 2
    assert Enum.map(events, & &1.event_type) == ["run_started", "llm_response"]
    assert Enum.all?(events, &(&1.payload["schema_version"] == 1))
  end

  test "update_run/2 transitions status" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Runs.create_run(%{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "external"})

    {:ok, run} = Runs.update_run(run, %{status: "running"})
    assert run.status == "running"

    {:ok, run} = Runs.update_run(run, %{status: "completed", output: "done"})
    assert run.status == "completed"
    assert run.output == "done"
  end

  test "rejects invalid typed payloads" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Runs.create_run(%{
        tenant_id: tenant.id,
        agent_id: agent.id,
        trigger_type: "external",
        status: "pending"
      })

    assert {:error, %{payload: "step must be an integer"}} =
             Runs.append_event(run, %{
               event_type: "llm_request",
               payload: %{"step" => "bad", "message_count" => 1}
             })
  end

  test "builds failure inspector from run metadata and events" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Runs.create_run(%{
        tenant_id: tenant.id,
        agent_id: agent.id,
        trigger_type: "external",
        status: "failed",
        failure_metadata: %{
          "error_class" => "internal",
          "error_code" => "runtime_failure",
          "retry_decision" => "terminal"
        }
      })

    Runs.append_event(run, %{event_type: "run_started"})

    Runs.append_event(run, %{
      event_type: "checkpoint_saved",
      payload: %{"messages" => [%{role: "user", content: "hi"}], "step" => 1}
    })

    Runs.append_event(run, %{
      event_type: "run_failed",
      payload: %{
        "error" => "boom",
        "error_class" => "internal",
        "error_code" => "runtime_failure",
        "retry_decision" => "terminal"
      }
    })

    inspector = Runs.failure_inspector(run)
    assert inspector["error_class"] == "internal"
    assert inspector["error_code"] == "runtime_failure"
    assert inspector["retry_decision"] == "terminal"
    assert inspector["last_checkpoint"]["event_type"] == "checkpoint_saved"
    assert inspector["last_checkpoint"]["sequence"] == 2
    assert inspector["last_event"]["event_type"] == "run_failed"
    assert inspector["last_event"]["sequence"] == 3
  end

  describe "lineage" do
    setup do
      tenant = create_tenant()
      agent = create_agent(tenant)

      parent = run!(tenant, agent, %{status: "running"})
      first = run!(tenant, agent, %{status: "completed", parent_run_id: parent.id, depth: 1})
      second = run!(tenant, agent, %{status: "waiting", parent_run_id: parent.id, depth: 1})
      _unrelated = run!(tenant, agent, %{status: "running"})

      %{parent: parent, first: first, second: second}
    end

    test "child_runs/1 returns only this run's children, oldest first", ctx do
      assert Enum.map(Runs.child_runs(ctx.parent.id), & &1.id) == [ctx.first.id, ctx.second.id]
      assert Runs.child_runs(ctx.first.id) == []
    end

    test "live_children?/1 counts a parked child as alive", ctx do
      # The case that matters: a child waiting on a human is not a worker that
      # went away, and the step timer reads this to decide whether to fail.
      assert Runs.live_children?(ctx.parent.id)
    end

    test "live_children?/1 is false once every child is terminal", ctx do
      {:ok, _} = Runs.update_run(ctx.second, %{status: "failed"})
      refute Runs.live_children?(ctx.parent.id)
    end

    test "live_children?/1 is false for a run that launched nothing", ctx do
      refute Runs.live_children?(ctx.first.id)
    end
  end

  defp run!(tenant, agent, attrs) do
    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "message"},
          attrs
        )
      )

    run
  end

  defp run_at(tenant, agent, status, seconds_ago, attrs \\ %{}) do
    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "message", status: status},
          attrs
        )
      )

    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    Repo.update_all(from(r in Norns.Runs.Run, where: r.id == ^run.id), set: [inserted_at: at])
    run
  end

  describe "page_runs_for_tenant/2" do
    test "lists runs across the tenant's agents, newest first, with agent preloaded" do
      tenant = create_tenant()
      a1 = create_agent(tenant)
      a2 = create_agent(tenant)

      old = run_at(tenant, a1, "completed", 30)
      mid = run_at(tenant, a2, "failed", 20)
      new = run_at(tenant, a1, "running", 10)

      %{runs: runs, has_next: false, page: 1} = Runs.page_runs_for_tenant(tenant.id)

      assert Enum.map(runs, & &1.id) == [new.id, mid.id, old.id]
      assert Enum.map(runs, & &1.agent.name) == [a1.name, a2.name, a1.name]
    end

    test "never returns another tenant's runs" do
      tenant = create_tenant()
      other = create_tenant()
      mine = run_at(tenant, create_agent(tenant), "running", 5)
      other_agent = create_agent(other)
      _theirs = run_at(other, other_agent, "running", 1)

      assert [%{id: id}] = Runs.page_runs_for_tenant(tenant.id).runs
      assert id == mine.id

      # Naming the other tenant's agent does not reach across.
      assert Runs.page_runs_for_tenant(tenant.id, agent_id: other_agent.id).runs == []
    end

    test "filters by one status, a list of statuses, and agent" do
      tenant = create_tenant()
      a1 = create_agent(tenant)
      a2 = create_agent(tenant)

      pending = run_at(tenant, a1, "pending", 40)
      running = run_at(tenant, a2, "running", 30)
      failed = run_at(tenant, a1, "failed", 20)
      _done = run_at(tenant, a2, "completed", 10)

      ids = fn opts -> Enum.map(Runs.page_runs_for_tenant(tenant.id, opts).runs, & &1.id) end

      assert ids.(status: "failed") == [failed.id]
      assert ids.(status: ["pending", "running"]) == [running.id, pending.id]
      assert ids.(agent_id: a1.id) == [failed.id, pending.id]
      assert ids.(agent_id: a2.id, status: "running") == [running.id]
    end

    test "pages newest first and says whether there is a next page" do
      tenant = create_tenant()
      agent = create_agent(tenant)
      runs = for s <- 5..1//-1, do: run_at(tenant, agent, "completed", s)
      [r5, r4, r3, r2, r1] = runs

      p1 = Runs.page_runs_for_tenant(tenant.id, per_page: 2)
      assert Enum.map(p1.runs, & &1.id) == [r1.id, r2.id]
      assert p1.has_next

      p3 = Runs.page_runs_for_tenant(tenant.id, per_page: 2, page: 3)
      assert Enum.map(p3.runs, & &1.id) == [r5.id]
      refute p3.has_next

      assert Enum.map(Runs.page_runs_for_tenant(tenant.id, per_page: 2, page: 2).runs, & &1.id) ==
               [r3.id, r4.id]
    end
  end
end
