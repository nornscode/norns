defmodule Norns.Agents.ProcessTest do
  use Norns.DataCase, async: false

  alias Norns.{Agents, Conversations, Runs}
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

    test "a turn cut off at the output limit completes, and says so", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "Here is the first half of the fi"}], stop_reason: "max_tokens"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "write the file")
      wait_for(:completed)

      run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
      # Failing would throw away a turn the user can see and use.
      assert run.status == "completed"
      assert run.output == "Here is the first half of the fi"

      # How a client knows to warn that it was cut off.
      response = Enum.find(Runs.list_events(run.id), &(&1.event_type == "llm_response"))
      assert response.payload["finish_reason"] == "length"
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

  describe "ask_human / human-in-the-loop" do
    defp ask_human_response(question, id \\ "call_ask") do
      %{
        content: [
          %{"type" => "tool_use", "id" => id, "name" => "ask_human", "input" => %{"question" => question}}
        ],
        stop_reason: "tool_use"
      }
    end

    test "parks in :waiting and broadcasts the question", %{tenant: tenant, agent: agent} do
      Fake.set_responses([ask_human_response("Book the 7pm show?")])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Buy me tickets")

      payload = wait_for(:waiting_for_user)
      assert payload.question == "Book the 7pm show?"
      assert payload.tool_call_id == "call_ask"

      state = AgentProcess.get_state(pid)
      assert state.status == :waiting

      run = Runs.get_run!(state.run_id)
      event_types = Enum.map(Runs.list_events(run.id), & &1.event_type)
      assert "waiting_for_user" in event_types

      # Polling clients can tell "working" from "waiting on you".
      assert run.status == "waiting"
      assert %{"question" => "Book the 7pm show?", "tool_call_id" => "call_ask"} =
               Runs.pending_question(run)
    end

    test "a reply resumes the run and feeds the answer back to the LLM", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        ask_human_response("Book the 7pm show?"),
        %{content: [%{"type" => "text", "text" => "Booked."}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Buy me tickets")
      wait_for(:waiting_for_user)

      assert :ok = AgentProcess.reply_to_human(pid, "yes, go ahead")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      assert run.status == "completed"
      assert Runs.pending_question(run) == nil

      events = Runs.list_events(run.id)

      answer =
        Enum.find(events, fn e ->
          e.event_type == "tool_result" and e.payload["name"] == "ask_human"
        end)

      assert answer.payload["content"] == "yes, go ahead"
      assert answer.payload["tool_call_id"] == "call_ask"

      # The LLM ran again after the answer arrived.
      assert Enum.count(events, &(&1.event_type == "llm_request")) == 2
    end

    test "a normal message to a parked agent is treated as the answer", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        ask_human_response("Book the 7pm show?"),
        %{content: [%{"type" => "text", "text" => "Booked."}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Buy me tickets")
      wait_for(:waiting_for_user)

      # A conversational client just replies — no separate endpoint, no :busy.
      assert {:ok, _run_id} = AgentProcess.send_message(pid, "yes, the 7pm one")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)
      assert run.status == "completed"

      answer =
        Runs.list_events(run.id)
        |> Enum.find(&(&1.event_type == "tool_result" and &1.payload["name"] == "ask_human"))

      assert answer.payload["content"] == "yes, the 7pm one"
    end

    test "replying to an agent that is not waiting is rejected", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "Done."}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Hello")
      wait_for(:completed)

      assert {:error, :not_waiting} = AgentProcess.reply_to_human(pid, "unsolicited")
    end

    test "other tool results are held and delivered alongside the answer", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_search", "name" => "web_search", "input" => %{"query" => "shows"}},
            %{"type" => "tool_use", "id" => "call_ask", "name" => "ask_human", "input" => %{"question" => "Which one?"}}
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "Booked."}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Find and book a show")

      wait_for(:waiting_for_user)
      assert :ok = AgentProcess.reply_to_human(pid, "the 7pm one")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)

      result_ids =
        events
        |> Enum.filter(&(&1.event_type == "tool_result"))
        |> Enum.map(& &1.payload["tool_call_id"])

      assert "call_search" in result_ids
      assert "call_ask" in result_ids
    end
  end

  describe "agent_def refresh" do
    test "picks up a model change from a REST update mid-run, without a restart", %{
      tenant: tenant,
      agent: agent
    } do
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
        AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id, test_pid: self())

      subscribe_and_send(pid, agent.id, "Tell me about Elixir")

      # Give the update time to land in the DB before the process dispatches
      # its second (post-tool-call) LLM request.
      assert_receive {:runtime_hook, :after_tool_call_persisted, _payload}, 1_000
      {:ok, _agent} = Agents.update_agent(agent, %{model: "claude-updated-model"})

      wait_for(:completed)

      calls = Fake.calls()
      assert Enum.map(calls, & &1.model) == [agent.model, "claude-updated-model"]
    end
  end

  describe "sliding window context strategy" do
    test "keeps tool_use/tool_result pairs atomic when trimming", %{tenant: tenant} do
      agent = create_agent(tenant, %{model_config: %{"context_window" => 1}})

      Fake.set_responses([
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_1", "name" => "web_search", "input" => %{"query" => "a"}}
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_2", "name" => "web_search", "input" => %{"query" => "b"}}
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => "Done."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Search twice")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)

      llm_requests =
        events
        |> Enum.filter(&(&1.event_type == "llm_request"))
        |> Enum.sort_by(& &1.payload["step"])

      # Step 3's request is built from a 5-message history (user, assistant+tool_use,
      # tool_result, assistant+tool_use, tool_result) with context_window=1 — a naive
      # tail-slice would start on the second tool_result and orphan it.
      third_request = Enum.at(llm_requests, 2)
      messages = third_request.payload["messages"]

      refute hd(messages)["role"] == "tool"

      tool_use_ids =
        messages
        |> Enum.flat_map(&(&1["tool_calls"] || []))
        |> Enum.map(& &1["id"])

      tool_result_ids =
        messages
        |> Enum.filter(&(&1["role"] == "tool"))
        |> Enum.map(& &1["tool_call_id"])

      assert Enum.all?(tool_result_ids, &(&1 in tool_use_ids))
    end
  end

  describe "empty final output fallback" do
    test "falls back to the last non-empty assistant content", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{
          content: [
            %{"type" => "text", "text" => "Here's what I found: Elixir is great."},
            %{"type" => "tool_use", "id" => "call_1", "name" => "web_search", "input" => %{"query" => "elixir"}}
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => ""}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Tell me about Elixir")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)

      assert run.status == "completed"
      assert run.output == "Here's what I found: Elixir is great."
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

      # Each turn carries the run that produced it, so a client can draw the
      # same run boundaries whether or not it watched them happen.
      assert Enum.map(conversation.messages, & &1["run_id"]) ==
               [first_run_id, first_run_id, second_run_id, second_run_id]

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

    test "preserves tool_calls/tool_call_id when a later turn reloads from the DB", %{
      tenant: tenant,
      agent: agent
    } do
      agent =
        create_agent(tenant, %{
          model_config: %{"mode" => "conversation", "context_window" => 20},
          name: agent.name <> "-tools"
        })

      conversation_key = "slack:C-tools"

      # Turn 1: a tool-using exchange. Messages stay in-memory (atom-keyed)
      # and are persisted to the conversation on completion.
      Fake.set_responses([
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_1", "name" => "web_search", "input" => %{"query" => "elixir"}}
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "Found it."}], stop_reason: "end_turn"}
      ])

      {:ok, pid1} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          conversation_key: conversation_key
        )

      subscribe_and_send(pid1, agent.id, "search for elixir")
      wait_for(:completed)

      # Stop the process so turn 2 starts fresh and must reload the
      # conversation history from Postgres (the path that stripped tool ids).
      :ok = GenServer.stop(pid1)
      wait_until_deregistered(tenant.id, agent.id, conversation_key)

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "Second reply"}], stop_reason: "end_turn"}
      ])

      {:ok, pid2} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          conversation_key: conversation_key
        )

      subscribe_and_send(pid2, agent.id, "and now summarize")
      wait_for(:completed)

      second_run_id = AgentProcess.get_state(pid2).run_id
      run = Runs.get_run!(second_run_id)

      # The neutral message history dispatched on turn 2 (reloaded from the DB)
      # must still pair the assistant tool_use with its tool result.
      llm_request =
        run.id
        |> Runs.list_events()
        |> Enum.find(&(&1.event_type == "llm_request"))

      messages = llm_request.payload["messages"]

      assistant_with_tools =
        Enum.find(messages, fn m -> m["role"] == "assistant" and m["tool_calls"] not in [nil, []] end)

      assert assistant_with_tools, "expected reloaded assistant message to retain tool_calls"
      assert hd(assistant_with_tools["tool_calls"])["id"] == "call_1"

      tool_message = Enum.find(messages, &(&1["role"] == "tool"))
      assert tool_message, "expected reloaded tool result message to be present"
      assert tool_message["tool_call_id"] == "call_1"
    end
  end

  defp wait_until_deregistered(tenant_id, agent_id, conversation_key, attempts \\ 50) do
    case Norns.Agents.Registry.lookup(tenant_id, agent_id, conversation_key) do
      :error -> :ok
      {:ok, _pid} when attempts > 0 ->
        Process.sleep(10)
        wait_until_deregistered(tenant_id, agent_id, conversation_key, attempts - 1)
      {:ok, _pid} -> flunk("agent process still registered after stop")
    end
  end
end
