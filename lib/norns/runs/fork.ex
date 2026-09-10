defmodule Norns.Runs.Fork do
  @moduledoc """
  Fork a run from a step.

  The new run starts from the parent's history as it stood after `step`:
  the messages replayed from the log up to that step (the way resume
  replays them) and the compaction summary, if any, written as the first
  checkpoint of the new run. If the step ended with tool calls still
  unanswered, the fork drops that assistant turn so the model decides
  again. An optional `message` is appended as a user turn.

  A fork is a task-mode run in a fresh conversation, never appended to
  the parent's, and stays on the parent's gard, where the working tree
  is. `system_prompt` and `model` overrides create a variant agent (the
  def with the overrides applied) and fork onto it: the process re-reads
  its def every step, so an override has nowhere else to live, and one
  agent per variant keeps prompt experiments legible.

  Core copies content here and never reads it.
  """

  alias Norns.{Agents, Conversations, Runs}
  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.Agents.Registry
  alias Norns.Runs.Run
  alias Norns.Runtime.{Content, Events}

  @type opts :: [step: non_neg_integer(), message: term(), system_prompt: String.t() | nil, model: String.t() | nil]

  @spec fork(Run.t(), opts()) :: {:ok, %{run: Run.t(), agent: Agents.Agent.t()}} | {:error, {:invalid, String.t()} | term()}
  def fork(%Run{} = parent, opts) do
    with {:ok, step} <- parse_step(Keyword.get(opts, :step), parent),
         {:ok, message} <- parse_message(Keyword.get(opts, :message)),
         {:ok, agent} <- agent_for(parent, opts) do
      history = AgentProcess.history_at(parent, step)
      messages = history.messages |> drop_unanswered(history.pending_tools?) |> append_message(message)

      key = "fork_#{parent.id}_#{System.unique_integer([:positive])}"
      {:ok, conversation} = Conversations.find_or_create_conversation(agent.id, parent.tenant_id, key)

      {:ok, conversation} =
        Conversations.update_conversation(conversation, %{
          messages: messages,
          summary: Content.to_column(history.summary)
        })

      input =
        %{"user_message" => message || "", "fork" => fork_input(parent, step, opts)}

      {:ok, run} =
        Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: parent.tenant_id,
          conversation_id: conversation.id,
          trigger_type: "fork",
          input: input,
          status: "running",
          gard_id: parent.gard_id
        })

      {:ok, _} = Runs.append_event(run, unwrap!(Events.run_started()))

      checkpoint =
        %{"messages" => messages, "step" => 0}
        |> then(fn c -> if history.summary, do: Map.put(c, "summary", history.summary), else: c end)

      {:ok, _} = Runs.append_event(run, unwrap!(Events.checkpoint_saved(checkpoint)))

      case Registry.resume_agent(run.id, agent.id, parent.tenant_id, conversation_key: key) do
        {:ok, _pid} -> {:ok, %{run: Runs.get_run!(run.id), agent: agent}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_step(step, parent) when is_binary(step) do
    case Integer.parse(step) do
      {n, ""} -> parse_step(n, parent)
      _ -> {:error, {:invalid, "step must be a non-negative integer"}}
    end
  end

  defp parse_step(step, parent) when is_integer(step) and step >= 0 do
    last = last_step(parent)

    if step <= last do
      {:ok, step}
    else
      {:error, {:invalid, "step #{step} is beyond the run's last step (#{last})"}}
    end
  end

  defp parse_step(_step, _parent), do: {:error, {:invalid, "step must be a non-negative integer"}}

  defp last_step(parent) do
    parent.id
    |> Runs.list_events()
    |> Enum.map(& &1.payload["step"])
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp parse_message(nil), do: {:ok, nil}
  defp parse_message(""), do: {:ok, nil}

  defp parse_message(message) do
    if Content.valid?(message), do: {:ok, message}, else: {:error, {:invalid, "message must be text or a content block"}}
  end

  # An assistant turn whose tool calls never got results would leave the
  # model waiting on answers that will never come; drop it and let it choose.
  defp drop_unanswered(messages, false), do: messages

  defp drop_unanswered(messages, true) do
    case Enum.find_index(Enum.reverse(messages), &assistant_with_tool_calls?/1) do
      nil -> messages
      from_end -> Enum.take(messages, length(messages) - from_end - 1)
    end
  end

  defp assistant_with_tool_calls?(%{role: "assistant", tool_calls: calls}) when is_list(calls) and calls != [], do: true
  defp assistant_with_tool_calls?(%{"role" => "assistant", "tool_calls" => calls}) when is_list(calls) and calls != [], do: true
  defp assistant_with_tool_calls?(_), do: false

  defp append_message(messages, nil), do: messages
  defp append_message(messages, message), do: messages ++ [%{role: "user", content: message}]

  defp agent_for(parent, opts) do
    base = Agents.get_agent!(parent.agent_id)
    overrides = Enum.reject([system_prompt: opts[:system_prompt], model: opts[:model]], fn {_k, v} -> v in [nil, ""] end)

    if overrides == [] do
      {:ok, base}
    else
      Agents.create_agent(%{
        tenant_id: base.tenant_id,
        name: "#{base.name}-fork-#{System.unique_integer([:positive])}",
        purpose: base.purpose,
        status: "idle",
        system_prompt: Keyword.get(overrides, :system_prompt, base.system_prompt),
        model: Keyword.get(overrides, :model, base.model),
        model_config: base.model_config,
        tools_config: base.tools_config,
        max_steps: base.max_steps
      })
    end
  end

  defp fork_input(parent, step, opts) do
    %{"run_id" => parent.id, "step" => step}
    |> then(fn m -> if opts[:system_prompt] in [nil, ""], do: m, else: Map.put(m, "system_prompt", opts[:system_prompt]) end)
    |> then(fn m -> if opts[:model] in [nil, ""], do: m, else: Map.put(m, "model", opts[:model]) end)
  end

  defp unwrap!({:ok, event}), do: event
  defp unwrap!({:error, reason}), do: raise(ArgumentError, "invalid event: #{inspect(reason)}")
end
