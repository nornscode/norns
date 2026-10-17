defmodule Norns.Workers.WorkerRegistryDeltaTest do
  @moduledoc """
  LLM dispatch with a history delta: the change goes only to the connection
  it was computed for, and only if that worker said it keeps history.
  """

  use ExUnit.Case, async: false

  alias Norns.Workers.WorkerRegistry

  @tenant 9_001
  @task %{
    model: "m",
    messages: [%{role: "user", content: "hi"}, %{role: "assistant", content: "yo"}],
    run_id: 1,
    step: 2
  }
  @delta %{base_count: 1, drop: 0, append: [%{role: "assistant", content: "yo"}]}

  setup do
    on_exit(fn ->
      for id <- ["caching", "plain", "other"], do: WorkerRegistry.unregister_worker(@tenant, id)
    end)

    :ok
  end

  test "a caching worker gets the delta when it is the connection the delta was built for" do
    :ok =
      WorkerRegistry.register_worker(@tenant, "caching", self(), [],
        capabilities: [:llm],
        features: [:message_cache]
      )

    {:ok, task_id, %{worker: pid, caches?: true}} =
      WorkerRegistry.dispatch_llm_task(@tenant, @task, from_pid: self(), delta: {self(), @delta})

    assert pid == self()
    assert_receive {:llm_task, %{task_id: ^task_id, messages_delta: @delta} = task}
    refute Map.has_key?(task, :messages)
  end

  test "the full list goes out when the delta was built for another connection" do
    :ok =
      WorkerRegistry.register_worker(@tenant, "caching", self(), [],
        capabilities: [:llm],
        features: [:message_cache]
      )

    other = spawn(fn -> :ok end)

    {:ok, task_id, %{caches?: true}} =
      WorkerRegistry.dispatch_llm_task(@tenant, @task, from_pid: self(), delta: {other, @delta})

    assert_receive {:llm_task, %{task_id: ^task_id, messages: [_, _]} = task}
    refute Map.has_key?(task, :messages_delta)
  end

  test "a run stays on the worker holding its history instead of rotating away" do
    :ok =
      WorkerRegistry.register_worker(@tenant, "caching", self(), [],
        capabilities: [:llm],
        features: [:message_cache]
      )

    other = spawn(fn -> Process.sleep(:infinity) end)

    :ok =
      WorkerRegistry.register_worker(@tenant, "other", other, [],
        capabilities: [:llm],
        features: [:message_cache]
      )

    # Three steps in a row with a delta built for this connection: round-robin
    # alone would send some of them to the other worker as full lists.
    for _ <- 1..3 do
      {:ok, task_id, %{worker: pid}} =
        WorkerRegistry.dispatch_llm_task(@tenant, @task, from_pid: self(), delta: {self(), @delta})

      assert pid == self()
      assert_receive {:llm_task, %{task_id: ^task_id, messages_delta: @delta}}
    end

    Process.exit(other, :kill)
  end

  test "a worker without the feature gets the full list and is reported as not caching" do
    :ok = WorkerRegistry.register_worker(@tenant, "plain", self(), [], capabilities: [:llm])

    {:ok, task_id, %{worker: pid, caches?: false}} =
      WorkerRegistry.dispatch_llm_task(@tenant, @task, from_pid: self(), delta: {self(), @delta})

    assert pid == self()
    assert_receive {:llm_task, %{task_id: ^task_id, messages: [_, _]} = task}
    refute Map.has_key?(task, :messages_delta)
  end

  test "with no worker the task is queued and nobody is recorded as holding it" do
    # Gard-strict: no worker claims this gard, so nothing can take it.
    {:ok, _task_id, %{worker: nil, caches?: false}} =
      WorkerRegistry.dispatch_llm_task(9_002, @task,
        from_pid: self(),
        gard: 424_242,
        delta: {self(), @delta}
      )
  end
end
