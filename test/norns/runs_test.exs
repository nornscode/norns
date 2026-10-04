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
end
