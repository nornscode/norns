defmodule Norns.Agents.ProcessRecoveryTest do
  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake
  alias Norns.Runs
  alias Norns.Tools.Tool

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)

    %{tenant: tenant, agent: agent}
  end

  describe "state reconstruction" do
    test "resumes from event log and completes", %{tenant: tenant, agent: agent} do
      # Step 1: Create a run manually and populate events as if it crashed mid-execution
      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"user_message" => "Research Elixir"},
          status: "running"
        })

      # Simulate events that would have been logged before a crash
      Runs.append_event(run, %{event_type: "agent_started", source: "system"})

      Runs.append_event(run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => 1, "message_count" => 1}
      })

      Runs.append_event(run, %{
        event_type: "llm_response",
        source: "system",
        payload: %{
          "content" => [
            %{"type" => "tool_use", "id" => "call_1", "name" => "search", "input" => %{"query" => "elixir"}}
          ],
          "stop_reason" => "tool_use",
          "step" => 1,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
        }
      })

      Runs.append_event(run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{"tool_use_id" => "call_1", "name" => "search", "input" => %{"query" => "elixir"}, "step" => 1}
      })

      Runs.append_event(run, %{
        event_type: "tool_result",
        source: "system",
        payload: %{"tool_use_id" => "call_1", "content" => "Elixir is a functional language", "is_error" => false, "step" => 1}
      })

      # "Crash" happened here — run is still status: "running"

      # Step 2: Set up fake response for resumed execution
      Fake.set_responses([
        %{
          content: [%{"type" => "text", "text" => "Recovered: Elixir is great!"}],
          stop_reason: "end_turn"
        }
      ])

      search_tool = %Tool{
        name: "search",
        description: "Search",
        input_schema: %{},
        handler: fn %{"query" => q} -> {:ok, "Results for #{q}"} end
      }

      # Step 3: Resume from the event log
      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          tools: [search_tool],
          resume_run_id: run.id
        )

      Process.sleep(300)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      # Run should be completed
      run = Runs.get_run!(run.id)
      assert run.status == "completed"
      assert run.output == "Recovered: Elixir is great!"

      # Verify the full event log
      all_events = Runs.list_events(run.id)
      event_types = Enum.map(all_events, & &1.event_type)

      # Original events still present
      assert "agent_started" in event_types
      assert "tool_call" in event_types
      assert "tool_result" in event_types

      # New events from resume
      assert "agent_completed" in event_types

      # The LLM was called with the reconstructed message history
      # (assistant tool_use + user tool_result already in messages)
      llm_requests = Enum.filter(all_events, &(&1.event_type == "llm_request"))
      # 1 from original + 1 from resume
      assert length(llm_requests) == 2
    end
  end

  describe "rebuild_state/2" do
    test "reconstructs messages from events", %{tenant: tenant, agent: agent} do
      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"user_message" => "test"},
          status: "running"
        })

      Runs.append_event(run, %{event_type: "agent_started", source: "system"})

      Runs.append_event(run, %{
        event_type: "llm_response",
        source: "system",
        payload: %{
          "content" => [
            %{"type" => "text", "text" => "I'll search for that."},
            %{"type" => "tool_use", "id" => "c1", "name" => "web_search", "input" => %{"query" => "test"}}
          ],
          "stop_reason" => "tool_use",
          "step" => 1
        }
      })

      Runs.append_event(run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{"tool_use_id" => "c1", "name" => "web_search", "input" => %{"query" => "test"}, "step" => 1}
      })

      Runs.append_event(run, %{
        event_type: "tool_result",
        source: "system",
        payload: %{
          "tool_use_id" => "c1",
          "content" => "Search results here",
          "is_error" => false,
          "step" => 1
        }
      })

      base_state = %{
        agent_id: agent.id,
        tenant_id: tenant.id,
        agent: agent,
        api_key: "test-key",
        model: agent.model,
        system_prompt: agent.system_prompt,
        tools: [],
        messages: [],
        step: 0,
        max_steps: 50,
        run: nil,
        status: :idle
      }

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

      assert rebuilt.status == :running
      assert rebuilt.step == 1
      assert length(rebuilt.messages) == 2

      [assistant_msg, user_msg] = rebuilt.messages
      assert assistant_msg.role == "assistant"
      assert user_msg.role == "user"
      assert is_list(user_msg.content)
    end

    test "uses checkpoint when available", %{tenant: tenant, agent: agent} do
      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{},
          status: "running"
        })

      Runs.append_event(run, %{event_type: "agent_started", source: "system"})

      Runs.append_event(run, %{
        event_type: "llm_response",
        source: "system",
        payload: %{"content" => [%{"type" => "text", "text" => "old"}], "step" => 1}
      })

      checkpoint_messages = [
        %{role: "user", content: "hello"},
        %{role: "assistant", content: [%{"type" => "text", "text" => "old"}]}
      ]

      Runs.append_event(run, %{
        event_type: "checkpoint",
        source: "system",
        payload: %{"messages" => checkpoint_messages, "step" => 5}
      })

      base_state = %{
        agent_id: agent.id,
        tenant_id: tenant.id,
        agent: agent,
        api_key: "test-key",
        model: agent.model,
        system_prompt: agent.system_prompt,
        tools: [],
        messages: [],
        step: 0,
        max_steps: 50,
        run: nil,
        status: :idle
      }

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

      assert rebuilt.step == 5
      assert length(rebuilt.messages) == 2
    end
  end
end
