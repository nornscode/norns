defmodule Norns.Agents.HistoryDeltaTest do
  use ExUnit.Case, async: true

  alias Norns.Agents.HistoryDelta

  defp m(i), do: %{role: "user", content: "m#{i}"}

  test "an append-only history sends only the new tail" do
    previous = Enum.map(1..3, &m/1)
    next = previous ++ [m(4), m(5)]

    assert {:delta, %{base_count: 3, drop: 0, append: [%{content: "m4"}, %{content: "m5"}]}} =
             HistoryDelta.compute(previous, next)
  end

  test "a dropped prefix (compaction, a sliding window) is expressed as drop" do
    previous = Enum.map(1..5, &m/1)
    next = Enum.drop(previous, 2) ++ [m(6)]

    assert {:delta, %{base_count: 5, drop: 2, append: [%{content: "m6"}]}} =
             HistoryDelta.compute(previous, next)
  end

  test "nothing in common means a full send" do
    assert :full = HistoryDelta.compute([m(1), m(2)], [m(9)])
    assert :full = HistoryDelta.compute([], [m(1)])
    assert :full = HistoryDelta.compute([m(1), m(2), m(3)], [m(2)])
  end

  test "apply rebuilds the list a worker holds, and refuses a base of the wrong size" do
    previous = Enum.map(1..5, &m/1)
    next = Enum.drop(previous, 2) ++ [m(6)]
    {:delta, delta} = HistoryDelta.compute(previous, next)

    assert {:ok, ^next} = HistoryDelta.apply(previous, delta)
    assert {:error, :message_cache_miss} = HistoryDelta.apply(tl(previous), delta)
    assert {:error, :message_cache_miss} = HistoryDelta.apply([], delta)
  end
end
