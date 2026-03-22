defmodule Norns.Agents.RunnerTest do
  use Norns.DataCase, async: true

  alias Norns.Agents.Runner
  alias Norns.LLM.Fake
  alias Norns.Runs

  describe "execute/3" do
    test "creates a completed run with output on success" do
      tenant = create_tenant(%{api_keys: %{"anthropic" => "test-key"}})
      agent = create_agent(tenant, %{system_prompt: "You summarize.", model: "test-model"})

      Fake.set_responses([
        %{
          content: [%{"type" => "text", "text" => "Here is a summary."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, run} = Runner.execute(agent, "some commits", tenant)

      assert run.status == "completed"
      assert run.output == "Here is a summary."

      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)
      assert "run_started" in event_types
      assert "llm_response" in event_types
      assert "run_completed" in event_types
    end
  end
end
