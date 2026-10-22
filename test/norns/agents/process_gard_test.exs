defmodule Norns.Agents.ProcessGardTest do
  use Norns.DataCase, async: false

  alias Norns.{Gards, Runs}
  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.Agents.Registry, as: AgentRegistry
  alias Norns.TestWorker.LLM
  alias Norns.Runtime.Events
  alias Norns.TestWorker.Tool

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    {:ok, gard} = Gards.create_gard(%{tenant_id: tenant.id, name: "workspace"})
    :ok = Gards.claim(tenant.id, gard.id, gard.claim_token)

    %{tenant: tenant, agent: agent, gard: gard}
  end

  defp tool(name, result) do
    %Tool{
      name: name,
      description: name,
      input_schema: %{},
      handler: fn _ -> {:ok, result} end
    }
  end

  defp start_worker(tenant, opts) do
    {:ok, pid} = Norns.TestWorker.start_link(Keyword.merge([tenant: tenant.id, name: nil, capabilities: [:tools]], opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end

  defp wait_for(event, timeout \\ 5000) do
    receive do
      {^event, payload} -> payload
    after
      timeout -> flunk("Did not receive #{event} within #{timeout}ms")
    end
  end

  test "a gard-bound run uses its gard's tools and the no-gard workers' tools, each on its own worker",
       %{tenant: tenant, agent: agent, gard: gard} do
    # Gard workers are LLM-capable, like a real gard deployment: LLM
    # dispatch is gard-strict, so the gard's own worker serves its runs.
    # The no-gard worker is a tenant-wide service — Fulla's confirm cards,
    # timers and people tools — that a run in a gard still needs to reach.
    # Both serve `read_file`; the gard's copy is the one the run must get.
    start_worker(tenant,
      worker_id: "gard-worker",
      gard: gard.id,
      capabilities: [:llm, :tools],
      tools: [tool("read_file", "gard file contents")]
    )

    start_worker(tenant,
      worker_id: "plain-worker",
      tools: [tool("read_file", "plain file contents"), tool("send_card", "card sent")]
    )

    {:ok, other_gard} = Gards.create_gard(%{tenant_id: tenant.id, name: "elsewhere"})
    start_worker(tenant, worker_id: "other-gard-worker", gard: other_gard.id, tools: [tool("other_tool", "x")])

    LLM.set_responses([
      %{
        content: [
          %{"type" => "tool_use", "id" => "call_1", "name" => "read_file", "input" => %{"path" => "x"}},
          %{"type" => "tool_use", "id" => "call_2", "name" => "send_card", "input" => %{}}
        ],
        stop_reason: "tool_use"
      },
      %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
    ])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

    {:ok, run_id} =
      AgentRegistry.send_message(tenant.id, agent.id, "read the file", gard_id: gard.id)

    wait_for(:completed)

    run = Runs.get_run!(run_id)
    assert run.gard_id == gard.id

    events = Runs.list_events(run.id)

    request = Enum.find(events, &(&1.event_type == "llm_request"))
    assert "read_file" in request.payload["tools"]
    assert "send_card" in request.payload["tools"]
    refute "other_tool" in request.payload["tools"]

    results = events |> Enum.filter(&(&1.event_type == "tool_result")) |> Map.new(&{&1.payload["name"], &1.payload["content"]})
    assert results == %{"read_file" => "gard file contents", "send_card" => "card sent"}
  end

  test "a no-gard run sees only no-gard tools", %{tenant: tenant, agent: agent, gard: gard} do
    start_worker(tenant, worker_id: "gard-worker", gard: gard.id, tools: [tool("read_file", "x")])
    start_worker(tenant, worker_id: "plain-worker", tools: [tool("plain_tool", "plain result")])

    LLM.set_responses([
      %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
    ])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    {:ok, run_id} = AgentRegistry.send_message(tenant.id, agent.id, "hello")
    wait_for(:completed)

    request = Enum.find(Runs.list_events(run_id), &(&1.event_type == "llm_request"))
    assert "plain_tool" in request.payload["tools"]
    refute "read_file" in request.payload["tools"]
  end

  test "a resumed run keeps its gard affinity", %{tenant: tenant, agent: agent, gard: gard} do
    start_worker(tenant,
      worker_id: "gard-worker",
      gard: gard.id,
      capabilities: [:llm, :tools],
      tools: [tool("read_file", "x")]
    )

    {:ok, run} =
      Runs.create_run(%{
        tenant_id: tenant.id,
        agent_id: agent.id,
        trigger_type: "message",
        status: "running",
        input: %{"user_message" => "carry on"},
        gard_id: gard.id
      })

    {:ok, started} = Events.run_started()
    {:ok, _} = Runs.append_event(run, started)

    LLM.set_responses([
      %{content: [%{"type" => "text", "text" => "resumed and done"}], stop_reason: "end_turn"}
    ])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

    {:ok, _pid} =
      AgentProcess.start_link(
        agent_id: agent.id,
        tenant_id: tenant.id,
        resume_run_id: run.id,
        conversation_key: "resume-test"
      )

    wait_for(:completed)

    request = Enum.find(Runs.list_events(run.id), &(&1.event_type == "llm_request"))
    # The resumed run still advertises its gard's tools — affinity survived.
    assert "read_file" in request.payload["tools"]
  end

  test "a child launched from a gard-bound run inherits the gard", %{tenant: tenant, agent: agent, gard: gard} do
    child_agent = create_agent(tenant, %{name: "child-#{System.unique_integer([:positive])}"})

    # Parent and child are both gard-bound, so both need the gard's
    # worker for LLM — the no-gard default worker no longer serves them.
    start_worker(tenant, worker_id: "gard-worker", gard: gard.id, capabilities: [:llm, :tools])

    LLM.set_responses([
      # Parent launches the child
      %{
        content: [
          %{
            "type" => "tool_use",
            "id" => "call_launch",
            "name" => "launch_agent",
            "input" => %{"agent_name" => child_agent.name, "message" => "do the subtask"}
          }
        ],
        stop_reason: "tool_use"
      },
      # Child completes immediately
      %{content: [%{"type" => "text", "text" => "child done"}], stop_reason: "end_turn"},
      # Parent wraps up
      %{content: [%{"type" => "text", "text" => "parent done"}], stop_reason: "end_turn"}
    ])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

    {:ok, _run_id} =
      AgentRegistry.send_message(tenant.id, agent.id, "delegate this", gard_id: gard.id)

    wait_for(:completed)

    child_run =
      Runs.list_runs(child_agent.id)
      |> List.first()

    assert child_run != nil
    assert child_run.gard_id == gard.id
  end
end
