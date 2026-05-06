defmodule Norns.Agents.ProcessSubagentTest do
  use Norns.DataCase, async: false

  alias Norns.Runs
  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)

    %{tenant: tenant, agent: agent}
  end

  defp subscribe_and_send(pid, agent_id, content) do
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent_id}")
    AgentProcess.send_message(pid, content)
  end

  defp wait_for(event, timeout \\ 5000) do
    receive do
      {^event, payload} -> payload
    after
      timeout -> flunk("Did not receive #{event} within #{timeout}ms")
    end
  end

  describe "list_agents tool" do
    test "returns available agents excluding self", %{tenant: tenant, agent: agent} do
      _other_agent = create_agent(tenant, %{name: "helper-agent", purpose: "Helps with tasks"})

      Fake.set_responses([
        # LLM calls list_agents
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_list", "name" => "list_agents", "input" => %{}}
          ],
          stop_reason: "tool_use"
        },
        # LLM completes after seeing the result
        %{
          content: [%{"type" => "text", "text" => "Found agents."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "List agents")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "tool_call" in event_types
      assert "tool_result" in event_types

      # Find the tool_result event for list_agents
      tool_result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "list_agents"))
      assert tool_result != nil

      result = Jason.decode!(tool_result.payload["content"])
      agent_names = Enum.map(result, & &1["name"])

      # Should include other agent but NOT self
      assert "helper-agent" in agent_names
      refute agent.name in agent_names
    end
  end

  describe "launch_agent tool" do
    test "launches child agent and returns its output", %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "child-agent", purpose: "Child worker"})

      Fake.set_responses([
        # Parent: calls launch_agent
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_launch",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "child-agent", "message" => "Do the thing"}
            }
          ],
          stop_reason: "tool_use"
        },
        # Child agent: responds (Fake is shared, child picks up next response)
        %{
          content: [%{"type" => "text", "text" => "Child completed the task."}],
          stop_reason: "end_turn"
        },
        # Parent: uses the child result
        %{
          content: [%{"type" => "text", "text" => "Done, child said it completed."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch child")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "tool_call" in event_types
      assert "subagent_launched" in event_types

      launched = Enum.find(events, &(&1.event_type == "subagent_launched"))
      assert launched.payload["child_agent_name"] == "child-agent"
      assert launched.payload["tool_call_id"] == "call_launch"
    end

    test "rejects self-launch", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_self",
              "name" => "launch_agent",
              "input" => %{"agent_name" => agent.name, "message" => "Launch myself"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => "Got an error."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch self")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)

      tool_result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "launch_agent"))
      assert tool_result.payload["is_error"] == true
      assert tool_result.payload["content"] =~ "Cannot launch self"
    end

    test "passes context to child agent via launch_agent tool", %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "context-child", purpose: "Receives context"})

      Fake.set_responses([
        # Parent: calls launch_agent with context
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_ctx",
              "name" => "launch_agent",
              "input" => %{
                "agent_name" => "context-child",
                "message" => "Process this ticket",
                "context" => %{
                  "messages" => [
                    %{"role" => "user", "content" => "Original ticket: printer is broken"},
                    %{"role" => "assistant", "content" => "I'll route this to the right team."}
                  ],
                  "data" => %{"ticket_id" => "T-123", "priority" => "high"}
                }
              }
            }
          ],
          stop_reason: "tool_use"
        },
        # Child agent responds
        %{
          content: [%{"type" => "text", "text" => "Ticket T-123 resolved."}],
          stop_reason: "end_turn"
        },
        # Parent completes
        %{
          content: [%{"type" => "text", "text" => "Child resolved the ticket."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Handle ticket")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      # Verify the subagent_launched event includes context
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      launched = Enum.find(events, &(&1.event_type == "subagent_launched"))
      assert launched != nil
      assert launched.payload["context"]["data"]["ticket_id"] == "T-123"
      assert length(launched.payload["context"]["messages"]) == 2

      # Verify child run was created with context in its input
      child_run_id = launched.payload["child_run_id"]
      child_run = Runs.get_run!(child_run_id)
      assert child_run.input["context"] != nil
      assert child_run.input["context"]["data"]["ticket_id"] == "T-123"

      # Verify child run's events show the context was used
      child_events = Runs.list_events(child_run.id)
      llm_request = Enum.find(child_events, &(&1.event_type == "llm_request"))
      assert llm_request != nil
      messages = llm_request.payload["messages"]

      # Should contain inherited messages + data message + user message
      assert length(messages) >= 4

      # Check inherited messages are present
      assert Enum.any?(messages, fn m ->
        m["content"] == "Original ticket: printer is broken" || m[:content] == "Original ticket: printer is broken"
      end)

      # Check data context message is present
      assert Enum.any?(messages, fn m ->
        content = m["content"] || m[:content] || ""
        String.contains?(content, "T-123") and String.contains?(content, "Inherited context")
      end)
    end

    test "launch_agent works without context (backward compatible)", %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "no-ctx-child", purpose: "No context"})

      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_noctx",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "no-ctx-child", "message" => "Do something"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => "Done."}],
          stop_reason: "end_turn"
        },
        %{
          content: [%{"type" => "text", "text" => "Child finished."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch without context")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      launched = Enum.find(events, &(&1.event_type == "subagent_launched"))
      assert launched != nil
      # No context field in the event
      refute Map.has_key?(launched.payload, "context")
    end

    test "rejects not-found agent", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_nf",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "nonexistent-agent", "message" => "Hello"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => "Agent not found."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch nonexistent")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)

      tool_result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "launch_agent"))
      assert tool_result.payload["is_error"] == true
      assert tool_result.payload["content"] =~ "not found"
    end
  end
end
