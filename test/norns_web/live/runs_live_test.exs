defmodule NornsWeb.RunsLiveTest do
  use NornsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    tenant = create_tenant()
    conn = Plug.Test.init_test_session(conn, %{tenant_id: tenant.id})
    %{conn: conn, tenant: tenant}
  end

  defp create_run(tenant, agent, attrs \\ %{}) do
    {:ok, run} =
      Norns.Runs.create_run(
        Map.merge(
          %{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed"},
          attrs
        )
      )

    run
  end

  test "asks for a token when not authenticated" do
    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/runs")
    assert html =~ "Not authenticated"
  end

  test "lists runs across agents", %{conn: conn, tenant: tenant} do
    alpha = create_agent(tenant, %{name: "alpha"})
    beta = create_agent(tenant, %{name: "beta"})
    a = create_run(tenant, alpha, %{input: %{"user_message" => "hello alpha"}})
    b = create_run(tenant, beta)

    {:ok, view, _html} = live(conn, "/runs")

    assert has_element?(view, "#run-#{a.id}", "alpha")
    assert has_element?(view, "#run-#{a.id}", "hello alpha")
    assert has_element?(view, "#run-#{b.id}", "beta")
  end

  test "does not show another tenant's runs", %{conn: conn} do
    other = create_tenant()
    run = create_run(other, create_agent(other))

    {:ok, view, _html} = live(conn, "/runs")
    refute has_element?(view, "#run-#{run.id}")
  end

  test "filters by agent and status from the query string", %{conn: conn, tenant: tenant} do
    alpha = create_agent(tenant, %{name: "alpha"})
    beta = create_agent(tenant, %{name: "beta"})
    done = create_run(tenant, alpha)
    failed = create_run(tenant, alpha, %{status: "failed"})
    other = create_run(tenant, beta)

    {:ok, view, _html} = live(conn, "/runs?agent_id=#{alpha.id}")
    assert has_element?(view, "#run-#{done.id}")
    assert has_element?(view, "#run-#{failed.id}")
    refute has_element?(view, "#run-#{other.id}")

    {:ok, view, _html} = live(conn, "/runs?agent_id=#{alpha.id}&status=failed")
    refute has_element?(view, "#run-#{done.id}")
    assert has_element?(view, "#run-#{failed.id}")
  end

  test "changing the filter patches the URL", %{conn: conn, tenant: tenant} do
    alpha = create_agent(tenant, %{name: "alpha"})
    beta = create_agent(tenant, %{name: "beta"})
    a = create_run(tenant, alpha)
    b = create_run(tenant, beta)

    {:ok, view, _html} = live(conn, "/runs")

    view
    |> form("#runs-filter", %{"agent_id" => to_string(beta.id), "status" => ""})
    |> render_change()

    assert_patch(view, "/runs?agent_id=#{beta.id}")
    refute has_element?(view, "#run-#{a.id}")
    assert has_element?(view, "#run-#{b.id}")
  end

  test "ignores a malformed filter", %{conn: conn, tenant: tenant} do
    run = create_run(tenant, create_agent(tenant))

    {:ok, view, _html} = live(conn, "/runs?agent_id=nope&status=bogus")
    assert has_element?(view, "#run-#{run.id}")
  end
end
