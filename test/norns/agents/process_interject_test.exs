defmodule Norns.Agents.ProcessInterjectTest do
  @moduledoc """
  A person speaking while the run works (`interject: true`): the message is
  taken into the run under way at its next LLM call, or starts the next run
  if this one ends first, instead of being refused as busy.
  """
  use Norns.DataCase, async: false

  alias Norns.{Conversations, Runs}
  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.Agents.Replay
  alias Norns.TestWorker.LLM
  alias Norns.TestWorker.Tool

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    test = self()

    # Answers only when the test says so, so the run is reliably mid-step.
    gate = %Tool{
      name: "gate",
      description: "waits for the test",
      input_schema: %{},
      handler: fn _ ->
        send(test, {:gate_open, self()})

        receive do
          :go -> {:ok, "gate done"}
        after
          10_000 -> {:error, "never released"}
        end
      end
    }

    {:ok, worker} = Norns.TestWorker.start_link(tenant: tenant.id, name: nil, tools: [gate])
    # The worker is linked to the test process and can die between an
    # alive? check and the stop, so tolerate it being gone.
    on_exit(fn ->
      try do
        GenServer.stop(worker)
      catch
        :exit, _ -> :ok
      end
    end)

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id, conversation_key: "chat")

    %{tenant: tenant, agent: agent, pid: pid}
  end

  defp gate_call(id \\ "call_1"),
    do: %{content: [%{"type" => "tool_use", "id" => id, "name" => "gate", "input" => %{}}], stop_reason: "tool_use"}

  defp text(t), do: %{content: [%{"type" => "text", "text" => t}], stop_reason: "end_turn"}

  defp held_tool do
    assert_receive {:gate_open, tool}, 5000
    tool
  end

  defp conversation_messages(pid) do
    Conversations.get_conversation!(AgentProcess.get_state(pid).conversation_id).messages
    |> Enum.map(fn m -> {m["role"], m["content"]} end)
  end

  test "joins the run under way after the step's tool results", %{agent: agent, pid: pid} do
    LLM.set_responses([gate_call(), text("PRs listed, and bubbo restarted.")])

    {:ok, run_id} = AgentProcess.send_message(pid, "list my draft PRs")
    tool = held_tool()

    assert {:ok, ^run_id} = AgentProcess.send_message(pid, "also restart bubbo", interject: true)
    send(tool, :go)
    assert_receive {:completed, _}, 5000

    assert [_] = Runs.list_runs(agent.id)
    assert Runs.get_run!(run_id).output == "PRs listed, and bubbo restarted."

    assert [
             {"user", "list my draft PRs"},
             {"assistant", _},
             {"tool", "gate done"},
             {"user", "also restart bubbo"},
             {"assistant", "PRs listed, and bubbo restarted."}
           ] = conversation_messages(pid)

    events = Runs.list_events(run_id)
    said = Enum.find(events, &(&1.event_type == "user_message"))
    assert said.payload["content"] == "also restart bubbo"
  end

  test "starts the next run when the run ends before it could be read", %{agent: agent, pid: pid} do
    LLM.set_responses([gate_call(), text("Restarted bubbo.")])

    {:ok, first} = AgentProcess.send_message(pid, "list my draft PRs")
    _tool = held_tool()

    assert {:ok, ^first} = AgentProcess.send_message(pid, "also restart bubbo", interject: true)
    assert {:ok, ^first} = AgentProcess.send_message(pid, "thanks", interject: true)
    # The step never comes back: the run fails with the words unread.
    send(pid, {:task_timeout, :tools})

    assert_receive {:error, _}, 5000
    assert_receive {:completed, _}, 5000

    assert Runs.get_run!(first).status == "failed"
    [next] = Runs.list_runs(agent.id) |> Enum.reject(&(&1.id == first))
    assert next.input["user_message"] == "also restart bubbo"
    assert next.output == "Restarted bubbo."

    assert [{"user", "also restart bubbo"}, {"user", "thanks"}, {"assistant", "Restarted bubbo."}] =
             conversation_messages(pid) |> Enum.take(-3)
  end

  test "a cancel takes what was said into the run with it", %{agent: agent, pid: pid} do
    LLM.set_responses([gate_call()])

    {:ok, run_id} = AgentProcess.send_message(pid, "list my draft PRs")
    _tool = held_tool()

    {:ok, ^run_id} = AgentProcess.send_message(pid, "also restart bubbo", interject: true)
    :ok = AgentProcess.cancel(pid, run_id)
    assert_receive {:error, _}, 5000

    Process.sleep(300)
    assert [_] = Runs.list_runs(agent.id)
  end

  test "without the flag, a busy run still refuses", %{pid: pid} do
    LLM.set_responses([gate_call(), text("done")])

    {:ok, _} = AgentProcess.send_message(pid, "list my draft PRs")
    tool = held_tool()

    assert {:error, :busy} = AgentProcess.send_message(pid, "also restart bubbo")
    send(tool, :go)
    assert_receive {:completed, _}, 5000
  end

  test "a scheduled message is refused even with the flag", %{pid: pid} do
    LLM.set_responses([gate_call(), text("done")])

    {:ok, _} = AgentProcess.send_message(pid, "list my draft PRs")
    tool = held_tool()

    assert {:error, :busy} =
             AgentProcess.send_message(pid, "[scheduled] brief", interject: true, trigger_type: "schedule")

    send(tool, :go)
    assert_receive {:completed, _}, 5000
  end

  describe "replay" do
    setup %{tenant: tenant, agent: agent} do
      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"user_message" => "list my draft PRs"},
          status: "running"
        })

      event = fn type, payload -> {:ok, _} = Runs.append_event(run, %{event_type: type, source: "system", payload: payload}) end

      event.("run_started", %{})

      event.("llm_request", %{
        "step" => 1,
        "message_count" => 1,
        "messages" => [%{"role" => "user", "content" => "list my draft PRs"}]
      })

      event.("llm_response", %{
        "content" => "",
        "tool_calls" => [%{"id" => "call_1", "name" => "gate", "arguments" => %{}}],
        "finish_reason" => "tool_call",
        "step" => 1
      })

      event.("user_message", %{"content" => "also restart bubbo", "step" => 1})
      event.("tool_result", %{"tool_call_id" => "call_1", "name" => "gate", "content" => "gate done", "is_error" => false, "step" => 1})

      %{run: run, event: event}
    end

    test "a crash before the next call keeps what was said, unread", %{run: run} do
      {:ok, state} = Replay.rebuild_state(run.id, %{conversation: nil, messages: [], summary: nil})

      assert state.interjections == ["also restart bubbo"]
      assert List.last(state.messages).role == "tool"
    end

    test "a crash after the next call has it in the history, once", %{run: run, event: event} do
      event.("llm_request", %{"step" => 2, "message_count" => 4})

      {:ok, state} = Replay.rebuild_state(run.id, %{conversation: nil, messages: [], summary: nil})

      assert state.interjections == []
      assert [_, _, %{role: "tool"}, %{role: "user", content: "also restart bubbo"}] = state.messages
    end
  end
end
