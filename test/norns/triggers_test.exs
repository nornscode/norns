defmodule Norns.TriggersTest do
  use Norns.DataCase, async: false

  alias Norns.{Runs, Triggers}
  alias Norns.TestWorker.LLM

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    %{tenant: tenant, agent: agent}
  end

  defp trigger_attrs(tenant, agent, attrs \\ %{}) do
    Map.merge(
      %{
        tenant_id: tenant.id,
        agent_id: agent.id,
        name: "trigger-#{System.unique_integer([:positive])}",
        cron: "* * * * *",
        message: "do the thing"
      },
      attrs
    )
  end

  defp minute(datetime \\ DateTime.utc_now()) do
    %{datetime | second: 0, microsecond: {0, 6}}
  end

  defp await_run_completion(agent_id) do
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent_id}")

    receive do
      {:completed, _} -> :ok
      {:error, _} -> :ok
    after
      5000 -> flunk("run did not finish")
    end
  end

  describe "create_trigger/1" do
    test "creates with a valid cron expression", %{tenant: tenant, agent: agent} do
      assert {:ok, trigger} = Triggers.create_trigger(trigger_attrs(tenant, agent, %{cron: "0 9 * * 5"}))
      assert trigger.enabled == true
      assert trigger.last_fired_at == nil
    end

    test "accepts cron aliases", %{tenant: tenant, agent: agent} do
      assert {:ok, _} = Triggers.create_trigger(trigger_attrs(tenant, agent, %{cron: "@daily"}))
    end

    test "rejects an invalid cron expression", %{tenant: tenant, agent: agent} do
      for bad <- ["not cron", "* * *", "99 * * * *"] do
        assert {:error, changeset} = Triggers.create_trigger(trigger_attrs(tenant, agent, %{cron: bad}))
        assert Keyword.has_key?(changeset.errors, :cron)
      end
    end

    test "names are unique per tenant", %{tenant: tenant, agent: agent} do
      attrs = trigger_attrs(tenant, agent, %{name: "friday-report"})
      assert {:ok, _} = Triggers.create_trigger(attrs)
      assert {:error, changeset} = Triggers.create_trigger(attrs)
      assert Keyword.has_key?(changeset.errors, :tenant_id) or match?([_ | _], changeset.errors)
    end
  end

  describe "listing and lookup" do
    test "list and get are tenant-scoped", %{tenant: tenant, agent: agent} do
      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)

      {:ok, mine} = Triggers.create_trigger(trigger_attrs(tenant, agent))
      {:ok, theirs} = Triggers.create_trigger(trigger_attrs(other_tenant, other_agent))

      assert Enum.map(Triggers.list_triggers(tenant.id), & &1.id) == [mine.id]
      assert Triggers.get_trigger(tenant.id, theirs.id) == nil
    end
  end

  describe "fire_due/1" do
    test "fires a due trigger and stamps the run as schedule-triggered", %{tenant: tenant, agent: agent} do
      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "posted"}], stop_reason: "end_turn"}
      ])

      {:ok, trigger} = Triggers.create_trigger(trigger_attrs(tenant, agent, %{message: "post the report"}))

      now = minute()
      assert {1, 0} = Triggers.fire_due(now)
      await_run_completion(agent.id)

      [run] = Runs.list_runs(agent.id)
      assert run.trigger_type == "schedule"
      assert run.input["user_message"] == "post the report"

      assert Triggers.get_trigger(tenant.id, trigger.id).last_fired_at == now
    end

    test "a trigger fires at most once per minute", %{tenant: tenant, agent: agent} do
      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "posted"}], stop_reason: "end_turn"}
      ])

      {:ok, _} = Triggers.create_trigger(trigger_attrs(tenant, agent))

      now = minute()
      assert {1, 0} = Triggers.fire_due(now)
      await_run_completion(agent.id)
      assert {0, 0} = Triggers.fire_due(now)

      assert length(Runs.list_runs(agent.id)) == 1
    end

    test "fires again in a later minute", %{tenant: tenant, agent: agent} do
      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "one"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "two"}], stop_reason: "end_turn"}
      ])

      {:ok, _} = Triggers.create_trigger(trigger_attrs(tenant, agent))

      now = minute()
      assert {1, 0} = Triggers.fire_due(now)
      await_run_completion(agent.id)

      assert {1, 0} = Triggers.fire_due(DateTime.add(now, 60, :second))
      await_run_completion(agent.id)

      assert length(Runs.list_runs(agent.id)) == 2
    end

    test "skips disabled and non-matching triggers", %{tenant: tenant, agent: agent} do
      {:ok, _} = Triggers.create_trigger(trigger_attrs(tenant, agent, %{enabled: false}))

      # 9am Friday only — fire_due at a known non-matching minute
      {:ok, _} = Triggers.create_trigger(trigger_attrs(tenant, agent, %{cron: "0 9 * * 5"}))
      not_friday = %{DateTime.new!(~D[2026-08-10], ~T[10:30:00], "Etc/UTC") | microsecond: {0, 6}}

      assert {0, 0} = Triggers.fire_due(not_friday)
      assert Runs.list_runs(agent.id) == []
    end
  end

  describe "fire/1" do
    test "manual fire does not consume the scheduled minute", %{tenant: tenant, agent: agent} do
      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "one"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "two"}], stop_reason: "end_turn"}
      ])

      {:ok, trigger} = Triggers.create_trigger(trigger_attrs(tenant, agent))

      assert {:ok, _run_id} = Triggers.fire(trigger)
      await_run_completion(agent.id)
      assert Triggers.get_trigger(tenant.id, trigger.id).last_fired_at == nil

      assert {1, 0} = Triggers.fire_due(minute())
      await_run_completion(agent.id)

      assert length(Runs.list_runs(agent.id)) == 2
    end

    test "a persistent conversation_key keeps history across firings", %{tenant: tenant, agent: agent} do
      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "one"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "two"}], stop_reason: "end_turn"}
      ])

      {:ok, trigger} =
        Triggers.create_trigger(trigger_attrs(tenant, agent, %{conversation_key: "report-thread"}))

      {:ok, _} = Triggers.fire(trigger)
      await_run_completion(agent.id)
      {:ok, _} = Triggers.fire(trigger)
      await_run_completion(agent.id)

      [_first, second] = LLM.calls()
      # Second firing sees the first firing's history: user, assistant, user
      assert length(second.messages) == 3
    end
  end
end
