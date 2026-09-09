defmodule Norns.Runs.TraceSummary do
  @moduledoc """
  A fixed-size, machine-readable account of what a run did.

  Built for an agent reading another agent's run. Raw event logs don't work for
  that: a long run holds hundreds of events and `llm_request` carries the entire
  message array, so fetching one is both enormous and mostly noise. A summary
  has to stay roughly the same size whether the run took five steps or five
  hundred, or it's useless on exactly the runs worth summarizing.

  Three rules shape the output:

    * **Fixed size.** Consecutive steps calling the same tool with the same
      result class collapse into one entry carrying a count and a sequence
      range. Nothing is discarded — it's addressable, not gone.
    * **Observations, not prescriptions.** Signals report what was detected and
      where. They don't suggest fixes; rule-based advice is wrong often enough
      to mislead a reader who could reason better from the evidence.
    * **Every summary is a query plan.** Anything elided comes with the
      sequence range needed to fetch it via `Norns.Runs.list_events/1`.

  Deliberately absent: message content, system prompts, full tool results, and
  any judgement about whether the run did the *right* thing. Those are separate
  concerns and smuggling them in here would make the output both larger and
  less trustworthy.
  """

  import Ecto.Query

  alias Norns.Repo
  alias Norns.Runs.{Run, RunEvent}

  # Consecutive identical calls at or above this count read as a loop.
  @loop_threshold 5
  # Timeline entries kept before eliding the middle.
  @timeline_head 8
  @timeline_tail 8
  # Longest rendered argument/result excerpt.
  @excerpt 120

  @type t :: map()

  @doc """
  Build a summary of `run_id`.

  Returns `{:error, :not_found}` for an unknown run.
  """
  @spec build(integer()) :: {:ok, t()} | {:error, :not_found}
  def build(run_id) do
    case Repo.get(Run, run_id) |> Repo.preload(:agent) do
      nil -> {:error, :not_found}
      run -> {:ok, summarize(run, scan(run_id))}
    end
  end

  # Scalar projection. Never selects `payload` wholesale — `llm_request` and
  # `checkpoint_saved` both carry full message arrays, and pulling those to
  # count events would load megabytes to produce a handful of integers.
  defp scan(run_id) do
    from(e in RunEvent,
      where: e.run_id == ^run_id,
      order_by: e.sequence,
      select: %{
        seq: e.sequence,
        type: e.event_type,
        at: e.inserted_at,
        step: fragment("(? ->> 'step')::int", e.payload),
        name: fragment("? ->> 'name'", e.payload),
        tool_call_id: fragment("? ->> 'tool_call_id'", e.payload),
        is_error: fragment("(? ->> 'is_error')::boolean", e.payload),
        usage: fragment("? -> 'usage'", e.payload),
        tools: fragment("? -> 'tools'", e.payload),
        error_class: fragment("? ->> 'error_class'", e.payload),
        error_code: fragment("? ->> 'error_code'", e.payload),
        error: fragment("? ->> 'error'", e.payload),
        reason: fragment("? ->> 'reason'", e.payload)
      }
    )
    |> Repo.all()
  end

  defp summarize(run, events) do
    calls = tool_calls(events)
    timeline = calls |> collapse() |> elide_middle() |> hydrate(run.id)
    signals = detect_signals(run, events, calls)

    %{
      run_id: run.id,
      agent: %{
        id: run.agent_id,
        name: run.agent && run.agent.name,
        model: run.agent && run.agent.model,
        max_steps: run.agent && run.agent.max_steps
      },
      parent_run_id: run.parent_run_id,
      depth: run.depth,
      verdict: run.status,
      reason: reason(run, events, signals),
      headline: headline(run, events, calls, signals),
      counters: counters(run, events, calls),
      tools_used: tools_used(calls),
      timeline: timeline,
      signals: signals,
      drill: drill(events, calls)
    }
  end

  # -- tool call / result pairing --

  defp tool_calls(events) do
    results =
      events
      |> Enum.filter(&(&1.type == "tool_result" and &1.tool_call_id))
      |> Map.new(&{&1.tool_call_id, &1})

    events
    |> Enum.filter(&(&1.type == "tool_call"))
    |> Enum.map(fn call ->
      result = Map.get(results, call.tool_call_id)

      %{
        step: call.step,
        tool: call.name,
        seq: call.seq,
        result_seq: result && result.seq,
        class: result_class(result)
      }
    end)
  end

  # A call with no result is not an error — it's a call that never came back,
  # which is what an interrupted run looks like.
  defp result_class(nil), do: :pending
  defp result_class(%{is_error: true}), do: :error
  defp result_class(_), do: :ok

  # -- timeline --

  defp collapse(calls) do
    calls
    |> Enum.chunk_by(&{&1.tool, &1.class})
    |> Enum.map(fn
      [single] ->
        %{
          step: single.step,
          tool: single.tool,
          class: single.class,
          count: 1,
          seq: [single.seq, single.result_seq || single.seq]
        }

      [first | _] = group ->
        last = List.last(group)

        %{
          step: "#{first.step}-#{last.step}",
          tool: first.tool,
          class: first.class,
          count: length(group),
          seq: [first.seq, last.result_seq || last.seq]
        }
    end)
  end

  # Keep the head and tail intact — that's where the setup and the terminal
  # behaviour live — and replace the middle with one marker that still carries
  # its sequence range.
  defp elide_middle(entries) when length(entries) <= @timeline_head + @timeline_tail + 1, do: entries

  defp elide_middle(entries) do
    head = Enum.take(entries, @timeline_head)
    tail = Enum.take(entries, -@timeline_tail)
    middle = entries |> Enum.drop(@timeline_head) |> Enum.drop(-@timeline_tail)

    marker = %{
      elided: length(middle),
      calls: Enum.sum(Enum.map(middle, & &1.count)),
      tools: middle |> Enum.map(& &1.tool) |> Enum.uniq(),
      seq: [middle |> List.first() |> then(& &1.seq) |> List.first(),
            middle |> List.last() |> then(& &1.seq) |> List.last()]
    }

    head ++ [marker] ++ tail
  end

  # Fetch arguments and result content only for the entries that survived
  # collapsing — a second small query rather than one large one.
  defp hydrate(entries, run_id) do
    seqs = entries |> Enum.flat_map(&entry_seqs/1) |> Enum.uniq()

    payloads =
      if seqs == [] do
        %{}
      else
        from(e in RunEvent,
          where: e.run_id == ^run_id and e.sequence in ^seqs,
          select: {e.sequence, e.payload}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.map(entries, fn
      %{elided: _} = marker ->
        marker

      entry ->
        [call_seq, result_seq] = entry.seq
        args = payloads |> Map.get(call_seq, %{}) |> Map.get("arguments")
        content = payloads |> Map.get(result_seq, %{}) |> Map.get("content")

        entry
        |> Map.put(:call, "#{entry.tool}(#{render_args(args)})")
        |> Map.put(:result, render_result(entry.class, content))
        |> Map.drop([:tool])
    end)
  end

  defp entry_seqs(%{elided: _}), do: []
  defp entry_seqs(%{seq: seq}), do: seq

  defp render_args(args) when is_map(args) and map_size(args) > 0 do
    args
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{arg_value(v)}" end)
    |> truncate(@excerpt)
  end

  defp render_args(_), do: ""

  # Arguments are inspected so a string reads differently from a number and an
  # empty string is visible at all — the difference between query="" and
  # query=0 matters when diagnosing why a call came back empty.
  defp arg_value(value), do: value |> inspect() |> truncate(@excerpt)

  defp render_result(:pending, _), do: "no result — call did not return"

  defp render_result(class, content) do
    prefix = if class == :error, do: "error: ", else: ""
    prefix <> truncate(excerpt(content), @excerpt)
  end

  # Results render plainly — they're prose the model should read, not values it
  # should compare.
  defp excerpt(value) when is_binary(value), do: value
  defp excerpt(nil), do: ""
  defp excerpt(%{"$enc" => _}), do: "[encrypted]"
  defp excerpt(value), do: inspect(value)

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "… (truncated)"
  end

  defp truncate(str, _max), do: str

  # -- counters --

  defp counters(run, events, calls) do
    %{
      steps: events |> Enum.map(& &1.step) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end),
      llm_calls: count(events, "llm_request"),
      tool_calls: length(calls),
      tool_errors: Enum.count(calls, &(&1.class == :error)),
      duplicates_skipped: count(events, "tool_duplicate"),
      subagents: count(events, "subagent_launched"),
      retries: count(events, "retry"),
      input_tokens: run.input_tokens || 0,
      output_tokens: run.output_tokens || 0,
      duration_ms: duration_ms(events)
    }
  end

  defp count(events, type), do: Enum.count(events, &(&1.type == type))

  defp duration_ms([]), do: 0

  defp duration_ms(events) do
    first = events |> List.first() |> Map.fetch!(:at)
    last = events |> List.last() |> Map.fetch!(:at)
    DateTime.diff(last, first, :millisecond)
  end

  defp tools_used(calls) do
    calls
    |> Enum.group_by(& &1.tool)
    |> Map.new(fn {tool, group} ->
      {tool,
       %{
         calls: length(group),
         errors: Enum.count(group, &(&1.class == :error)),
         pending: Enum.count(group, &(&1.class == :pending))
       }}
    end)
  end

  # -- signals --

  defp detect_signals(run, events, calls) do
    [
      loop_signal(calls),
      max_steps_signal(run, events),
      tool_failing_signals(calls),
      unknown_tool_signal(events, calls),
      no_tool_use_signal(events, calls),
      parked_signal(run, events),
      retry_storm_signal(events),
      pending_call_signal(calls)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp loop_signal(calls) do
    calls
    |> collapse()
    |> Enum.filter(&(&1.count >= @loop_threshold))
    |> Enum.map(fn group ->
      %{
        kind: "loop",
        severity: "high",
        detail:
          "#{group.count} consecutive calls to #{group.tool} with the same result class " <>
            "(#{group.class}). No strategy change across the run.",
        seq: group.seq
      }
    end)
  end

  defp max_steps_signal(%{status: "failed"} = run, events) do
    max_steps = run.agent && run.agent.max_steps
    reached = events |> Enum.map(& &1.step) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)

    if max_steps && reached >= max_steps do
      %{
        kind: "max_steps",
        severity: "high",
        detail: "Reached the step ceiling of #{max_steps} without completing.",
        seq: terminal_seq(events)
      }
    end
  end

  defp max_steps_signal(_run, _events), do: nil

  defp tool_failing_signals(calls) do
    calls
    |> Enum.group_by(& &1.tool)
    |> Enum.filter(fn {_tool, group} ->
      errors = Enum.count(group, &(&1.class == :error))
      errors >= 2 and errors == length(group)
    end)
    |> Enum.map(fn {tool, group} ->
      %{
        kind: "tool_failing",
        severity: "high",
        detail: "#{tool} failed on all #{length(group)} calls — the worker serving it may be down.",
        seq: [group |> List.first() |> Map.fetch!(:seq), group |> List.last() |> Map.fetch!(:seq)]
      }
    end)
  end

  # Needs the `tools` list recorded on llm_request. Runs predating that field
  # yield no offered tools, so the signal stays silent rather than guessing.
  defp unknown_tool_signal(events, calls) do
    offered = offered_tools(events)

    unknown =
      if offered == [] do
        []
      else
        calls |> Enum.map(& &1.tool) |> Enum.uniq() |> Enum.reject(&(&1 in offered))
      end

    if unknown != [] do
      %{
        kind: "unknown_tool",
        severity: "high",
        detail:
          "Called #{Enum.join(unknown, ", ")}, which no connected worker offered. " <>
            "The prompt likely names a tool that isn't registered.",
        seq: calls |> Enum.find(&(&1.tool in unknown)) |> then(&[&1.seq, &1.seq])
      }
    end
  end

  defp no_tool_use_signal(events, []) do
    case offered_tools(events) do
      [] ->
        nil

      offered ->
        %{
          kind: "no_tool_use",
          severity: "medium",
          detail:
            "#{length(offered)} tools were available and none were called. " <>
              "The prompt may not connect the task to the tools.",
          seq: nil
        }
    end
  end

  defp no_tool_use_signal(_events, _calls), do: nil

  defp offered_tools(events) do
    events
    |> Enum.filter(&(&1.type == "llm_request" and is_list(&1.tools)))
    |> Enum.flat_map(& &1.tools)
    |> Enum.uniq()
  end

  defp parked_signal(%{status: "waiting"}, events) do
    parked = Enum.find(events, &(&1.type == "waiting_for_user"))

    if parked do
      %{
        kind: "parked_unanswered",
        severity: "medium",
        detail: "Parked on a question and still waiting for an answer.",
        seq: [parked.seq, parked.seq]
      }
    end
  end

  defp parked_signal(_run, _events), do: nil

  defp retry_storm_signal(events) do
    events
    |> Enum.filter(&(&1.type == "retry"))
    |> Enum.group_by(& &1.step)
    |> Enum.filter(fn {_step, group} -> length(group) >= 3 end)
    |> Enum.map(fn {step, group} ->
      %{
        kind: "retry_storm",
        severity: "medium",
        detail: "#{length(group)} retries at step #{step}.",
        seq: [group |> List.first() |> Map.fetch!(:seq), group |> List.last() |> Map.fetch!(:seq)]
      }
    end)
  end

  defp pending_call_signal(calls) do
    pending = Enum.filter(calls, &(&1.class == :pending))

    if pending != [] do
      %{
        kind: "unreturned_call",
        severity: "high",
        detail:
          "#{length(pending)} tool call(s) never produced a result — " <>
            "the run was interrupted or a worker dropped the task.",
        seq: [pending |> List.first() |> Map.fetch!(:seq), pending |> List.last() |> Map.fetch!(:seq)]
      }
    end
  end

  # -- verdict --

  # Closed set, so a caller comparing two runs can branch on it rather than
  # parsing prose. Free text lives in `headline`.
  defp reason(%{status: "completed"}, _events, _signals), do: "completed"
  defp reason(%{status: "waiting"}, _events, _signals), do: "parked"
  defp reason(%{status: status}, _events, _signals) when status in ["pending", "running"], do: "running"

  defp reason(%{status: "failed"}, events, signals) do
    cond do
      Enum.any?(signals, &(&1.kind == "max_steps")) -> "max_steps_exceeded"
      failure_class(events) == "validation" -> "tool_error_terminal"
      failure_class(events) -> "llm_error"
      true -> "failed"
    end
  end

  defp failure_class(events) do
    events
    |> Enum.find(&(&1.type == "run_failed"))
    |> case do
      nil -> nil
      event -> event.error_class
    end
  end

  defp headline(run, events, calls, signals) do
    case {run.status, signals} do
      {"completed", _} ->
        "Completed in #{length(calls)} tool call(s)."

      {"waiting", _} ->
        "Parked awaiting a human answer."

      {_, [%{detail: detail} | _]} ->
        detail

      {status, []} ->
        failed = Enum.find(events, &(&1.type == "run_failed"))
        if failed && failed.error, do: truncate(failed.error, 200), else: "Run is #{status}."
    end
  end

  defp drill(events, calls) do
    %{
      first_failure: calls |> Enum.find(&(&1.class == :error)) |> then(&(&1 && &1.result_seq)),
      terminal: terminal_seq(events)
    }
  end

  defp terminal_seq(events) do
    events
    |> Enum.filter(&(&1.type in ["run_failed", "run_completed"]))
    |> List.last()
    |> then(&(&1 && &1.seq))
  end
end
