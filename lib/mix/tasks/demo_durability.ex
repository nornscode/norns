defmodule Mix.Tasks.Demo.Durability do
  @moduledoc """
  Demonstrates crash recovery: starts an agent, kills it mid-task,
  resumes from the event log, and completes without losing progress.

  Uses the fake LLM — no API key needed.

      mix demo.durability
  """

  use Mix.Task

  @shortdoc "Demo: crash an agent mid-task and watch it recover"

  def run(_args) do
    Mix.Task.run("app.start")

    # Use fake LLM for the demo
    Application.put_env(:norns, Norns.LLM, module: Norns.LLM.Fake)

    alias Norns.{Agents, Runs, Tenants}
    alias Norns.Agents.Registry
    alias Norns.LLM.Fake
    alias Norns.Tools.{Http, WebSearch}

    banner()

    # 1. Setup
    step("Creating tenant and agent...")
    {:ok, tenant} = Tenants.create_tenant(%{
      name: "Demo",
      slug: "demo-#{System.unique_integer([:positive])}",
      api_keys: %{"anthropic" => "fake-key"}
    })

    {:ok, agent} = Agents.create_agent(%{
      tenant_id: tenant.id,
      name: "research-agent-#{System.unique_integer([:positive])}",
      system_prompt: "You are a research assistant.",
      status: "idle"
    })

    info("  Agent: #{agent.name} (id: #{agent.id})")

    # 2. Script fake LLM responses
    Fake.set_responses([
      # Step 1: Agent decides to search
      %{
        content: [%{
          "type" => "tool_use",
          "id" => "call_1",
          "name" => "http_request",
          "input" => %{"url" => "https://elixir-lang.org", "method" => "GET"}
        }],
        stop_reason: "tool_use"
      },
      # Step 2: Agent searches for more info
      %{
        content: [%{
          "type" => "tool_use",
          "id" => "call_2",
          "name" => "web_search",
          "input" => %{"query" => "Elixir programming language latest release"}
        }],
        stop_reason: "tool_use"
      },
      # (responses 3-4 scripted after crash for the resumed process)
    ])

    # 3. Start and send message
    step("Starting agent and sending query...")
    {:ok, _pid} = Registry.start_agent(agent.id, tenant.id, tools: [Http.__tool__(), WebSearch.__tool__()])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    Registry.send_message(tenant.id, agent.id, "Research the current status of the Elixir programming language")

    # 4. Wait for 2 tool results
    step("Agent is working (LLM → tool call → LLM → tool call)...")
    wait_for_events(:tool_result, 2)

    # Get the run ID
    [run] = Runs.list_runs(agent.id)
    run_id = run.id

    events_before = Runs.list_events(run_id)
    info("  Events logged before crash: #{length(events_before)}")

    # 5. Kill the process
    step("Simulating crash — killing the agent process...")
    Registry.stop_agent(tenant.id, agent.id)
    Process.sleep(100)

    run = Runs.get_run!(run_id)
    info("  Run status in database: #{run.status}")
    info("  Agent process alive? #{Registry.alive?(tenant.id, agent.id)}")

    # 6. Show the event log
    step("Event log before crash:")
    events_before |> Enum.each(fn e ->
      info("  [#{e.sequence}] #{e.event_type}" <> event_detail(e))
    end)

    # 7. Resume
    step("Resuming agent from event log...")

    # Script remaining responses for the resumed agent
    Fake.set_responses([
      # Step 3 (after resume): one more tool call
      %{
        content: [%{
          "type" => "tool_use",
          "id" => "call_3",
          "name" => "web_search",
          "input" => %{"query" => "Elixir 1.18 features"}
        }],
        stop_reason: "tool_use"
      },
      # Step 4: final answer
      %{
        content: [%{
          "type" => "text",
          "text" => "Based on my research, Elixir is thriving. The language continues to evolve with regular releases, strong community adoption, and growing use in production systems."
        }],
        stop_reason: "end_turn"
      }
    ])

    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
    {:ok, _pid} = Registry.resume_agent(run_id, agent.id, tenant.id, tools: [Http.__tool__(), WebSearch.__tool__()])

    # 8. Wait for completion
    wait_for_event(:completed, 10_000)

    # 9. Show results
    run = Runs.get_run!(run_id)
    all_events = Runs.list_events(run_id)

    step("Agent completed after recovery!")
    info("  Run status: #{run.status}")
    info("  Output: #{String.slice(run.output || "", 0, 200)}")
    info("")

    step("Full event log (#{length(all_events)} events):")
    all_events |> Enum.each(fn e ->
      info("  [#{e.sequence}] #{e.event_type}" <> event_detail(e))
    end)

    info("")
    tool_calls = Enum.count(all_events, &(&1.event_type == "tool_call"))
    llm_calls = Enum.count(all_events, &(&1.event_type == "llm_request"))
    info("  Summary: #{llm_calls} LLM calls, #{tool_calls} tool calls, #{length(all_events)} total events")
    info("  The agent survived a crash and completed without losing any work.")
    info("")
  end

  defp wait_for_events(_event, 0), do: :ok
  defp wait_for_events(event, count) do
    receive do
      {^event, _payload} -> wait_for_events(event, count - 1)
      _ -> wait_for_events(event, count)
    after
      10_000 -> Mix.shell().error("Timeout waiting for #{event}")
    end
  end

  defp wait_for_event(event, timeout) do
    receive do
      {^event, _payload} -> :ok
      _ -> wait_for_event(event, timeout)
    after
      timeout -> Mix.shell().error("Timeout waiting for #{event}")
    end
  end

  defp event_detail(%{event_type: "tool_call", payload: %{"name" => name}}), do: " → #{name}"
  defp event_detail(%{event_type: "tool_result", payload: %{"tool_use_id" => id}}), do: " → #{id}"
  defp event_detail(%{event_type: "llm_response", payload: %{"stop_reason" => sr}}), do: " (#{sr})"
  defp event_detail(%{event_type: "agent_completed"}), do: " ✓"
  defp event_detail(%{event_type: "checkpoint", payload: %{"step" => s}}), do: " (step #{s})"
  defp event_detail(_), do: ""

  defp banner do
    Mix.shell().info("""

    ╔══════════════════════════════════════════════╗
    ║       Norns Durability Demo                  ║
    ║                                              ║
    ║  Start an agent, crash it mid-task,          ║
    ║  resume from the event log, complete.        ║
    ║                                              ║
    ║  (Using fake LLM — no API key needed)        ║
    ╚══════════════════════════════════════════════╝
    """)
  end

  defp step(msg), do: Mix.shell().info("\n>> #{msg}")
  defp info(msg), do: Mix.shell().info(msg)
end
