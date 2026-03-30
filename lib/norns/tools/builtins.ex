defmodule Norns.Tools.Builtins do
  @moduledoc "Built-in orchestrator-level tools, intercepted by the agent process."

  alias Norns.Tools.Tool

  def all do
    [wait(), launch_agent(), list_agents()]
  end

  defp wait do
    %Tool{
      name: "wait",
      description: "Pause execution for a specified number of seconds.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "seconds" => %{"type" => "integer", "description" => "Number of seconds to wait"},
          "reason" => %{"type" => "string", "description" => "Why the agent is waiting"}
        },
        "required" => ["seconds"]
      },
      handler: :builtin,
      source: :builtin
    }
  end

  defp launch_agent do
    %Tool{
      name: "launch_agent",
      description: "Launch another agent as a sub-task and wait for its result. The child agent will run asynchronously and the result will be returned when it completes.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "agent_name" => %{"type" => "string", "description" => "Name of the agent to launch"},
          "message" => %{"type" => "string", "description" => "Message to send to the child agent"}
        },
        "required" => ["agent_name", "message"]
      },
      handler: :builtin,
      source: :builtin
    }
  end

  defp list_agents do
    %Tool{
      name: "list_agents",
      description: "List all available agents that can be launched as sub-tasks.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      handler: :builtin,
      source: :builtin
    }
  end
end
