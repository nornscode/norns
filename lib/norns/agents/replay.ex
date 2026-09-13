defmodule Norns.Agents.Replay do
  @moduledoc """
  An agent's state, rebuilt from the run's event log.

  This is the half of durability you only see when something goes wrong: a
  process dies, the node restarts, a fork needs the history as it stood
  fifteen steps ago. In every case the answer comes from the same fold —
  start at the last checkpoint (or the run's opening history), apply the
  events after it in order, and end with the messages, the step, the
  compaction summary, and whatever tool calls were left unanswered.

  It reads the envelope only. A message's content is carried through the
  fold untouched, which is why a replay works the same on a log full of
  ciphertext (`test/norns/runtime/opaque_content_test.exs`).

  Unanswered tool calls are the reason `rebuild_state/2` returns a
  `resume_action`: the process resumes by re-dispatching exactly those.
  """

  alias Norns.Agents.Messages
  alias Norns.Runs
  alias Norns.Runtime.Content

  @doc "Rebuild agent state from the event log for a given run."
  def rebuild_state(run_id, base_state) do
    run = Runs.get_run!(run_id)
    events = Runs.list_events(run_id)

    if events == [] do
      {:error, :no_events}
    else
      base_state = restore_conversation_for_run(base_state, run)
      initial_messages = initial_messages_for_replay(base_state, run)
      {messages, step, resume_action, summary} = replay_from_events(initial_messages, base_state[:summary], events)
      {input_tokens, output_tokens} = sum_token_usage(events)

      {:ok,
       base_state
       |> Map.put(:run, run)
       |> Map.put(:messages, messages)
       |> Map.put(:summary, summary)
       |> Map.put(:step, step)
       |> Map.put(:status, :running)
       |> Map.put(:resume_action, resume_action)
       |> Map.put(:input_tokens, input_tokens)
       |> Map.put(:output_tokens, output_tokens)
       # The gard rides on the run row — a resumed run must keep its
       # affinity or replayed tool dispatch would leak to no-gard workers.
       |> Map.put(:gard_id, run.gard_id)}
    end
  end

  @doc """
  The history of a run as it stood after `max_step`: the messages, the
  compaction summary, and whether that step left tool calls unanswered.
  Replays the log the way resume does, stopping at the step, from the
  history the run's first LLM request carried. Used by fork.
  """
  def history_at(run, max_step) do
    all_events = Runs.list_events(run.id)

    events =
      Enum.filter(all_events, fn event ->
        case event.payload["step"] do
          step when is_integer(step) -> step <= max_step
          _ -> true
        end
      end)

    # What the run started from is what its first LLM request carried: a
    # conversation's history moves on after the run, so it cannot be read
    # back from the conversation row.
    {initial_messages, initial_summary} =
      case Enum.find(all_events, &(&1.event_type == "llm_request")) do
        %{payload: %{"messages" => msgs} = payload} when is_list(msgs) ->
          {Messages.normalize(msgs), payload["summary"]}

        _ ->
          base = restore_conversation_for_run(%{conversation: nil, messages: [], summary: nil}, run)
          {initial_messages_for_replay(base, run), base.summary}
      end

    {messages, _step, resume_action, summary} = replay_from_events(initial_messages, initial_summary, events)

    %{messages: messages, summary: summary, pending_tools?: match?({:resume_tools, _}, resume_action)}
  end

  defp restore_conversation_for_run(state, run) do
    conversation = run.conversation || state.conversation
    messages = if conversation, do: Messages.normalize(conversation.messages), else: []
    summary = if conversation, do: conversation.summary, else: nil
    state |> Map.put(:conversation, conversation) |> Map.put(:messages, messages) |> Map.put(:summary, summary)
  end

  defp initial_messages_for_replay(state, run) do
    messages = state.messages
    context = get_in(run.input, ["context"])
    user_message = get_in(run.input, ["user_message"])

    context_messages = Messages.from_context(context)

    messages = messages ++ context_messages

    if Content.valid?(user_message) do
      messages ++ [%{role: "user", content: user_message}]
    else
      messages
    end
  end

  defp replay_from_events(initial_messages, initial_summary, events) do
    checkpoint =
      events
      |> Enum.reverse()
      |> Enum.find(fn event -> event.event_type in ["checkpoint_saved", "checkpoint"] end)

    case checkpoint do
      %{payload: %{"messages" => messages, "step" => step} = payload} ->
        post_checkpoint = Enum.drop_while(events, fn event -> event.sequence <= checkpoint.sequence end)
        replay_events_onto(Messages.normalize(messages), step, [], payload["summary"] || initial_summary, post_checkpoint)

      nil ->
        replay_events_onto(initial_messages, 0, [], initial_summary, events)
    end
  end

  defp replay_events_onto(messages, step, pending_tool_calls, summary, events) do
    {msgs, current_step, pending_calls, summary} =
      Enum.reduce(events, {messages, step, pending_tool_calls, summary}, fn event,
                                                                             {msgs, current_step, pending_calls, summary} ->
        case event.event_type do
          "llm_response" ->
            content = event.payload["content"] || ""
            tool_calls = event.payload["tool_calls"] || []

            assistant_msg =
              if tool_calls != [] do
                %{role: "assistant", content: content, tool_calls: tool_calls}
              else
                %{role: "assistant", content: content}
              end

            {msgs ++ [assistant_msg], event.payload["step"] || current_step, tool_calls, summary}

          "tool_result" ->
            tool_msg =
              %{
                role: "tool",
                tool_call_id: event.payload["tool_call_id"],
                name: event.payload["name"],
                content: event.payload["content"]
              }
              |> Messages.maybe_put(:kind, event.payload["kind"])
              |> Messages.maybe_put(:data, event.payload["data"])

            tool_msg =
              if event.payload["is_error"] do
                Map.put(tool_msg, :is_error, true)
              else
                tool_msg
              end

            {msgs ++ [tool_msg], current_step,
             remove_pending_tool_call(pending_calls, event.payload["tool_call_id"]), summary}

          "tool_duplicate" ->
            {msgs, current_step, remove_pending_tool_call(pending_calls, event.payload["tool_call_id"]), summary}

          "subagent_launched" ->
            {msgs, current_step, track_subagent_launch(pending_calls, event.payload), summary}

          # The folded prefix is gone; the summary stands in for it.
          "context_compacted" ->
            {Enum.drop(msgs, event.payload["dropped"] || 0), current_step, pending_calls, event.payload["summary"]}

          # Both pauses are re-derived from the still-pending tool call that
          # caused them, so the event itself replays as a no-op.
          type when type in ["waiting_for_timer", "waiting_for_user"] ->
            {msgs, current_step, pending_calls, summary}

          type when type in ["checkpoint_saved", "checkpoint"] ->
            {Messages.normalize(event.payload["messages"]), event.payload["step"], [], event.payload["summary"] || summary}

          _ ->
            {msgs, current_step, pending_calls, summary}
        end
      end)

    resume_action =
      if pending_calls != [], do: {:resume_tools, pending_calls}, else: :llm_loop

    {msgs, current_step, resume_action, summary}
  end

  defp sum_token_usage(events) do
    Enum.reduce(events, {0, 0}, fn event, {in_acc, out_acc} ->
      case event do
        %{event_type: type, payload: %{"usage" => usage}} when type in ["llm_response", "context_compacted"] and is_map(usage) ->
          {in_acc + (usage["input_tokens"] || 0), out_acc + (usage["output_tokens"] || 0)}
        _ ->
          {in_acc, out_acc}
      end
    end)
  end

  defp remove_pending_tool_call(pending_calls, tool_call_id) do
    Enum.reject(pending_calls, fn tc -> tc["id"] == tool_call_id end)
  end

  # Tag the pending launch with the run it already started, so resume reattaches
  # to that child instead of spawning a second one.
  #
  # Under the default `:on_tool_call` checkpoint policy the call is already
  # pending, carried over from the `llm_response` that requested it — appending
  # here as well is what used to dispatch the launch twice. Under `:every_step`
  # a checkpoint lands between the response and the launch and clears the
  # pending list, so there we do have to synthesize the call back. The
  # arguments are lost in that case, but a reattach doesn't need them.
  defp track_subagent_launch(pending_calls, payload) do
    tool_call_id = payload["tool_call_id"]
    child_run_id = parse_run_id(payload["child_run_id"])

    cond do
      is_nil(child_run_id) ->
        pending_calls

      Enum.any?(pending_calls, &(&1["id"] == tool_call_id)) ->
        Enum.map(pending_calls, fn
          %{"id" => ^tool_call_id} = tc -> Map.put(tc, "child_run_id", child_run_id)
          tc -> tc
        end)

      true ->
        pending_calls ++
          [
            %{
              "id" => tool_call_id,
              "name" => "launch_agent",
              "arguments" => %{"agent_name" => payload["child_agent_name"]},
              "child_run_id" => child_run_id
            }
          ]
    end
  end

  # Event payloads stringify the id; a value that doesn't parse means we have no
  # child to reattach to, and the caller falls back to a fresh launch.
  defp parse_run_id(id) when is_integer(id), do: id

  defp parse_run_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {run_id, ""} -> run_id
      _ -> nil
    end
  end

  defp parse_run_id(_), do: nil
end
