defmodule Norns.Agents.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Norns.Agents.ContextWindow

  defp history(n), do: Enum.map(1..n, &%{role: "user", content: "m#{&1}"})

  defp sent(n, window), do: ContextWindow.apply(history(n), window)

  test "a history within the window is sent whole" do
    assert sent(10, 10) == history(10)
    assert sent(3, 10) == history(3)
    assert ContextWindow.apply([], 10) == []
  end

  test "the window is a floor: between it and one and a half times it" do
    for n <- 10..200 do
      count = length(sent(n, 10))
      assert count >= 10 and count < 15, "#{n} messages sent #{count}"
      assert sent(n, 10) == Enum.take(history(n), -count)
    end
  end

  test "the front holds still for half a window of new messages" do
    # What a run's steps are sent as the history grows: each list starts where
    # the last did, so it reads back from a prompt cache, except at a drop.
    fronts = for n <- 100..139, do: hd(sent(n, 20)).content
    assert length(Enum.dedup(fronts)) == 4
    assert Enum.frequencies(fronts) |> Map.values() |> Enum.uniq() == [10]

    for n <- 100..108 do
      assert List.starts_with?(sent(n + 1, 20), sent(n, 20))
    end
  end

  test "a window too small to halve drops one message at a time" do
    assert length(sent(5, 1)) == 1
    assert length(sent(6, 1)) == 1
    assert Enum.map(sent(7, 2), & &1.content) == ["m6", "m7"]
  end

  test "a cut never splits a tool call from its results" do
    messages = [
      %{role: "user", content: "go"},
      %{role: "assistant", content: "", tool_calls: [%{id: "a"}, %{id: "b"}]},
      %{role: "tool", tool_call_id: "a", content: "1"},
      %{role: "tool", tool_call_id: "b", content: "2"},
      %{role: "assistant", content: "done"}
    ]

    # A window of two would cut at the second result; it backs up to the call.
    assert ContextWindow.drop(messages, 2) == 1
    assert hd(ContextWindow.apply(messages, 2)).role == "assistant"
    assert ContextWindow.pair_boundary(messages, 2) == 1
    assert ContextWindow.pair_boundary(messages, 4) == 4
    assert ContextWindow.pair_boundary(messages, 0) == 0
  end
end
