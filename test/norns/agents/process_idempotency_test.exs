defmodule Norns.Agents.ProcessIdempotencyTest do
  @moduledoc """
  A side effect that happened once must not happen twice because the
  orchestrator lost the answer.

  Core cannot know whether the effect landed — the result never arrived, and
  that is the whole problem — so what it does is make the call *nameable*:
  a key derived from run, step, tool call id and gard, all of which survive
  in the log, so the re-dispatched call carries the same name as the first.
  The worker is the only party that knows, and it answers from what it kept.
  """

  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.Agents.Registry, as: AgentRegistry
  alias Norns.Runs
  alias Norns.TestWorker.LLM
  alias Norns.TestWorker.Tool
  alias Norns.Tools.Idempotency

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    %{tenant: tenant, agent: agent}
  end

  defp start_worker(tenant, tools, opts \\ []) do
    {:ok, pid} =
      Norns.TestWorker.start_link(
        Keyword.merge([tenant: tenant.id, name: nil, capabilities: [:tools], tools: tools], opts)
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp charging_tool(counter) do
    %Tool{
      name: "charge_card",
      description: "takes money",
      input_schema: %{},
      side_effect?: true,
      handler: fn _ ->
        Agent.update(counter, &(&1 + 1))
        {:ok, "charged"}
      end
    }
  end

  defp wait_for(event, timeout \\ 5000) do
    receive do
      {^event, payload} -> payload
    after
      timeout -> flunk("Did not receive #{event} within #{timeout}ms")
    end
  end

  test "a worker's side-effecting tool gets a key, and the result carries it back", %{tenant: tenant, agent: agent} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    start_worker(tenant, [charging_tool(counter)])

    LLM.set_responses([
      %{content: [%{"type" => "tool_use", "id" => "call_1", "name" => "charge_card", "input" => %{}}], stop_reason: "tool_use"},
      %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
    ])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    {:ok, run_id} = AgentRegistry.send_message(tenant.id, agent.id, "charge it")
    wait_for(:completed)

    events = Runs.list_events(run_id)
    call = Enum.find(events, &(&1.event_type == "tool_call"))
    result = Enum.find(events, &(&1.event_type == "tool_result"))

    # `side_effect` is the worker's declaration about its own tool. Reading it
    # from the agent def instead — which is what core used to do — meant every
    # worker tool looked side-effect-free and no key was ever issued.
    assert call.payload["side_effect"] == true
    assert call.payload["idempotency_key"] == Idempotency.key(run_id, call.payload["step"], "call_1", "charge_card")
    assert result.payload["idempotency_key"] == call.payload["idempotency_key"]
  end

  test "the same call re-dispatched after a crash is not charged twice", %{tenant: tenant, agent: agent} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    worker = start_worker(tenant, [charging_tool(counter)])

    {:ok, run} =
      Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "charge it"},
        status: "running"
      })

    key = Idempotency.key(run.id, 1, "call_1", "charge_card")

    # The log as a crash left it: the call is on record, the result is not.
    # Replay will find the call unanswered and re-dispatch it.
    Runs.append_event(run, %{event_type: "run_started", source: "system"})

    Runs.append_event(run, %{
      event_type: "llm_response",
      source: "system",
      payload: %{
        "content" => "",
        "tool_calls" => [%{"id" => "call_1", "name" => "charge_card", "arguments" => %{}}],
        "finish_reason" => "tool_call",
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "tool_call",
      source: "system",
      payload: %{
        "tool_call_id" => "call_1",
        "name" => "charge_card",
        "arguments" => %{},
        "step" => 1,
        "side_effect" => true,
        "idempotency_key" => key
      }
    })

    # The worker did the work before core went down; only it knows that.
    send(worker, {:remember, key, {:ok, "charged"}})

    LLM.set_responses([%{content: [%{"type" => "text", "text" => "all set"}], stop_reason: "end_turn"}])

    {:ok, _pid} =
      AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id, resume_run_id: run.id)

    Process.sleep(400)

    assert Agent.get(counter, & &1) == 0, "the card was charged a second time"

    events = Runs.list_events(run.id)
    duplicate = Enum.find(events, &(&1.event_type == "tool_duplicate"))

    assert duplicate.payload["idempotency_key"] == key
    assert duplicate.payload["resolution"] == "reused_worker_result"
    assert duplicate.payload["tool_call_id"] == "call_1"
    # Nothing to point at: the reason the call was re-dispatched is that the
    # first result never reached the log.
    refute duplicate.payload["original_event_sequence"]

    # And the model still gets its answer — a duplicate is a result, not a gap.
    result = Enum.find(events, &(&1.event_type == "tool_result"))
    assert result.payload["content"] == "charged"
    assert Runs.get_run!(run.id).status == "completed"
  end

  test "when the earlier result is in the log, the duplicate points at it", %{tenant: tenant, agent: agent} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    worker = start_worker(tenant, [charging_tool(counter)])

    {:ok, run} =
      Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "charge it"},
        status: "running"
      })

    key = Idempotency.key(run.id, 1, "call_1", "charge_card")

    Runs.append_event(run, %{event_type: "run_started", source: "system"})

    {:ok, original} =
      Runs.append_event(run, %{
        event_type: "tool_result",
        source: "worker",
        payload: %{
          "tool_call_id" => "call_0",
          "name" => "charge_card",
          "content" => "charged",
          "is_error" => false,
          "step" => 1,
          "idempotency_key" => key
        }
      })

    Runs.append_event(run, %{
      event_type: "llm_response",
      source: "system",
      payload: %{
        "content" => "",
        "tool_calls" => [%{"id" => "call_1", "name" => "charge_card", "arguments" => %{}}],
        "finish_reason" => "tool_call",
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "tool_call",
      source: "system",
      payload: %{"tool_call_id" => "call_1", "name" => "charge_card", "arguments" => %{}, "step" => 1, "idempotency_key" => key}
    })

    send(worker, {:remember, key, {:ok, "charged"}})
    LLM.set_responses([%{content: [%{"type" => "text", "text" => "all set"}], stop_reason: "end_turn"}])

    {:ok, _pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id, resume_run_id: run.id)
    Process.sleep(400)

    duplicate = Enum.find(Runs.list_events(run.id), &(&1.event_type == "tool_duplicate"))
    assert duplicate.payload["original_event_sequence"] == original.sequence
  end
end
