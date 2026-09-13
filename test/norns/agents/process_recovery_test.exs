defmodule Norns.Agents.ProcessRecoveryTest do
  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.TestWorker.LLM
  alias Norns.Runs
  alias Norns.TestWorker.Tool

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
      Runs.append_event(run, %{event_type: "run_started", source: "system"})

      Runs.append_event(run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => 1, "message_count" => 1}
      })

      Runs.append_event(run, %{
        event_type: "llm_response",
        source: "system",
        payload: %{
          "content" => "",
          "tool_calls" => [%{"id" => "call_1", "name" => "search", "arguments" => %{"query" => "elixir"}}],
          "finish_reason" => "tool_call",
          "step" => 1,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
        }
      })

      Runs.append_event(run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{"tool_call_id" => "call_1", "name" => "search", "arguments" => %{"query" => "elixir"}, "step" => 1}
      })

      Runs.append_event(run, %{
        event_type: "tool_result",
        source: "system",
        payload: %{"tool_call_id" => "call_1", "name" => "search", "content" => "Elixir is a functional language", "is_error" => false, "step" => 1}
      })

      # "Crash" happened here — run is still status: "running"

      # Step 2: Set up fake response for resumed execution
      LLM.set_responses([
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
      assert "run_started" in event_types
      assert "tool_call" in event_types
      assert "tool_result" in event_types

      # New events from resume
      assert "run_completed" in event_types

      # The LLM was called with the reconstructed message history
      # (assistant tool_use + user tool_result already in messages)
      llm_requests = Enum.filter(all_events, &(&1.event_type == "llm_request"))
      # 1 from original + 1 from resume
      assert length(llm_requests) == 2
    end

    test "a run parked on ask_human re-parks instead of resuming the loop", %{
      tenant: tenant,
      agent: agent
    } do
      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"user_message" => "Buy me tickets"},
          status: "running"
        })

      Runs.append_event(run, %{event_type: "run_started", source: "system"})

      Runs.append_event(run, %{
        event_type: "llm_response",
        source: "system",
        payload: %{
          "content" => "",
          "tool_calls" => [
            %{"id" => "call_ask", "name" => "ask_human", "arguments" => %{"question" => "Book the 7pm show?"}}
          ],
          "finish_reason" => "tool_call",
          "step" => 1,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
        }
      })

      Runs.append_event(run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{
          "tool_call_id" => "call_ask",
          "name" => "ask_human",
          "arguments" => %{"question" => "Book the 7pm show?"},
          "step" => 1
        }
      })

      Runs.append_event(run, %{
        event_type: "waiting_for_user",
        source: "system",
        payload: %{"tool_call_id" => "call_ask", "question" => "Book the 7pm show?", "step" => 1}
      })

      # "Crash" here — the question was never answered.

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          resume_run_id: run.id
        )

      # The question is re-asked so a waiting subscriber can answer it again.
      assert_receive {:waiting_for_user, %{question: "Book the 7pm show?"}}, 5000

      state = AgentProcess.get_state(pid)
      assert state.status == :waiting

      # It parked rather than calling the LLM again.
      assert Runs.list_events(run.id)
             |> Enum.count(&(&1.event_type == "llm_request")) == 0

      # And it can still be answered after recovery.
      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "Booked."}], stop_reason: "end_turn"}
      ])

      assert :ok = AgentProcess.reply_to_human(pid, "yes")
      assert_receive {:completed, _}, 5000

      assert Runs.get_run!(run.id).status == "completed"
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

      Runs.append_event(run, %{event_type: "run_started", source: "system"})

      Runs.append_event(run, %{
        event_type: "llm_response",
        source: "system",
        payload: %{
          "content" => "I'll search for that.",
          "tool_calls" => [%{"id" => "c1", "name" => "web_search", "arguments" => %{"query" => "test"}}],
          "finish_reason" => "tool_call",
          "step" => 1,
          "usage" => %{}
        }
      })

      Runs.append_event(run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{"tool_call_id" => "c1", "name" => "web_search", "arguments" => %{"query" => "test"}, "step" => 1}
      })

      Runs.append_event(run, %{
        event_type: "tool_result",
        source: "system",
        payload: %{
          "tool_call_id" => "c1",
          "name" => "web_search",
          "content" => "Search results here",
          "is_error" => false,
          "step" => 1
        }
      })

      base_state = %{
        agent_id: agent.id,
        tenant_id: tenant.id,
        agent: agent,
        model: agent.model,
        system_prompt: agent.system_prompt,
        tools: [],
        messages: [],
        step: 0,
        max_steps: 50,
        run: nil,
        status: :idle,
        conversation: nil,
        conversation_key: "default",
      }

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

      assert rebuilt.status == :running
      assert rebuilt.step == 1
      assert length(rebuilt.messages) == 3

      [original_user_msg, assistant_msg, tool_result_msg] = rebuilt.messages
      assert original_user_msg.role == "user"
      assert original_user_msg.content == "test"
      assert assistant_msg.role == "assistant"
      assert tool_result_msg.role == "tool"
      assert is_binary(tool_result_msg.content)
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

      Runs.append_event(run, %{event_type: "run_started", source: "system"})

      Runs.append_event(run, %{
        event_type: "llm_response",
        source: "system",
        payload: %{"content" => "old", "finish_reason" => "stop", "usage" => %{}, "step" => 1}
      })

      checkpoint_messages = [
        %{role: "user", content: "hello"},
        %{role: "assistant", content: "old"}
      ]

      Runs.append_event(run, %{
        event_type: "checkpoint_saved",
        source: "system",
        payload: %{"messages" => checkpoint_messages, "step" => 5}
      })

      base_state = %{
        agent_id: agent.id,
        tenant_id: tenant.id,
        agent: agent,
        model: agent.model,
        system_prompt: agent.system_prompt,
        tools: [],
        messages: [],
        step: 0,
        max_steps: 50,
        run: nil,
        status: :idle,
        conversation: nil,
        conversation_key: "default",
      }

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

      assert rebuilt.step == 5
      assert length(rebuilt.messages) == 2
    end
  end
end
