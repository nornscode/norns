defmodule Norns.Runs.ForkTest do
  @moduledoc """
  Fork: a new run on the parent's history up to a step, in a fresh
  conversation, optionally with a new message or a def override.
  """

  use Norns.DataCase, async: false

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.{Agents, Conversations, Runs}
  alias Norns.LLM.Fake
  alias Norns.Runs.Fork

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant, %{model_config: %{"mode" => "conversation"}})
    %{tenant: tenant, agent: agent}
  end

  defp tool_use(query) do
    %{
      content: [%{"type" => "tool_use", "id" => "call_#{query}", "name" => "web_search", "input" => %{"query" => query}}],
      stop_reason: "tool_use"
    }
  end

  defp text(t), do: %{content: [%{"type" => "text", "text" => t}], stop_reason: "end_turn"}

  defp await_completion(run_id) do
    receive do
      {:completed, %{run_id: ^run_id}} -> :ok
      {:error, %{run_id: ^run_id} = payload} -> flunk("run failed: #{inspect(payload)}")
    after
      5_000 -> flunk("run #{run_id} did not complete")
    end
  end

  # A parent run with two tool steps and a final answer.
  defp parent_run(tenant, agent) do
    Fake.set_responses([tool_use("a"), tool_use("b"), text("Parent done.")])
    {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    {:ok, run_id} = AgentProcess.send_message(pid, "Search a then b")
    await_completion(run_id)
    Runs.get_run!(run_id)
  end

  test "forks from a step in a fresh conversation and runs to completion", %{tenant: tenant, agent: agent} do
    parent = parent_run(tenant, agent)
    Fake.set_responses([text("Forked answer.")])

    assert {:ok, %{run: fork, agent: fork_agent}} = Fork.fork(parent, step: 1)
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{fork_agent.id}")
    await_completion(fork.id)

    assert fork_agent.id == agent.id
    assert fork.trigger_type == "fork"
    assert fork.input == %{"user_message" => "", "fork" => %{"run_id" => parent.id, "step" => 1}}
    assert fork.conversation_id != parent.conversation_id
    assert fork.gard_id == parent.gard_id

    # The first checkpoint is the parent's history after step 1: user, the
    # first tool call, and its result.
    [_started, checkpoint | _] = Runs.list_events(fork.id)
    assert checkpoint.event_type == "checkpoint_saved"
    assert [%{"role" => "user"}, %{"role" => "assistant", "tool_calls" => [%{"id" => "call_a"}]}, %{"role" => "tool", "tool_call_id" => "call_a"}] =
             checkpoint.payload["messages"]

    # The fork's LLM call saw exactly that history.
    [call] = Fake.calls()
    assert length(call.messages) == 3

    assert Runs.get_run!(fork.id).status == "completed"
    assert Runs.get_run!(fork.id).output == "Forked answer."

    # The parent's conversation is untouched.
    parent_conversation = Conversations.get_conversation!(parent.conversation_id)
    assert length(parent_conversation.messages) == 6
  end

  test "appends a new message and honours overrides on a variant agent", %{tenant: tenant, agent: agent} do
    parent = parent_run(tenant, agent)
    Fake.set_responses([text("Variant answer.")])

    assert {:ok, %{run: fork, agent: variant}} =
             Fork.fork(parent, step: 2, message: "Try it differently", system_prompt: "Be terse.", model: "claude-opus-5")

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{variant.id}")
    await_completion(fork.id)

    refute variant.id == agent.id
    assert variant.system_prompt == "Be terse."
    assert variant.model == "claude-opus-5"
    assert variant.model_config == agent.model_config
    assert String.starts_with?(variant.name, agent.name <> "-fork-")
    assert fork.agent_id == variant.id
    assert fork.input["user_message"] == "Try it differently"
    assert fork.input["fork"] == %{"run_id" => parent.id, "step" => 2, "system_prompt" => "Be terse.", "model" => "claude-opus-5"}

    [call] = Fake.calls()
    assert call.model == "claude-opus-5"
    assert call.system_prompt =~ "Be terse."
    assert %{"role" => "user"} = List.last(call.messages)
    # user, a, result, b, result, new message
    assert length(call.messages) == 6
  end

  test "step 0 forks from the original message alone", %{tenant: tenant, agent: agent} do
    parent = parent_run(tenant, agent)
    Fake.set_responses([text("From scratch.")])

    assert {:ok, %{run: fork, agent: _}} = Fork.fork(parent, step: "0")
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    await_completion(fork.id)

    [call] = Fake.calls()
    assert [%{"role" => "user"}] = call.messages
  end

  test "rejects a step beyond the log or malformed", %{tenant: tenant, agent: agent} do
    parent = parent_run(tenant, agent)
    assert {:error, {:invalid, msg}} = Fork.fork(parent, step: 99)
    assert msg =~ "beyond the run's last step (3)"
    assert {:error, {:invalid, _}} = Fork.fork(parent, step: "one")
    assert {:error, {:invalid, _}} = Fork.fork(parent, step: -1)
    assert {:error, {:invalid, _}} = Fork.fork(parent, step: 1, message: 42)
  end

  test "drops an assistant turn whose tool calls were never answered", %{tenant: tenant, agent: agent} do
    {:ok, run} =
      Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{"user_message" => "go"}, status: "failed"})

    append = fn type, payload -> {:ok, _} = Runs.append_event(run, %{event_type: type, source: "system", payload: payload}) end
    append.("run_started", %{})
    append.("llm_response", %{"content" => "", "tool_calls" => [%{"id" => "c1", "name" => "web_search", "arguments" => %{}}], "finish_reason" => "tool_call", "usage" => %{}, "step" => 1})
    append.("tool_call", %{"tool_call_id" => "c1", "name" => "web_search", "arguments" => %{}, "step" => 1})
    append.("tool_result", %{"tool_call_id" => "c1", "name" => "web_search", "content" => "r1", "is_error" => false, "step" => 1})
    append.("context_compacted", %{"step" => 1, "dropped" => 1, "kept" => 2, "summary" => "S"})
    append.("llm_response", %{"content" => "", "tool_calls" => [%{"id" => "c2", "name" => "web_search", "arguments" => %{}}], "finish_reason" => "tool_call", "usage" => %{}, "step" => 2})
    append.("tool_call", %{"tool_call_id" => "c2", "name" => "web_search", "arguments" => %{}, "step" => 2})

    Fake.set_responses([text("Recovered.")])
    assert {:ok, %{run: fork, agent: _}} = Fork.fork(Runs.get_run!(run.id), step: 2)
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    await_completion(fork.id)

    [_started, checkpoint | _] = Runs.list_events(fork.id)
    assert [%{"role" => "assistant"}, %{"role" => "tool", "content" => "r1"}] = checkpoint.payload["messages"]
    assert checkpoint.payload["summary"] == "S"

    [call] = Fake.calls()
    assert call.system_prompt =~ "Summary of earlier conversation: S"
  end
end
