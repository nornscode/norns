defmodule Norns.Agents.ProcessHistoryCacheTest do
  @moduledoc """
  A worker that keeps the history it was last sent gets the change on later
  steps; one that forgot is sent the whole list again at the same step, and
  the run is none the wiser.
  """

  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.Runs
  alias Norns.TestWorker.LLM
  alias Norns.TestWorker.Tool

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)

    tool = %Tool{
      name: "web_search",
      description: "search",
      input_schema: %{},
      handler: fn _ -> {:ok, "r"} end
    }

    {:ok, worker} =
      Norns.TestWorker.start_link(
        tenant: tenant.id,
        name: nil,
        tools: [tool],
        features: [:message_cache],
        observer: self()
      )

    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    %{tenant: tenant, agent: agent, worker: worker}
  end

  defp tool_use(id) do
    %{
      content: [
        %{"type" => "tool_use", "id" => id, "name" => "web_search", "input" => %{"q" => id}}
      ],
      stop_reason: "tool_use"
    }
  end

  defp text(t), do: %{content: [%{"type" => "text", "text" => t}], stop_reason: "end_turn"}

  defp await_completion(run_id) do
    receive do
      {:completed, %{run_id: ^run_id}} -> :ok
      {:error, payload} -> flunk("run failed: #{inspect(payload)}")
    after
      5_000 -> flunk("run did not complete")
    end
  end

  defp request_steps(run_id) do
    run_id
    |> Runs.list_events()
    |> Enum.filter(&(&1.event_type == "llm_request"))
    |> Enum.map(& &1.payload["step"])
  end

  test "later steps carry the change, not the history", %{tenant: tenant, agent: agent} do
    LLM.set_responses([tool_use("c1"), tool_use("c2"), text("Done.")])
    {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
    {:ok, run_id} = AgentProcess.send_message(pid, "go")
    await_completion(run_id)

    assert_receive {:llm_task, %{step: 1, messages: [%{role: "user"}]} = first}
    refute Map.has_key?(first, :messages_delta)

    assert_receive {:llm_task,
                    %{
                      step: 2,
                      messages_delta: %{
                        base_count: 1,
                        drop: 0,
                        append: [%{role: "assistant"}, %{role: "tool"}]
                      }
                    } =
                      second}

    refute Map.has_key?(second, :messages)

    assert_receive {:llm_task,
                    %{step: 3, messages_delta: %{base_count: 3, drop: 0, append: [_, _]}}}

    # The worker rebuilt the history core holds: the second tool's result,
    # which only ever travelled as a delta, reached the model.
    [_, _, third] = LLM.calls()
    assert inspect(third.messages) =~ "c2"
    assert Runs.get_run!(run_id).status == "completed"
  end

  test "a worker that forgot the history is sent it again at the same step, with no retry",
       %{tenant: tenant, agent: agent, worker: worker} do
    LLM.set_responses([tool_use("c1"), tool_use("c2"), text("Done.")])
    {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
    {:ok, run_id} = AgentProcess.send_message(pid, "go")

    assert_receive {:llm_task, %{step: 1, messages: _}}
    assert_receive {:llm_task, %{step: 2, messages_delta: _}}
    # Lands in the worker's mailbox before step 3 can, which needs the
    # step-2 result to travel to core and back.
    send(worker, :forget_history)

    assert_receive {:llm_task, %{step: 3, messages_delta: _}}
    assert_receive {:llm_task, %{step: 3, messages: messages}}
    assert length(messages) == 5

    await_completion(run_id)

    assert request_steps(run_id) == [1, 2, 3, 3]
    refute Enum.any?(Runs.list_events(run_id), &(&1.event_type == "retry"))
    # The miss cost no model call.
    assert length(LLM.calls()) == 3
  end
end
