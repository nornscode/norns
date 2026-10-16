defmodule NornsWeb.WorkersLiveTest do
  use NornsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Norns.Workers.WorkerRegistry

  setup %{conn: conn} do
    tenant = create_tenant()
    conn = Plug.Test.init_test_session(conn, %{tenant_id: tenant.id})
    %{conn: conn, tenant: tenant}
  end

  defp register_worker(tenant, worker_id, opts \\ []) do
    WorkerRegistry.register_worker(
      tenant.id,
      worker_id,
      self(),
      Keyword.get(opts, :tools, []),
      capabilities: Keyword.get(opts, :capabilities, [:tools]),
      gard: Keyword.get(opts, :gard)
    )

    on_exit(fn -> WorkerRegistry.unregister_worker(tenant.id, worker_id) end)
  end

  defp tool_def(name) do
    %{"name" => name, "description" => "does #{name}", "input_schema" => %{"type" => "object"}}
  end

  test "asks for a token when not authenticated" do
    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/workers")
    assert html =~ "Not authenticated"
  end

  test "says so when no worker is connected", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/workers")
    assert html =~ "No workers connected"
  end

  test "lists connected workers with capabilities, tools, and gard", %{conn: conn, tenant: tenant} do
    register_worker(tenant, "slack-connector",
      tools: [tool_def("post_to_slack"), tool_def("list_slack_channels")],
      capabilities: [:llm, :tools]
    )

    register_worker(tenant, "coding-worker", gard: "gard_abc")

    {:ok, _view, html} = live(conn, "/workers")

    assert html =~ "slack-connector"
    assert html =~ "2 tools"
    assert html =~ "post_to_slack, list_slack_channels"
    assert html =~ "llm"
    assert html =~ "coding-worker"
    assert html =~ "gard gard_abc"
    assert html =~ "no tools"
  end

  test "shows a draining worker as draining", %{conn: conn, tenant: tenant} do
    register_worker(tenant, "shutting-down")
    WorkerRegistry.drain_worker(tenant.id, "shutting-down")

    {:ok, _view, html} = live(conn, "/workers")
    assert html =~ "draining"
  end

  test "refresh picks up a worker that connected after mount", %{conn: conn, tenant: tenant} do
    {:ok, view, html} = live(conn, "/workers")
    refute html =~ "late-worker"

    register_worker(tenant, "late-worker")
    assert render_click(view, "refresh") =~ "late-worker"
  end

  test "does not list another tenant's workers", %{conn: conn} do
    other = create_tenant()
    register_worker(other, "other-worker")

    {:ok, _view, html} = live(conn, "/workers")
    refute html =~ "other-worker"
  end
end
