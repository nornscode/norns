defmodule Norns.Agents.HistoryDelta do
  @moduledoc """
  What to send an LLM worker that already holds the previous step's history.

  The message list is almost all of an `llm_task`, and almost all of it is
  what the same worker saw one step earlier. A worker that says at join time
  that it keeps the list it was last sent for each run
  (`features: ["message_cache"]`) gets the change instead, for as long as
  the same connection serves the run:

      %{base_count: n, drop: d, append: [...]}

  meaning "take the `n` messages you hold for this run, drop the first `d`,
  append these". `drop` is non-zero after compaction or under a sliding
  window; `append` is normally the assistant turn and its tool results. The
  task carries `messages_delta` in place of `messages`; everything else in
  it is unchanged.

  The worker checks `base_count` against what it holds. If they disagree it
  answers with the error `message_cache_miss`, and core resends the whole
  list at the same step without counting a retry. That is the only
  invalidation protocol: core never has to know why a worker forgot.
  """

  @type delta :: %{base_count: non_neg_integer(), drop: non_neg_integer(), append: [map()]}

  @doc """
  The delta from `previous` (the list last sent) to `next`, or `:full` when
  they share nothing and sending the whole list is cheaper.
  """
  @spec compute([map()], [map()]) :: {:delta, delta()} | :full
  def compute(previous, next) do
    base_count = length(previous)

    case drop_for_prefix(previous, next, 0) do
      nil ->
        :full

      drop ->
        kept = base_count - drop
        {:delta, %{base_count: base_count, drop: drop, append: Enum.drop(next, kept)}}
    end
  end

  # The smallest `drop` such that `previous` without its first `drop`
  # messages is a prefix of `next`. In the common case (append-only history)
  # it returns at the first comparison.
  defp drop_for_prefix([], _next, _drop), do: nil

  defp drop_for_prefix(previous, next, drop) do
    if List.starts_with?(next, previous),
      do: drop,
      else: drop_for_prefix(tl(previous), next, drop + 1)
  end

  @doc "Apply a delta to the list a worker holds. The reference for SDKs."
  @spec apply([map()], delta()) :: {:ok, [map()]} | {:error, :message_cache_miss}
  def apply(previous, %{base_count: n, drop: d, append: append}) when length(previous) == n do
    {:ok, Enum.drop(previous, d) ++ append}
  end

  def apply(_previous, _delta), do: {:error, :message_cache_miss}
end
