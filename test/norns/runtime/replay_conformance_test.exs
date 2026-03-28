defmodule Norns.Runtime.ReplayConformanceTest do
  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake
  alias Norns.Runs
  alias Norns.Tools.Tool

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    {:ok, side_effects} = Agent.start_link(fn -> [] end)

    tool = %Tool{
      name: "side_effect",
      description: "records a deterministic side effect",
      input_schema: %{},
      side_effect?: true,
      handler: fn %{"value" => value} ->
        key = get_in(Process.get(:norns_tool_context), [:idempotency_key]) || "no-key"

        Agent.get_and_update(side_effects, fn seen ->
          if Enum.any?(seen, fn {existing_key, _value} -> existing_key == key end) do
            {{:ok, "stored:#{value}"}, seen}
          else
            {{:ok, "stored:#{value}"}, [{key, value} | seen]}
          end
        end)
        |> case do
          {:ok, result} -> {:ok, result}
        end
      end
    }

    %{tenant: tenant, agent: agent, side_effects: side_effects, tool: tool}
  end

  test "rebuild_state detects pending tool calls and sets resume_tools action", %{tenant: tenant, agent: agent, tool: tool} do
    # Simulate: tool_call logged but no tool_result — crash before result arrived
    {:ok, run} =
      Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "do work"},
        status: "running"
      })

    Runs.append_event(run, %{event_type: "run_started"})
    Runs.append_event(run, %{
      event_type: "llm_response",
      payload: %{
        "content" => [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "arguments" => %{"value" => "once"}}],
        "finish_reason" => "tool_call",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20},
        "step" => 1
      }
    })
    Runs.append_event(run, %{
      event_type: "tool_call",
      payload: %{
        "tool_call_id" => "call_1",
        "name" => "side_effect",
        "arguments" => %{"value" => "once"},
        "step" => 1,
        "side_effect" => true,
        "idempotency_key" => "run:#{run.id}:step:1:tool:call_1:name:side_effect"
      }
    })
    # NO tool_result — crash happened here

    base_state = %{
      agent_id: agent.id,
      tenant_id: tenant.id,
      agent: agent,
      api_key: "test-key",
      agent_def: Norns.Agents.AgentDef.from_agent(agent, tools: [tool]),
      conversation: nil,
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      pending_ask: nil,
      pending_llm_task: nil,
      pending_tool_tasks: nil,
      resume_action: nil,
      test_pid: nil
    }

    {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

    assert rebuilt.status == :running
    assert rebuilt.step == 1
    # The resume action should be to re-dispatch the pending tools
    assert match?({:resume_tools, [%{"id" => "call_1"} | _]}, rebuilt.resume_action)
    # Messages include the assistant response with tool_use
    assert length(rebuilt.messages) == 2  # user + assistant
  end

  test "resumes from crash after tool result persisted without re-executing", %{tenant: tenant, agent: agent, side_effects: side_effects, tool: tool} do
    # Simulate: agent dispatched tool, result came back and was persisted,
    # then crashed before the next LLM call. On resume, tool should NOT re-execute.
    {:ok, run} =
      Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "do work"},
        status: "running"
      })

    Runs.append_event(run, %{event_type: "run_started"})
    Runs.append_event(run, %{
      event_type: "llm_response",
      payload: %{
        "content" => [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "arguments" => %{"value" => "once"}}],
        "finish_reason" => "tool_call",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20},
        "step" => 1
      }
    })
    Runs.append_event(run, %{
      event_type: "tool_call",
      payload: %{
        "tool_call_id" => "call_1",
        "name" => "side_effect",
        "arguments" => %{"value" => "once"},
        "step" => 1,
        "side_effect" => true,
        "idempotency_key" => "run:#{run.id}:step:1:tool:call_1:name:side_effect"
      }
    })
    Runs.append_event(run, %{
      event_type: "tool_result",
      payload: %{
        "tool_call_id" => "call_1",
        "content" => "side_effect:once",
        "is_error" => false,
        "step" => 1,
        "idempotency_key" => "run:#{run.id}:step:1:tool:call_1:name:side_effect"
      }
    })
    # Crash happened here — tool result persisted but no checkpoint/LLM call

    Fake.set_responses([
      %{content: [%{"type" => "text", "text" => "finished"}], stop_reason: "end_turn"}
    ])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

    {:ok, resumed_pid} =
      AgentProcess.start_link(
        agent_id: agent.id,
        tenant_id: tenant.id,
        tools: [tool],
        resume_run_id: run.id
      )

    receive do
      {:completed, _} -> :ok
      {:error, _} -> :ok
    after
      5000 -> flunk("Agent did not complete after resume")
    end

    run = Runs.get_run!(run.id)
    assert run.status == "completed"
    assert run.output == "finished"

    # Side effect should NOT have been re-executed — result was already persisted
    assert side_effect_values(side_effects) == []

    events = Runs.list_events(run.id)
    assert Enum.count(events, &(&1.event_type == "tool_call")) == 1
    assert Enum.count(events, &(&1.event_type == "tool_result")) == 1
  end

  test "reconstructs equivalent state when crashing before checkpoint write", %{tenant: tenant, agent: agent, tool: tool} do
    Process.flag(:trap_exit, true)

    Fake.set_responses([
      %{
        content: [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "arguments" => %{"value" => "cp"}}],
        stop_reason: "tool_use"
      }
    ])

    {:ok, pid} =
      AgentProcess.start_link(
        agent_id: agent.id,
        tenant_id: tenant.id,
        tools: [tool],
        test_pid: self()
      )

    ref = Process.monitor(pid)
    AgentProcess.send_message(pid, "checkpoint")

    assert_receive {:runtime_hook, hook, _payload}, 1_000
    send(pid, {:runtime_hook_reply, hook, :crash})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    [run] = Runs.list_runs(agent.id)
    events = Runs.list_events(run.id)
    refute Enum.any?(events, &(&1.event_type == "checkpoint_saved"))

    base_state = %{
      agent_id: agent.id,
      tenant_id: tenant.id,
      agent: agent,
      api_key: "test-key",
      agent_def: Norns.Agents.AgentDef.from_agent(agent, tools: [tool]),
      conversation: nil,
      tools: [tool],
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      pending_ask: nil,
      resume_action: nil,
      test_pid: nil
    }

    {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

    assert rebuilt.step == 1
    assert match?({:resume_tools, [_ | _]}, rebuilt.resume_action)
    assert Enum.any?(rebuilt.messages, fn
             %{role: "assistant", content: content} when is_list(content) ->
               Enum.any?(content, &(&1["type"] == "tool_use" and &1["id"] == "call_1"))

             _ ->
               false
           end)
  end

  test "resume from checkpoint plus trailing events keeps event sequence consistent", %{tenant: tenant, agent: agent} do
    {:ok, run} =
      Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "hello"},
        status: "running"
      })

    Runs.append_event(run, %{event_type: "run_started"})

    Runs.append_event(run, %{
      event_type: "checkpoint_saved",
      payload: %{
        "messages" => [%{role: "user", content: "hello"}, %{role: "assistant", content: [%{"type" => "text", "text" => "old"}]}],
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "llm_response",
      payload: %{
        "content" => [%{"type" => "text", "text" => "new"}],
        "finish_reason" => "stop",
        "usage" => %{},
        "step" => 2
      }
    })

    base_state = %{
      agent_id: agent.id,
      tenant_id: tenant.id,
      agent: agent,
      api_key: "test-key",
      agent_def: Norns.Agents.AgentDef.from_agent(agent),
      conversation: nil,
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      pending_ask: nil,
      resume_action: nil,
      test_pid: nil
    }

    {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)
    events = Runs.list_events(run.id)

    assert rebuilt.step == 2
    assert rebuilt.resume_action == :llm_loop
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
    assert List.last(rebuilt.messages).content == [%{"type" => "text", "text" => "new"}]
  end

  test "rebuilds waiting runs with deterministic waiting resume action", %{tenant: tenant, agent: agent} do
    {:ok, run} =
      Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "hello"},
        status: "waiting"
      })

    Runs.append_event(run, %{event_type: "run_started"})

    Runs.append_event(run, %{
      event_type: "llm_response",
      payload: %{
        "content" => [%{"type" => "tool_use", "id" => "ask_1", "name" => "ask_user", "arguments" => %{"question" => "Need approval?"}}],
        "finish_reason" => "tool_call",
        "usage" => %{},
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "waiting_for_user",
      payload: %{"question" => "Need approval?", "tool_call_id" => "ask_1", "step" => 1}
    })

    base_state = %{
      agent_id: agent.id,
      tenant_id: tenant.id,
      agent: agent,
      api_key: "test-key",
      agent_def: Norns.Agents.AgentDef.from_agent(agent),
      conversation: nil,
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      pending_ask: nil,
      resume_action: nil,
      test_pid: nil
    }

    {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

    assert rebuilt.status == :waiting
    assert rebuilt.resume_action == :waiting
    assert rebuilt.pending_ask.tool_use_id == "ask_1"
  end

  test "rebuild skips duplicate side effects and resumes deterministically", %{tenant: tenant, agent: agent} do
    {:ok, run} =
      Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "hello"},
        status: "running"
      })

    Runs.append_event(run, %{event_type: "run_started"})

    Runs.append_event(run, %{
      event_type: "llm_response",
      payload: %{
        "content" => [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "arguments" => %{"value" => "once"}}],
        "finish_reason" => "tool_call",
        "usage" => %{},
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "tool_call",
      payload: %{
        "tool_call_id" => "call_1",
        "name" => "side_effect",
        "arguments" => %{"value" => "once"},
        "step" => 1,
        "side_effect" => true,
        "idempotency_key" => "run:#{run.id}:step:1:tool:call_1:name:side_effect"
      }
    })

    Runs.append_event(run, %{
      event_type: "tool_duplicate",
      payload: %{
        "tool_call_id" => "call_1",
        "name" => "side_effect",
        "idempotency_key" => "run:#{run.id}:step:1:tool:call_1:name:side_effect",
        "step" => 1,
        "original_event_sequence" => 3,
        "resolution" => "reused_persisted_result"
      }
    })

    base_state = %{
      agent_id: agent.id,
      tenant_id: tenant.id,
      agent: agent,
      api_key: "test-key",
      agent_def: Norns.Agents.AgentDef.from_agent(agent),
      conversation: nil,
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      pending_ask: nil,
      resume_action: nil,
      test_pid: nil
    }

    {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state)

    assert rebuilt.status == :running
    assert rebuilt.step == 1
    assert rebuilt.resume_action == :llm_loop
  end

  defp side_effect_values(side_effects) do
    side_effects
    |> Agent.get(&Enum.reverse/1)
    |> Enum.map(fn {_key, value} -> value end)
  end
end
