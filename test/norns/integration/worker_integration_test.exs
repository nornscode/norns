defmodule Norns.Integration.WorkerIntegrationTest do
  @moduledoc """
  End-to-end test: agent dispatches a tool call to a connected worker,
  worker executes and returns result, agent completes.
  """
  use NornsWeb.ChannelCase, async: false

  alias Norns.Agents.{Process, Registry}
  alias Norns.LLM.Fake
  alias Norns.Runs
  alias Norns.Workers.WorkerRegistry
  alias NornsWeb.{WorkerSocket, WorkerChannel}

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    token = tenant.api_keys |> Map.values() |> List.first()

    # Connect a worker
    {:ok, socket} = connect(WorkerSocket, %{"token" => token})

    worker_tools = [
      %{
        "name" => "database_query",
        "description" => "Run a database query",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"sql" => %{"type" => "string"}},
          "required" => ["sql"]
        }
      }
    ]

    {:ok, _, socket} =
      subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
        "worker_id" => "test-worker-#{System.unique_integer([:positive])}",
        "tools" => worker_tools
      })

    on_exit(fn ->
      WorkerRegistry.unregister_worker(tenant.id, socket.assigns[:worker_id])
    end)

    %{tenant: tenant, agent: agent, socket: socket}
  end

  test "agent dispatches tool call to worker and completes", %{
    tenant: tenant,
    agent: agent,
    socket: socket
  } do
    # Script LLM responses:
    # 1. Call the remote database_query tool
    # 2. Return final answer
    Fake.set_responses([
      %{
        content: [
          %{
            "type" => "tool_use",
            "id" => "call_remote_1",
            "name" => "database_query",
            "input" => %{"sql" => "SELECT count(*) FROM users"}
          }
        ],
        stop_reason: "tool_use"
      },
      %{
        content: [%{"type" => "text", "text" => "There are 42 users in the database."}],
        stop_reason: "end_turn"
      }
    ])

    # Get remote tools and start agent with them
    remote_tools = WorkerRegistry.available_tools(tenant.id)
    assert length(remote_tools) == 1

    {:ok, pid} =
      Registry.start_agent(agent.id, tenant.id, tools: remote_tools)

    # Subscribe to agent events
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

    # Send message to trigger the flow
    Process.send_message(pid, "How many users do we have?")

    # Worker should receive a tool_task push
    assert_push "tool_task", task, 5000
    assert task["tool_name"] == "database_query" || task[:tool_name] == "database_query"

    task_id = task["task_id"] || task[:task_id]
    assert task_id

    # Worker executes and returns result
    push(socket, "tool_result", %{
      "task_id" => task_id,
      "status" => "ok",
      "result" => "count: 42"
    })

    # Wait for agent to complete
    assert_receive {:completed, %{output: output}}, 5000
    assert output =~ "42 users"

    # Verify the run
    state = Process.get_state(pid)
    run = Runs.get_run!(state.run_id)
    assert run.status == "completed"

    # Verify events include the remote tool call
    events = Runs.list_events(run.id)
    event_types = Enum.map(events, & &1.event_type)
    assert "tool_call" in event_types
    assert "tool_result" in event_types

    tool_call_event = Enum.find(events, &(&1.event_type == "tool_call"))
    assert tool_call_event.payload["name"] == "database_query"
  end
end
