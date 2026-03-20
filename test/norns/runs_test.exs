defmodule Norns.RunsTest do
  use Norns.DataCase, async: true

  alias Norns.Runs

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

    {:ok, e1} = Runs.append_event(run, %{event_type: "run_started"})
    {:ok, e2} = Runs.append_event(run, %{event_type: "llm_response", payload: %{"text" => "hi"}})

    assert e1.sequence == 1
    assert e2.sequence == 2

    events = Runs.list_events(run.id)
    assert length(events) == 2
    assert Enum.map(events, & &1.event_type) == ["run_started", "llm_response"]
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
end
