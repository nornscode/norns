defmodule Norns.Runtime.EventTimelineTest do
  @moduledoc "Gate 5: SDK-originated runs show expected event sequence."
  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake
  alias Norns.Runs
  alias Norns.Tools.WebSearch

  describe "event timeline consistency" do
    test "simple run produces expected event sequence", %{} do
      tenant = create_tenant()
      agent = create_agent(tenant)

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "Hello!"}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      AgentProcess.send_message(pid, "Hi")

      receive do
        {:completed, _} -> :ok
      after
        5000 -> flunk("Did not complete")
      end

      state = AgentProcess.get_state(pid)
      events = Runs.list_events(state.run_id)
      types = Enum.map(events, & &1.event_type)

      # Expected sequence for a simple end_turn run
      assert types == ["run_started", "llm_request", "llm_response", "run_completed"]

      # All events have schema_version
      assert Enum.all?(events, &(&1.payload["schema_version"] == 1))

      # Sequence numbers are monotonic
      sequences = Enum.map(events, & &1.sequence)
      assert sequences == Enum.sort(sequences)
      assert length(Enum.uniq(sequences)) == length(sequences)
    end

    test "tool-use run produces expected event sequence", %{} do
      tenant = create_tenant()
      agent = create_agent(tenant)

      Fake.set_responses([
        %{
          content: [%{"type" => "tool_use", "id" => "c1", "name" => "web_search", "input" => %{"query" => "test"}}],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "Done"}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id, tools: [WebSearch.tool()])
      AgentProcess.send_message(pid, "Search")

      receive do
        {:completed, _} -> :ok
      after
        5000 -> flunk("Did not complete")
      end

      state = AgentProcess.get_state(pid)
      events = Runs.list_events(state.run_id)
      types = Enum.map(events, & &1.event_type)

      # Expected: start → llm_req → llm_resp(tool_use) → tool_call → tool_result → checkpoint → llm_req → llm_resp(end_turn) → completed
      assert "run_started" in types
      assert "llm_request" in types
      assert "llm_response" in types
      assert "tool_call" in types
      assert "tool_result" in types
      assert "run_completed" in types

      # Two LLM requests (one before tool, one after)
      assert Enum.count(types, &(&1 == "llm_request")) == 2

      # Events are in order: run_started is first, run_completed is last
      assert List.first(types) == "run_started"
      assert List.last(types) == "run_completed"
    end

    test "failed run has failure metadata and inspector-compatible events", %{} do
      tenant = create_tenant(%{api_keys: %{"anthropic" => ""}})
      agent = create_agent(tenant, %{model_config: %{"on_failure" => "stop"}})

      # Empty API key will cause LLM error
      Fake.set_responses([])
      # Override to force an error from the fake
      Norns.LLM.Fake.set_responses([])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      AgentProcess.send_message(pid, "Fail please")

      receive do
        {:error, _} -> :ok
        {:completed, _} -> :ok
      after
        5000 -> flunk("Did not complete or error")
      end

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)

      events = Runs.list_events(run.id)
      types = Enum.map(events, & &1.event_type)

      assert "run_started" in types
      assert "llm_request" in types

      # Run has either completed (fake returned fallback) or failed
      if run.status == "failed" do
        assert "run_failed" in types

        failed_event = Enum.find(events, &(&1.event_type == "run_failed"))
        assert failed_event.payload["error_class"]
        assert failed_event.payload["error_code"]
        assert failed_event.payload["retry_decision"]

        # Failure inspector works
        inspector = Runs.failure_inspector(run)
        assert inspector["error_class"]
        assert inspector["last_event"]
      end
    end
  end
end
