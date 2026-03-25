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
      handler: fn %{"value" => value} ->
        Agent.update(side_effects, &[value | &1])
        {:ok, "stored:#{value}"}
      end
    }

    %{tenant: tenant, agent: agent, side_effects: side_effects, tool: tool}
  end

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
    assert Agent.get(side_effects, &Enum.reverse/1) == ["once"]

    events = Runs.list_events(run.id)
    assert Enum.count(events, &(&1.event_type == "tool_call")) == 1
    assert Enum.count(events, &(&1.event_type == "tool_result")) == 1

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
end
