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

  @tag :skip
  @tag :pending_async_replay
  test "replays pending tool work after crash without duplicating side effects", %{tenant: tenant, agent: agent, side_effects: side_effects, tool: tool} do
    Process.flag(:trap_exit, true)

    Fake.set_responses([
      %{
        content: [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "input" => %{"value" => "once"}}],
        stop_reason: "tool_use"
      },
      %{
        content: [%{"type" => "text", "text" => "finished"}],
        stop_reason: "end_turn"
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
    AgentProcess.send_message(pid, "do work")

    assert_receive {:runtime_hook, hook, _payload}, 1_000
    send(pid, {:runtime_hook_reply, hook, :crash})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    [run] = Runs.list_runs(agent.id)
    assert Runs.get_run!(run.id).status == "running"
    assert Agent.get(side_effects, & &1) == []

    {:ok, resumed_pid} =
      AgentProcess.start_link(
        agent_id: agent.id,
        tenant_id: tenant.id,
        tools: [tool],
        resume_run_id: run.id
      )

    Process.sleep(300)

    run = Runs.get_run!(run.id)
    assert run.status == "completed"
    assert run.output == "finished"
    assert side_effect_values(side_effects) == ["once"]

    events = Runs.list_events(run.id)
    assert Enum.count(events, &(&1.event_type == "tool_call")) == 1
    assert Enum.count(events, &(&1.event_type == "tool_result")) == 1

    state = AgentProcess.get_state(resumed_pid)
    assert state.status == :idle
  end

  @tag :skip
  @tag :pending_async_replay
  test "replays crash after side effect execution without duplicating the side effect", %{tenant: tenant, agent: agent, side_effects: side_effects, tool: tool} do
    Process.flag(:trap_exit, true)

    Fake.set_responses([
      %{
        content: [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "input" => %{"value" => "once"}}],
        stop_reason: "tool_use"
      },
      %{
        content: [%{"type" => "text", "text" => "finished"}],
        stop_reason: "end_turn"
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
    AgentProcess.send_message(pid, "do work")

    assert_receive {:runtime_hook, :after_tool_execution_before_result_persisted, _payload}, 1_000
    send(pid, {:runtime_hook_reply, :after_tool_execution_before_result_persisted, :crash})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    [run] = Runs.list_runs(agent.id)
    assert side_effect_values(side_effects) == ["once"]

    {:ok, resumed_pid} =
      AgentProcess.start_link(
        agent_id: agent.id,
        tenant_id: tenant.id,
        tools: [tool],
        resume_run_id: run.id
      )

    Process.sleep(300)

    run = Runs.get_run!(run.id)
    assert run.status == "completed"
    assert run.output == "finished"
    assert side_effect_values(side_effects) == ["once"]

    events = Runs.list_events(run.id)
    assert Enum.count(events, &(&1.event_type == "tool_call")) == 1
    assert Enum.count(events, &(&1.event_type == "tool_result")) == 1
    refute Enum.any?(events, &(&1.event_type == "tool_duplicate"))

    state = AgentProcess.get_state(resumed_pid)
    assert state.status == :idle
  end

  test "reconstructs equivalent state when crashing before checkpoint write", %{tenant: tenant, agent: agent, tool: tool} do
    Process.flag(:trap_exit, true)

    Fake.set_responses([
      %{
        content: [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "input" => %{"value" => "cp"}}],
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
        "stop_reason" => "end_turn",
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
        "content" => [%{"type" => "tool_use", "id" => "ask_1", "name" => "ask_user", "input" => %{"question" => "Need approval?"}}],
        "stop_reason" => "tool_use",
        "usage" => %{},
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "waiting_for_user",
      payload: %{"question" => "Need approval?", "tool_use_id" => "ask_1", "step" => 1}
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
        "content" => [%{"type" => "tool_use", "id" => "call_1", "name" => "side_effect", "input" => %{"value" => "once"}}],
        "stop_reason" => "tool_use",
        "usage" => %{},
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "tool_call",
      payload: %{
        "tool_use_id" => "call_1",
        "name" => "side_effect",
        "input" => %{"value" => "once"},
        "step" => 1,
        "side_effect" => true,
        "idempotency_key" => "run:#{run.id}:step:1:tool:call_1:name:side_effect"
      }
    })

    Runs.append_event(run, %{
      event_type: "tool_duplicate",
      payload: %{
        "tool_use_id" => "call_1",
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
