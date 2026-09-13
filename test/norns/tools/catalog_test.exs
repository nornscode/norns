defmodule Norns.Tools.CatalogTest do
  use Norns.DataCase, async: false

  alias Norns.Agents.ToolPolicy
  alias Norns.Tools.Catalog
  alias Norns.Tools.Tool
  alias Norns.Workers.WorkerRegistry

  # Unique tenant ids per test keep the shared registry from cross-talking.
  defp tenant_id, do: System.unique_integer([:positive]) + 200_000

  defp tool_def(name), do: %{"name" => name, "description" => name, "input_schema" => %{}}
  defp tool(name), do: %Tool{name: name, description: name, input_schema: %{}}
  defp names(tools), do: Enum.map(tools, & &1.name)

  test "built-ins are always there and a worker cannot displace one" do
    tid = tenant_id()
    :ok = WorkerRegistry.register_worker(tid, "w", self(), [tool_def("ask_human"), tool_def("search")])

    tools = Catalog.for_tenant(tid)

    assert "search" in names(tools)
    # One entry per name, and the surviving ask_human is the orchestrator's.
    assert Enum.count(tools, &(&1.name == "ask_human")) == 1
    assert Enum.find(tools, &(&1.name == "ask_human")).source == :builtin

    WorkerRegistry.unregister_worker(tid, "w")
  end

  test "gard-filtered, because a list is a promise that dispatch can reach the tool" do
    tid = tenant_id()
    :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("plain_tool")])
    :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("gard_tool")], gard: 7)

    assert "plain_tool" in names(Catalog.for_tenant(tid))
    refute "gard_tool" in names(Catalog.for_tenant(tid))

    assert "gard_tool" in names(Catalog.for_tenant(tid, gard: 7))
    refute "plain_tool" in names(Catalog.for_tenant(tid, gard: 7))

    WorkerRegistry.unregister_worker(tid, "plain")
    WorkerRegistry.unregister_worker(tid, "garded")
  end

  test "the policy filters the agent's own and the worker's tools, never the built-ins" do
    tid = tenant_id()
    :ok = WorkerRegistry.register_worker(tid, "w", self(), [tool_def("allowed"), tool_def("denied")])
    policy = %ToolPolicy{mode: :allowlist, allowed_tools: ["allowed", "mine"]}

    tools = Catalog.for_tenant(tid, policy: policy, extra: [tool("mine"), tool("not_mine")])
    names = names(tools)

    assert "allowed" in names
    assert "mine" in names
    refute "denied" in names
    refute "not_mine" in names

    # Built-ins are orchestrator semantics, not part of what a policy selects.
    assert "ask_human" in names
    assert "wait" in names

    WorkerRegistry.unregister_worker(tid, "w")
  end

  test "with no worker of its own, a tenant still has the built-ins and the agent's own" do
    tid = tenant_id()
    names = names(Catalog.for_tenant(tid, extra: [tool("mine")]))

    assert "mine" in names
    assert "ask_human" in names

    # No tool worker for this tenant, yet LLM dispatch is available: it falls
    # back to :default-tenant workers and tool dispatch does not. The pair is
    # coherent, and a caller reading an empty tool list needs to know that.
    assert %{workers_connected: 0, llm_available: true} = Catalog.availability(tid)
  end
end
