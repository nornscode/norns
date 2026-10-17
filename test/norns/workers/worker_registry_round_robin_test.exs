defmodule Norns.Workers.WorkerRegistryRoundRobinTest do
  use ExUnit.Case, async: false

  alias Norns.Workers.WorkerRegistry

  @tenant 7_100
  @tools [%{"name" => "search", "description" => "Search", "input_schema" => %{}}]

  # A stand-in channel: forwards every push to the test process tagged with
  # the worker's name, so the test can see which worker each task reached.
  defp channel(name) do
    test_pid = self()

    spawn_link(fn ->
      Stream.repeatedly(fn ->
        receive do
          msg -> send(test_pid, {:pushed, name, msg})
        end
      end)
      |> Stream.run()
    end)
  end

  defp register(names, opts \\ []) do
    for name <- names do
      :ok = WorkerRegistry.register_worker(@tenant, name, channel(name), @tools, opts)
    end

    on_exit(fn -> Enum.each(names, &WorkerRegistry.unregister_worker(@tenant, &1)) end)
  end

  defp collect(tag, n) do
    for _ <- 1..n do
      assert_receive {:pushed, name, {^tag, _}}, 1_000
      name
    end
  end

  test "tool tasks rotate through every worker that offers the tool" do
    register(["rr-a", "rr-b", "rr-c"])

    for i <- 1..6 do
      {:ok, _} = WorkerRegistry.dispatch_task(@tenant, "search", %{"i" => i}, from_pid: self())
    end

    assert collect(:push_tool_task, 6) |> Enum.frequencies() ==
             %{"rr-a" => 2, "rr-b" => 2, "rr-c" => 2}
  end

  test "LLM tasks rotate through every LLM-capable worker" do
    register(["llm-a", "llm-b"], capabilities: [:llm])

    for _ <- 1..4 do
      {:ok, _} = WorkerRegistry.dispatch_llm_task(@tenant, %{messages: []}, from_pid: self())
    end

    assert collect(:llm_task, 4) |> Enum.frequencies() == %{"llm-a" => 2, "llm-b" => 2}
  end

  test "a draining worker drops out of the rotation" do
    register(["dr-a", "dr-b"])
    WorkerRegistry.drain_worker(@tenant, "dr-a")
    # drain is a cast; a call behind it guarantees it has been applied
    _ = WorkerRegistry.connected_workers(@tenant)

    for i <- 1..3 do
      {:ok, _} = WorkerRegistry.dispatch_task(@tenant, "search", %{"i" => i}, from_pid: self())
    end

    assert collect(:push_tool_task, 3) |> Enum.uniq() == ["dr-b"]
  end
end
