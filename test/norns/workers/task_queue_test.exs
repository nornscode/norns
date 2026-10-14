defmodule Norns.Workers.TaskQueueTest do
  use ExUnit.Case, async: false

  alias Norns.Workers.TaskQueue

  # Issue #3, the part that outlived the re-dispatch fix. A task that no
  # worker ever takes sits in the queue until the sweep gives up on it, and
  # the giving-up has to reach the agent in the shape the agent listens for.
  # `Norns.Agents.Process` has clauses for `:task_result` and none for
  # `:tool_result`, so the legacy name did not time the run out — it killed
  # the agent with a function_clause, and the run stayed `running` with its
  # conversation locked behind a 409. Which is the original bug, reached by
  # a longer road.
  describe "sweeping a task nobody took" do
    test "tells the waiting agent in the shape it handles" do
      old = System.monotonic_time(:millisecond) - 600_000

      TaskQueue.enqueue(:sweep_tenant, %{
        task_id: "stale-1",
        tool_name: "__llm__",
        input: %{},
        from_pid: self(),
        queued_at: old
      })

      send(TaskQueue, :sweep_stale)

      assert_receive {:task_result, "stale-1", {:error, :timeout}}, 1_000
    end

    test "leaves a task that is merely waiting alone" do
      TaskQueue.enqueue(:sweep_tenant_fresh, %{
        task_id: "fresh-1",
        tool_name: "__llm__",
        input: %{},
        from_pid: self()
      })

      send(TaskQueue, :sweep_stale)

      refute_receive {:task_result, "fresh-1", _}, 300
      assert [%{task_id: "fresh-1"}] = TaskQueue.flush(:sweep_tenant_fresh, "__llm__")
    end
  end
end
