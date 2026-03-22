defmodule Norns.Agents.ProcessTest do
  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake
  alias Norns.Runs
  alias Norns.Tools.WebSearch

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)

    %{tenant: tenant, agent: agent}
  end

  describe "simple end_turn flow" do
    test "processes a message and completes", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{
          content: [%{"type" => "text", "text" => "Hello! I can help with that."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      AgentProcess.send_message(pid, "Hello agent")

      # Give the GenServer time to process
      Process.sleep(100)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle
      assert state.step == 1

      # Verify run was created and completed
      assert state.run_id != nil
      run = Runs.get_run!(state.run_id)
      assert run.status == "completed"
      assert run.output == "Hello! I can help with that."

      # Verify events were logged
      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "agent_started" in event_types
      assert "llm_request" in event_types
      assert "llm_response" in event_types
      assert "agent_completed" in event_types
    end
  end

  describe "tool use flow" do
    test "executes tool calls and continues LLM loop", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        # First response: tool call
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_1",
              "name" => "web_search",
              "input" => %{"query" => "elixir programming"}
            }
          ],
          stop_reason: "tool_use"
        },
        # Second response: final answer
        %{
          content: [%{"type" => "text", "text" => "Based on my search, Elixir is great!"}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          tools: [WebSearch.tool()]
        )

      AgentProcess.send_message(pid, "Tell me about Elixir")
      Process.sleep(200)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle
      assert state.step == 2

      run = Runs.get_run!(state.run_id)
      assert run.status == "completed"

      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "tool_call" in event_types
      assert "tool_result" in event_types

      # Should have 2 llm_request events (one per loop iteration)
      assert Enum.count(event_types, &(&1 == "llm_request")) == 2
    end
  end

  describe "max steps" do
    test "stops when max_steps exceeded", %{tenant: tenant, agent: agent} do
      # Always return tool_use to force infinite loop
      responses =
        for i <- 1..5 do
          %{
            content: [
              %{
                "type" => "tool_use",
                "id" => "call_#{i}",
                "name" => "web_search",
                "input" => %{"query" => "query #{i}"}
              }
            ],
            stop_reason: "tool_use"
          }
        end

      Fake.set_responses(responses)

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          tools: [WebSearch.tool()],
          max_steps: 3
        )

      AgentProcess.send_message(pid, "Loop forever")
      Process.sleep(300)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      assert run.status == "failed"

      events = Runs.list_events(run.id)
      error_event = Enum.find(events, &(&1.event_type == "agent_error"))
      assert error_event.payload["error"] =~ "Max steps"
    end
  end

  describe "PubSub broadcasting" do
    test "broadcasts events during execution", %{tenant: tenant, agent: agent} do
      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

      Fake.set_responses([
        %{
          content: [%{"type" => "text", "text" => "Done!"}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      AgentProcess.send_message(pid, "Hi")
      Process.sleep(100)

      assert_received {:agent_started, %{agent_id: _}}
      assert_received {:llm_response, %{agent_id: _, stop_reason: "end_turn"}}
      assert_received {:completed, %{agent_id: _, output: "Done!"}}
    end
  end
end
