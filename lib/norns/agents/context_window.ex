defmodule Norns.Agents.ContextWindow do
  @moduledoc """
  The sliding window: which of a history's messages an LLM call is sent.

  The window keeps at least the newest `window` messages and drops older ones
  half a window at a time, so the list sent is between `window` and one and a
  half times `window` long. Dropping one message for each one appended would
  hold the count exact and move the front of the list on every call, and a
  provider's prompt cache reads back only an unchanged prefix: every step of
  a run would pay to write the whole history again. Dropping in chunks leaves
  the front where it was for half a window of messages, so within a run each
  call's list is the next call's prefix.

  The cut is a function of the list alone. A run rebuilt from its log starts
  from the list its first call was sent, not the whole conversation, so it
  may cut at a different message from then on; it keeps the window all the
  same.
  """

  @doc "The messages to send: `messages` without the prefix the window has dropped."
  @spec apply([map()], pos_integer()) :: [map()]
  def apply(messages, window), do: Enum.drop(messages, drop(messages, window))

  @doc "How many messages the window drops from the front of `messages`."
  @spec drop([map()], pos_integer()) :: non_neg_integer()
  def drop(messages, window) do
    window = max(window, 1)
    chunk = max(div(window, 2), 1)
    over = max(length(messages) - window, 0)
    pair_boundary(messages, div(over, chunk) * chunk)
  end

  @doc """
  The largest cut at or before `drop` that does not split a tool call from
  its results.

  A tool_use message is always immediately followed by its tool_result
  message(s), so a cut that lands on a "tool" message has split a pair. Back
  up until it lands on the owning assistant message instead.
  """
  @spec pair_boundary([map()], non_neg_integer()) :: non_neg_integer()
  def pair_boundary(messages, drop) when drop > 0 do
    case Enum.at(messages, drop) do
      %{role: "tool"} -> pair_boundary(messages, drop - 1)
      _ -> drop
    end
  end

  def pair_boundary(_messages, drop), do: drop
end
