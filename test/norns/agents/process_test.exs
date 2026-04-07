defmodule Norns.Agents.ProcessTest do
  use Norns.DataCase, async: false

  alias Norns.{Conversations, Runs}
  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)

    %{tenant: tenant, agent: agent}
  end

  # Subscribe and wait for a specific PubSub event
  defp wait_for_completion(agent_id, timeout \\ 5000) do
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent_id}")

    receive do
      {:completed, _} -> :ok
      {:error, _} -> :ok
    after
      timeout -> flunk("Agent did not complete within #{timeout}ms")
    end
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

  defp collect_events_until(terminal_event, timeout \\ 5000, acc \\ []) do
    receive do
      {^terminal_event, _payload} = event -> Enum.reverse([event | acc])
      {_type, _payload} = event -> collect_events_until(terminal_event, timeout, [event | acc])
    after
      timeout -> flunk("Did not receive #{terminal_event} within #{timeout}ms")
    end
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
      subscribe_and_send(pid, agent.id, "Hello agent")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle
      assert state.step == 1

      assert state.run_id != nil
      run = Runs.get_run!(state.run_id)
      assert run.status == "completed"
      assert run.output == "Hello! I can help with that."

      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "run_started" in event_types
      assert "llm_request" in event_types
      assert "llm_response" in event_types
      assert "run_completed" in event_types
    end

    test "conversation persists messages across runs", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "first"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "second"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)

      subscribe_and_send(pid, agent.id, "first message")
      wait_for(:completed)

      AgentProcess.send_message(pid, "second message")
      wait_for(:completed)

      [first_call, second_call] = Fake.calls()
      assert first_call.messages == [%{"role" => "user", "content" => "first message"}]
      # Second run includes conversation history
      assert length(second_call.messages) == 3
      assert List.last(second_call.messages) == %{"role" => "user", "content" => "second message"}
    end
  end

  describe "tool use flow" do
    test "executes tool calls and continues LLM loop", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
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
        %{
          content: [%{"type" => "text", "text" => "Based on my search, Elixir is great!"}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          
        )

      subscribe_and_send(pid, agent.id, "Tell me about Elixir")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle
      assert state.step == 2

      run = Runs.get_run!(state.run_id)
      assert run.status == "completed"

      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "tool_call" in event_types
      assert "tool_result" in event_types
      assert Enum.count(event_types, &(&1 == "llm_request")) == 2
    end
  end

  describe "max steps" do
    test "stops when max_steps exceeded", %{tenant: tenant, agent: agent} do
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
          max_steps: 3
        )

      subscribe_and_send(pid, agent.id, "Loop forever")
      wait_for(:error)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      assert run.status == "failed"

      events = Runs.list_events(run.id)
      error_event = Enum.find(events, &(&1.event_type == "run_failed"))
      assert error_event.payload["error"] =~ "Max steps"
      assert error_event.payload["error_class"] == "internal"
      assert error_event.payload["retry_decision"] == "terminal"
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

      # Collect all events until completion
      events = collect_events_until(:completed)

      event_types = Enum.map(events, fn {type, _} -> type end)
      assert :agent_started in event_types
      assert :llm_response in event_types
      assert :completed in event_types
    end
  end

  describe "conversation mode" do
    test "persists context across runs and links runs to the conversation", %{tenant: tenant} do
      agent =
        create_agent(tenant, %{
          model_config: %{"mode" => "conversation", "context_window" => 20}
        })

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "First reply"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "Second reply"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          conversation_key: "slack:C123"
        )

      subscribe_and_send(pid, agent.id, "first message")
      wait_for(:completed)
      first_run_id = AgentProcess.get_state(pid).run_id

      AgentProcess.send_message(pid, "second message")
      wait_for(:completed)
      second_run_id = AgentProcess.get_state(pid).run_id

      conversation = Conversations.get_conversation_by_agent_key!(agent.id, "slack:C123")
      assert conversation.message_count == 4
      assert length(conversation.messages) == 4

      first_run = Runs.get_run!(first_run_id)
      second_run = Runs.get_run!(second_run_id)

      assert first_run.conversation_id == conversation.id
      assert second_run.conversation_id == conversation.id

      [first_call, second_call] = Fake.calls()
      assert length(first_call.messages) == 1
      assert length(second_call.messages) == 3
      assert Enum.at(second_call.messages, 0)["content"] == "first message"
      assert Enum.at(second_call.messages, 2)["content"] == "second message"
    end
  end
end
