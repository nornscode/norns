defmodule Norns.Agents.ProcessSubagentRecoveryTest do
  @moduledoc """
  What happens to an in-flight `launch_agent` when the parent crashes.

  The child is the expensive half of a delegation, so resume has to pick up the
  run the parent's own event log points at rather than starting a fresh one.
  """

  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake
  alias Norns.Runs
  alias Norns.Runs.Run

  setup do
    tenant = create_tenant()
    parent = create_agent(tenant, %{name: "parent-agent"})
    child = create_agent(tenant, %{name: "child-agent"})

    %{tenant: tenant, parent: parent, child: child}
  end

  # A parent that dispatched `launch_agent` and died before the result landed.
  # `:checkpoint` reproduces the `:every_step` policy, where a checkpoint lands
  # between the llm_response and the launch and clears the pending call.
  defp crashed_parent_run(tenant, parent, child_run_id, opts \\ []) do
    tool_calls = [
      %{
        "id" => "call_launch",
        "name" => "launch_agent",
        "arguments" => %{"agent_name" => "child-agent", "message" => "Do the thing"}
      }
    ]

    {:ok, run} =
      Runs.create_run(%{
        agent_id: parent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{"user_message" => "Delegate this"},
        status: "running"
      })

    Runs.append_event(run, %{event_type: "run_started", source: "system"})

    Runs.append_event(run, %{
      event_type: "llm_response",
      source: "system",
      payload: %{
        "content" => "",
        "tool_calls" => tool_calls,
        "finish_reason" => "tool_call",
        "step" => 1,
        "usage" => %{}
      }
    })

    if Keyword.get(opts, :checkpoint, false) do
      Runs.append_event(run, %{
        event_type: "checkpoint_saved",
        source: "system",
        payload: %{
          "messages" => [
            %{"role" => "user", "content" => "Delegate this"},
            %{"role" => "assistant", "content" => "", "tool_calls" => tool_calls}
          ],
          "step" => 1
        }
      })
    end

    Runs.append_event(run, %{
      event_type: "tool_call",
      source: "system",
      payload: %{
        "tool_call_id" => "call_launch",
        "name" => "launch_agent",
        "arguments" => %{"agent_name" => "child-agent", "message" => "Do the thing"},
        "step" => 1
      }
    })

    Runs.append_event(run, %{
      event_type: "subagent_launched",
      source: "system",
      payload: %{
        "tool_call_id" => "call_launch",
        "child_agent_name" => "child-agent",
        "child_run_id" => to_string(child_run_id),
        "step" => 1
      }
    })

    run
  end

  defp child_run(tenant, child, parent_run_id, attrs) do
    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{
            agent_id: child.id,
            tenant_id: tenant.id,
            trigger_type: "message",
            input: %{"user_message" => "Do the thing"},
            status: "running",
            parent_run_id: parent_run_id,
            depth: 1
          },
          attrs
        )
      )

    run
  end

  defp run_ids_for(agent), do: Repo.all(from r in Run, where: r.agent_id == ^agent.id, select: r.id)

  defp launch_results(run_id) do
    run_id
    |> Runs.list_events()
    |> Enum.filter(&(&1.event_type == "tool_result" && &1.payload["tool_call_id"] == "call_launch"))
  end

  defp resume(parent, tenant, run) do
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{parent.id}")

    {:ok, pid} =
      AgentProcess.start_link(agent_id: parent.id, tenant_id: tenant.id, resume_run_id: run.id)

    pid
  end

  describe "resuming a parent that was awaiting a sub-agent" do
    test "adopts a child that already finished", ctx do
      %{tenant: tenant, parent: parent, child: child} = ctx

      done = child_run(tenant, child, nil, %{status: "completed", output: "42"})
      parent_run = crashed_parent_run(tenant, parent, done.id)

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "The child said 42."}], stop_reason: "end_turn"}
      ])

      resume(parent, tenant, parent_run)
      assert_receive {:completed, _}, 5000

      # The whole point: the finished child's work is reused, not repeated.
      assert run_ids_for(child) == [done.id]

      assert [result] = launch_results(parent_run.id)
      refute result.payload["is_error"]

      assert result.payload["kind"] == "subagent_completed"
      assert result.payload["content"] == "42"
      assert %{"run_id" => run_id, "status" => "completed"} = result.payload["data"]

      assert run_id == done.id
    end

    test "adopts a child that already failed, as an error result", ctx do
      %{tenant: tenant, parent: parent, child: child} = ctx

      dead =
        child_run(tenant, child, nil, %{
          status: "failed",
          failure_metadata: %{"error" => "upstream exploded", "error_class" => "internal"}
        })

      parent_run = crashed_parent_run(tenant, parent, dead.id)

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "The child failed."}], stop_reason: "end_turn"}
      ])

      resume(parent, tenant, parent_run)
      assert_receive {:completed, _}, 5000

      assert run_ids_for(child) == [dead.id]

      assert [result] = launch_results(parent_run.id)
      assert result.payload["is_error"]

      assert result.payload["kind"] == "subagent_failed"
      assert result.payload["data"]["status"] == "failed"
      assert result.payload["content"] == "upstream exploded"
    end

    test "waits for a child that is still in flight, and resumes it", ctx do
      %{tenant: tenant, parent: parent, child: child} = ctx

      # Parked on ask_human and with no live process — the case where nothing
      # else would ever restart the child, so the parent has to.
      pending = child_run(tenant, child, nil, %{status: "waiting"})
      Runs.append_event(pending, %{event_type: "run_started", source: "system"})

      Runs.append_event(pending, %{
        event_type: "llm_response",
        source: "system",
        payload: %{
          "content" => "",
          "tool_calls" => [
            %{"id" => "call_ask", "name" => "ask_human", "arguments" => %{"question" => "Which one?"}}
          ],
          "finish_reason" => "tool_call",
          "step" => 1,
          "usage" => %{}
        }
      })

      Runs.append_event(pending, %{
        event_type: "waiting_for_user",
        source: "system",
        payload: %{"tool_call_id" => "call_ask", "question" => "Which one?", "step" => 1}
      })

      parent_run = crashed_parent_run(tenant, parent, pending.id)

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{child.id}")
      parent_pid = resume(parent, tenant, parent_run)

      # The parent brought the child back up rather than waiting out the task
      # timeout for a result no process was going to produce.
      assert_receive {:waiting_for_user, %{question: "Which one?"}}, 5000
      assert AgentProcess.get_state(parent_pid).status == :awaiting_tools
      assert run_ids_for(child) == [pending.id]

      # Answering the child drives the parent the rest of the way.
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "The second one."}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "Child chose the second one."}], stop_reason: "end_turn"}
      ])

      assert {:ok, child_pid} = Norns.Agents.Registry.lookup(tenant.id, child.id, "default")
      assert :ok = AgentProcess.reply_to_human(child_pid, "the second one")

      # Both topics are subscribed here, so pin the parent's completion.
      parent_id = parent.id
      assert_receive {:completed, %{agent_id: ^parent_id}}, 5000

      assert [result] = launch_results(parent_run.id)
      assert result.payload["kind"] == "subagent_completed"
      assert %{"run_id" => run_id, "status" => "completed"} = result.payload["data"]
      assert run_id == pending.id
    end

    test "reattaches once, not twice, under the default checkpoint policy", ctx do
      %{tenant: tenant, parent: parent, child: child} = ctx

      # With :on_tool_call the llm_response survives replay, so the pending
      # launch is already there. subagent_launched used to append a second copy
      # of it, and both copies got dispatched.
      done = child_run(tenant, child, nil, %{status: "completed", output: "once"})
      parent_run = crashed_parent_run(tenant, parent, done.id)

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "Done."}], stop_reason: "end_turn"}
      ])

      resume(parent, tenant, parent_run)
      assert_receive {:completed, _}, 5000

      assert length(launch_results(parent_run.id)) == 1
      assert run_ids_for(child) == [done.id]
    end

    test "reattaches when a checkpoint cleared the pending call", ctx do
      %{tenant: tenant, parent: parent, child: child} = ctx

      # Under :every_step the checkpoint lands before the launch, so replay has
      # to rebuild the pending call from subagent_launched alone.
      done = child_run(tenant, child, nil, %{status: "completed", output: "still adopted"})
      parent_run = crashed_parent_run(tenant, parent, done.id, checkpoint: true)

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "Done."}], stop_reason: "end_turn"}
      ])

      resume(parent, tenant, parent_run)
      assert_receive {:completed, _}, 5000

      assert run_ids_for(child) == [done.id]

      assert [result] = launch_results(parent_run.id)
      assert result.payload["kind"] == "subagent_completed"
      assert result.payload["content"] == "still adopted"
    end

    test "reports a vanished child rather than silently relaunching", ctx do
      %{tenant: tenant, parent: parent, child: child} = ctx

      parent_run = crashed_parent_run(tenant, parent, 999_999)

      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "I lost the child."}], stop_reason: "end_turn"}
      ])

      resume(parent, tenant, parent_run)
      assert_receive {:completed, _}, 5000

      # Relaunching would look like recovery while quietly doubling the bill.
      assert run_ids_for(child) == []

      assert [result] = launch_results(parent_run.id)
      assert result.payload["is_error"]
      assert result.payload["kind"] == "subagent_missing"
      assert result.payload["data"]["run_id"] == 999_999
    end
  end

  describe "concurrent launches of the same agent" do
    test "resolve independently instead of colliding", ctx do
      %{tenant: tenant, parent: parent, child: child} = ctx

      # pending_subagents used to be keyed by child agent id, so the second
      # launch overwrote the first and one call never got a result.
      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_a",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "child-agent", "message" => "first"}
            },
            %{
              "type" => "tool_use",
              "id" => "call_b",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "child-agent", "message" => "second"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "child done"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "child done"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "Both finished."}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{parent.id}")
      {:ok, pid} = AgentProcess.start_link(agent_id: parent.id, tenant_id: tenant.id)
      AgentProcess.send_message(pid, "Delegate twice")

      assert_receive {:completed, %{agent_id: parent_agent_id}}, 10_000
      assert parent_agent_id == parent.id

      parent_run_id = AgentProcess.get_state(pid).run_id

      results =
        parent_run_id
        |> Runs.list_events()
        |> Enum.filter(&(&1.event_type == "tool_result" && &1.payload["name"] == "launch_agent"))

      assert length(results) == 2
      assert Enum.sort(Enum.map(results, & &1.payload["tool_call_id"])) == ["call_a", "call_b"]

      # Two children ran, and each call reports the run that actually served it.
      reported = results |> Enum.map(& &1.payload["data"]["run_id"]) |> Enum.sort()
      assert length(Enum.uniq(reported)) == 2
      assert reported == Enum.sort(run_ids_for(child))
    end
  end
end
