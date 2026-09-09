defmodule Norns.Runtime.OpaqueContentTest do
  @moduledoc """
  The opaque-content conformance suite (`Norns.Runtime.Content`).

  Every content position is filled with a block core cannot read — the shape
  a worker holding an encryption key would send — and the state machine has
  to store it, replay it, resume from it, and complete a run on it without
  looking inside. If a future change makes core branch on content, it fails
  here first.
  """

  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake
  alias Norns.Runs
  alias Norns.Runtime.{Content, EventValidator}
  alias Norns.Tools.Tool

  # What a worker with a key sends in a content position. Random ciphertext:
  # nothing in core may make sense of it.
  defp block do
    %{
      "$enc" => "v1",
      "kid" => "k_test",
      "n" => Base.encode64(:crypto.strong_rand_bytes(24)),
      "ct" => Base.encode64(:crypto.strong_rand_bytes(48))
    }
  end

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    %{tenant: tenant, agent: agent}
  end

  describe "the validator" do
    test "accepts an opaque block in every content position" do
      b = block()

      payloads = %{
        "llm_request" => %{"step" => 1, "message_count" => 1, "messages" => [], "system_prompt" => b, "summary" => b},
        "llm_response" => %{"step" => 1, "content" => b, "finish_reason" => "stop"},
        "tool_call" => %{"tool_call_id" => "c1", "name" => "t", "arguments" => b, "step" => 1},
        "tool_result" => %{"tool_call_id" => "c1", "name" => "t", "content" => b, "is_error" => false, "step" => 1},
        "run_completed" => %{"output" => b},
        "run_failed" => %{"error" => b, "error_class" => "internal", "error_code" => "x", "retry_decision" => "terminal"},
        "retry" => %{"error" => b, "attempt" => 1, "delay_ms" => 1, "step" => 1, "error_class" => "internal", "error_code" => "x", "retry_decision" => "retry"},
        "waiting_for_user" => %{"question" => b, "tool_call_id" => "c1", "step" => 1},
        "user_response" => %{"content" => b, "tool_call_id" => "c1", "step" => 1},
        "subagent_launched" => %{"tool_call_id" => "c1", "child_agent_name" => "kid", "child_run_id" => "9", "step" => 1, "context" => b}
      }

      for {type, payload} <- payloads do
        fields = EventValidator.content_fields(type)
        assert fields != [], "#{type} declares no content fields"
        assert Enum.all?(fields, &Map.has_key?(payload, &1)), "#{type} payload misses a content field"
        assert {:ok, _} = EventValidator.validate(%{event_type: type, payload: payload}), "#{type} rejected an opaque block"
      end
    end

    test "content may be empty — whether it is empty is not core's call" do
      assert {:ok, _} = EventValidator.validate(%{event_type: "run_completed", payload: %{"output" => ""}})
      assert {:ok, _} = EventValidator.validate(%{event_type: "waiting_for_user", payload: %{"question" => "", "tool_call_id" => "c1", "step" => 1}})
    end

    test "rejects a content position that is neither text, a map, nor a block" do
      assert {:error, _} = EventValidator.validate(%{event_type: "run_completed", payload: %{"output" => 42}})
    end
  end

  describe "replay" do
    test "rebuilds state from a log whose every content position is opaque", %{tenant: tenant, agent: agent} do
      user = block()
      say = block()
      args = block()
      result = block()
      args2 = block()

      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"user_message" => user},
          status: "running"
        })

      append!(run, "run_started", %{})
      append!(run, "llm_response", %{"content" => say, "tool_calls" => [%{"id" => "c1", "name" => "vault", "arguments" => args}], "finish_reason" => "tool_call", "usage" => %{"input_tokens" => 1, "output_tokens" => 1}, "step" => 1})
      append!(run, "tool_call", %{"tool_call_id" => "c1", "name" => "vault", "arguments" => args, "step" => 1})
      append!(run, "tool_result", %{"tool_call_id" => "c1", "name" => "vault", "content" => result, "is_error" => false, "step" => 1})
      append!(run, "llm_response", %{"content" => "", "tool_calls" => [%{"id" => "c2", "name" => "vault", "arguments" => args2}], "finish_reason" => "tool_call", "usage" => %{"input_tokens" => 1, "output_tokens" => 1}, "step" => 2})
      append!(run, "tool_call", %{"tool_call_id" => "c2", "name" => "vault", "arguments" => args2, "step" => 2})
      # crashed here — c2 never returned

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state(tenant, agent))

      assert rebuilt.step == 2
      assert [%{role: "user", content: ^user}, %{role: "assistant", content: ^say}, %{role: "tool", content: ^result}, %{role: "assistant"}] = rebuilt.messages
      assert {:resume_tools, [%{"id" => "c2", "arguments" => ^args2}]} = rebuilt.resume_action
    end

    test "a checkpoint of opaque and kinded messages replays verbatim", %{tenant: tenant, agent: agent} do
      user = block()
      inherited = block()
      later = block()

      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"user_message" => user},
          status: "running"
        })

      append!(run, "run_started", %{})

      append!(run, "checkpoint_saved", %{
        "messages" => [
          %{"role" => "user", "kind" => "inherited_context", "content" => inherited},
          %{"role" => "user", "content" => user},
          %{"role" => "assistant", "content" => block(), "tool_calls" => [%{"id" => "c1", "name" => "wait", "arguments" => %{"seconds" => 1}}]}
        ],
        "step" => 1
      })

      append!(run, "tool_result", %{"tool_call_id" => "c1", "name" => "wait", "content" => "", "kind" => "timer_completed", "data" => %{}, "is_error" => false, "step" => 1})
      append!(run, "llm_response", %{"content" => later, "finish_reason" => "stop", "usage" => %{"input_tokens" => 1, "output_tokens" => 1}, "step" => 2})

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state(tenant, agent))

      assert [
               %{role: "user", kind: "inherited_context", content: ^inherited},
               %{role: "user", content: ^user},
               %{role: "assistant"},
               %{role: "tool", kind: "timer_completed", content: ""},
               %{role: "assistant", content: ^later}
             ] = rebuilt.messages

      assert rebuilt.resume_action == :llm_loop
    end
  end

  describe "a live run" do
    test "completes with every content position stored and forwarded verbatim", %{tenant: tenant, agent: agent} do
      user = block()
      args = block()
      result = block()

      vault = %Tool{
        name: "vault",
        description: "returns ciphertext",
        input_schema: %{},
        handler: fn _input -> {:ok, result} end
      }

      {:ok, _worker} = Norns.TestWorker.start_link(tools: [vault], name: nil, worker_id: "opaque-worker")

      Fake.set_responses([
        %{content: [%{"type" => "tool_use", "id" => "c1", "name" => "vault", "input" => args}], stop_reason: "tool_use"},
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id, tools: [vault])
      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, run_id} = AgentProcess.send_message(pid, user)

      assert_receive {:completed, %{run_id: ^run_id}}, 5000

      run = Runs.get_run!(run_id)
      assert run.status == "completed"
      assert run.output == "done"
      assert run.input["user_message"] == user

      events = Runs.list_events(run_id)
      assert %{payload: %{"arguments" => ^args}} = Enum.find(events, &(&1.event_type == "tool_call"))
      assert %{payload: %{"content" => ^result}} = Enum.find(events, &(&1.event_type == "tool_result"))

      # The worker saw exactly what was sent — no rendering, no truncation.
      [first, second] = Fake.calls()
      assert [%{"role" => "user", "content" => ^user}] = first.messages
      assert Enum.any?(second.messages, fn m ->
               is_list(m["content"]) and Enum.any?(m["content"], &(&1["type"] == "tool_result" and &1["content"] == result))
             end)
    end

    test "a sub-agent's output reaches the parent as content, its run id as envelope", %{tenant: tenant, agent: agent} do
      child = create_agent(tenant, %{name: "vault-child", purpose: "returns ciphertext"})
      secret = block()

      Fake.set_responses([
        # parent launches the child
        %{content: [%{"type" => "tool_use", "id" => "l1", "name" => "launch_agent", "input" => %{"agent_name" => child.name, "message" => block()}}], stop_reason: "tool_use"},
        # child answers with ciphertext (the Fake speaks Anthropic; a real worker would set final_output)
        %{content: [%{"type" => "text", "text" => Jason.encode!(secret)}], stop_reason: "end_turn"},
        # parent finishes
        %{content: [%{"type" => "text", "text" => "relayed"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, run_id} = AgentProcess.send_message(pid, "go")

      assert_receive {:completed, %{run_id: ^run_id}}, 5000

      launch_result =
        Runs.list_events(run_id)
        |> Enum.find(&(&1.event_type == "tool_result" and &1.payload["name"] == "launch_agent"))

      assert launch_result.payload["kind"] == "subagent_completed"
      assert launch_result.payload["content"] == Jason.encode!(secret)
      assert is_integer(launch_result.payload["data"]["run_id"])
    end

    test "run output may be an opaque block", %{tenant: tenant, agent: agent} do
      # Core stores what the worker reports as final_output — an older worker
      # reports none and the last turn's content stands in.
      output = block()
      Fake.set_responses([%{content: [%{"type" => "text", "text" => Jason.encode!(output)}], stop_reason: "end_turn"}])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, run_id} = AgentProcess.send_message(pid, block())
      assert_receive {:completed, %{run_id: ^run_id}}, 5000

      run = Runs.get_run!(run_id)
      assert Jason.decode!(run.output) == output
      assert Content.to_column(output) == run.output
    end
  end

  defp append!(run, type, payload) do
    {:ok, _} = Runs.append_event(run, %{event_type: type, payload: payload})
  end

  defp base_state(tenant, agent) do
    %{
      agent_id: agent.id,
      tenant_id: tenant.id,
      agent: agent,
      agent_def: Norns.Agents.AgentDef.from_agent(agent, tools: []),
      conversation: nil,
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      pending_llm_task: nil,
      pending_tool_tasks: nil,
      resume_action: nil,
      test_pid: nil
    }
  end
end
