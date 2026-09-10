defmodule Norns.Agents.ProcessCompactionTest do
  @moduledoc """
  `context_policy` compaction: once an LLM response reports `compact_at` input
  tokens, the older history is folded into a summary by an LLM task the
  worker serves, and the run continues on the summary plus the last `keep`
  messages. Core stores the summary without reading it.
  """

  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.{Conversations, Runs}
  alias Norns.LLM.Fake
  alias Norns.Runtime.EventValidator

  @policy %{"compact_at" => 50, "keep" => 2}

  setup do
    tenant = create_tenant()

    agent =
      create_agent(tenant, %{
        model_config: %{"mode" => "conversation", "context_strategy" => "none", "context_policy" => @policy}
      })

    %{tenant: tenant, agent: agent}
  end

  defp tool_use(query, usage) do
    %{
      content: [%{"type" => "tool_use", "id" => "call_#{query}", "name" => "web_search", "input" => %{"query" => query}}],
      stop_reason: "tool_use",
      usage: usage
    }
  end

  defp text(t), do: %{content: [%{"type" => "text", "text" => t}], stop_reason: "end_turn"}

  defp run_to_completion(pid, agent, message) do
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    {:ok, run_id} = AgentProcess.send_message(pid, message)

    receive do
      {:completed, %{run_id: ^run_id}} -> run_id
      {:error, payload} -> flunk("run failed: #{inspect(payload)}")
    after
      5_000 -> flunk("run did not complete")
    end
  end

  defp events(run_id, type), do: run_id |> Runs.list_events() |> Enum.filter(&(&1.event_type == type))

  describe "compaction" do
    test "folds the older history into a summary and continues on it", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        tool_use("a", %{input_tokens: 100, output_tokens: 5}),
        text("SUMMARY: searched a"),
        text("Done.")
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      run_id = run_to_completion(pid, agent, "Search for a")

      # The event: what was folded, what stayed, the summary as content.
      assert [compacted] = events(run_id, "context_compacted")
      assert %{"dropped" => 1, "kept" => 2, "summary" => "SUMMARY: searched a", "step" => 1} = compacted.payload
      assert %{"input_tokens" => 10, "output_tokens" => 20} = compacted.payload["usage"]

      # A checkpoint right after it carries the summary.
      checkpoint = run_id |> events("checkpoint_saved") |> Enum.find(&(&1.sequence > compacted.sequence))
      assert checkpoint.payload["summary"] == "SUMMARY: searched a"
      assert length(checkpoint.payload["messages"]) == 2

      # The next LLM request goes out on the kept tail plus the summary.
      [_first, second] = events(run_id, "llm_request")
      assert second.payload["summary"] == "SUMMARY: searched a"
      assert second.payload["message_count"] == 2
      assert [%{"role" => "assistant"}, %{"role" => "tool"}] = second.payload["messages"]

      # The worker wrote the prose: the compaction call carried the def's prompt
      # and the folded history plus an instruction; the following call carried
      # the summary in the composed prompt.
      [_step1, compaction_call, step2] = Fake.calls()
      assert compaction_call.system_prompt == agent.system_prompt
      assert compaction_call.opts == []
      assert %{"role" => "user"} = List.last(compaction_call.messages)
      assert step2.system_prompt =~ "Summary of earlier conversation: SUMMARY: searched a"

      # Tokens: the compaction call counts.
      run = Runs.get_run!(run_id)
      assert run.input_tokens == 100 + 10 + 10

      # The conversation persists the summary and the compacted history.
      {:ok, conversation} = Conversations.find_or_create_conversation(agent.id, tenant.id, "default")
      assert conversation.summary == "SUMMARY: searched a"
      assert length(conversation.messages) == 3

      # The next run in the conversation starts from the summary.
      Fake.set_responses([text("Still here.")])
      run2 = run_to_completion(pid, agent, "And now?")
      [request] = events(run2, "llm_request")
      assert request.payload["summary"] == "SUMMARY: searched a"
      assert request.payload["message_count"] == 4
    end

    test "does nothing under the threshold", %{tenant: tenant, agent: agent} do
      Fake.set_responses([tool_use("a", %{input_tokens: 49, output_tokens: 5}), text("Done.")])
      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      run_id = run_to_completion(pid, agent, "Search for a")

      assert events(run_id, "context_compacted") == []
      assert length(Fake.calls()) == 2
    end

    test "continues uncompacted when the worker returns no summary", %{tenant: tenant, agent: agent} do
      Fake.set_responses([tool_use("a", %{input_tokens: 100, output_tokens: 5}), text(""), text("Done.")])
      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      run_id = run_to_completion(pid, agent, "Search for a")

      assert events(run_id, "context_compacted") == []
      assert Runs.get_run!(run_id).status == "completed"
      [_first, second] = events(run_id, "llm_request")
      assert second.payload["message_count"] == 3
      assert second.payload["summary"] == nil
    end

    test "the summary can be an opaque block" do
      block = %{"$enc" => "v1", "kid" => "k", "n" => "n", "ct" => "c"}

      assert {:ok, _} =
               EventValidator.validate(%{
                 event_type: "context_compacted",
                 payload: %{"step" => 1, "dropped" => 3, "kept" => 2, "summary" => block}
               })

      assert {:ok, _} =
               EventValidator.validate(%{
                 event_type: "checkpoint_saved",
                 payload: %{"messages" => [], "step" => 1, "summary" => block}
               })

      assert {:error, _} =
               EventValidator.validate(%{
                 event_type: "context_compacted",
                 payload: %{"step" => 1, "dropped" => 3, "kept" => 2, "summary" => 42}
               })
    end
  end

  describe "replay" do
    defp append!(run, type, payload) do
      {:ok, _} = Runs.append_event(run, %{event_type: type, source: "system", payload: payload})
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
        summary: nil,
        test_pid: nil
      }
    end

    test "a context_compacted event drops the folded prefix and restores the summary", %{tenant: tenant, agent: agent} do
      {:ok, run} =
        Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{"user_message" => "go"}, status: "running"})

      append!(run, "run_started", %{})
      append!(run, "llm_response", %{"content" => "", "tool_calls" => [%{"id" => "c1", "name" => "web_search", "arguments" => %{}}], "finish_reason" => "tool_call", "usage" => %{"input_tokens" => 100, "output_tokens" => 1}, "step" => 1})
      append!(run, "tool_call", %{"tool_call_id" => "c1", "name" => "web_search", "arguments" => %{}, "step" => 1})
      append!(run, "tool_result", %{"tool_call_id" => "c1", "name" => "web_search", "content" => "r1", "is_error" => false, "step" => 1})
      append!(run, "context_compacted", %{"step" => 1, "dropped" => 2, "kept" => 1, "summary" => "S1", "usage" => %{"input_tokens" => 7, "output_tokens" => 3}})
      # crashed before the post-compaction checkpoint landed
      append!(run, "llm_response", %{"content" => "", "tool_calls" => [%{"id" => "c2", "name" => "web_search", "arguments" => %{}}], "finish_reason" => "tool_call", "usage" => %{"input_tokens" => 10, "output_tokens" => 1}, "step" => 2})
      append!(run, "tool_call", %{"tool_call_id" => "c2", "name" => "web_search", "arguments" => %{}, "step" => 2})

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state(tenant, agent))

      assert rebuilt.summary == "S1"
      assert [%{role: "tool", content: "r1"}, %{role: "assistant"}] = rebuilt.messages
      assert {:resume_tools, [%{"id" => "c2"}]} = rebuilt.resume_action
      assert rebuilt.input_tokens == 117
    end

    test "a checkpoint restores the summary it carries", %{tenant: tenant, agent: agent} do
      {:ok, run} =
        Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{"user_message" => "go"}, status: "running"})

      append!(run, "run_started", %{})
      append!(run, "checkpoint_saved", %{"messages" => [%{"role" => "user", "content" => "tail"}], "step" => 3, "summary" => "S2"})
      append!(run, "llm_response", %{"content" => "ok", "finish_reason" => "stop", "usage" => %{}, "step" => 4})

      {:ok, rebuilt} = AgentProcess.rebuild_state(run.id, base_state(tenant, agent))
      assert rebuilt.summary == "S2"
      assert [%{role: "user", content: "tail"}, %{role: "assistant", content: "ok"}] = rebuilt.messages
    end
  end
end
