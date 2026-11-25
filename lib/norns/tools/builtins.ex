defmodule Norns.Tools.Builtins do
  @moduledoc "Built-in orchestrator-level tools, intercepted by the agent process."

  alias Norns.Tools.Tool

  @names ~w(wait ask_human launch_agent list_agents list_runs inspect_run)

  def all do
    [wait(), ask_human(), launch_agent(), list_agents(), list_runs(), inspect_run()]
  end

  @doc "Names of every built-in, in `all/0` order."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Whether `name` is a built-in's — one the agent process intercepts rather than dispatches."
  @spec builtin?(term()) :: boolean()
  def builtin?(name), do: name in @names

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
      source: :builtin
    }
  end

  defp ask_human do
    %Tool{
      name: "ask_human",
      description: "Ask the human a question and pause until they answer. Use this to confirm before taking an action with real side effects, or when a detail is ambiguous and guessing would be wrong. The run parks indefinitely until a reply arrives.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "question" => %{"type" => "string", "description" => "The question to ask the human"}
        },
        "required" => ["question"]
      },
      source: :builtin
    }
  end

  defp launch_agent do
    %Tool{
      name: "launch_agent",
      description: "Launch another agent as a sub-task and wait for its result. The child agent will run asynchronously and the result will be returned when it completes. You may optionally pass context to give the child agent relevant history and data from the current conversation.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "agent_name" => %{"type" => "string", "description" => "Name of the agent to launch"},
          "message" => %{"type" => "string", "description" => "Message to send to the child agent"},
          "context" => %{
            "type" => "object",
            "description" => "Optional context to pass to the child agent",
            "properties" => %{
              "messages" => %{
                "type" => "array",
                "description" => "Relevant message history to seed the child agent's conversation",
                "items" => %{"type" => "object"}
              },
              "data" => %{
                "type" => "object",
                "description" => "Structured data the child agent needs (will be included as a system context message)"
              }
            }
          }
        },
        "required" => ["agent_name", "message"]
      },
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
      source: :builtin
    }
  end

  defp list_runs do
    %Tool{
      name: "list_runs",
      description: "List recent runs across all agents, newest first: who ran, their status, the task they were given, and their output, error, or pending question. Use this to see what other agents are doing or have done.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "agent_name" => %{"type" => "string", "description" => "Only runs of this agent"},
          "status" => %{
            "type" => "string",
            "enum" => ["pending", "running", "waiting", "completed", "failed"],
            "description" => "Only runs in this status. \"waiting\" means parked on a question for a human."
          },
          "limit" => %{"type" => "integer", "description" => "How many runs to return (default 20, max 50)"}
        },
        "required" => []
      },
      source: :builtin
    }
  end

  defp inspect_run do
    %Tool{
      name: "inspect_run",
      description: "Inspect one run in detail: its task, outcome, the tool calls it made, and detected problems such as loops or failing tools. Get run ids from list_runs or launch_agent results.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{"type" => "integer", "description" => "The run to inspect"}
        },
        "required" => ["run_id"]
      },
      source: :builtin
    }
  end
end
