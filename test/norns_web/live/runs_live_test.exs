defmodule NornsWeb.RunsLiveTest do
  use NornsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Norns.Runs

  setup %{conn: conn} do
    tenant = create_tenant()
    conn = Plug.Test.init_test_session(conn, %{tenant_id: tenant.id})
    %{conn: conn, tenant: tenant}
  end

  defp create_run(tenant, agent, status, attrs \\ %{}) do
    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "message", status: status},
          attrs
        )
      )

    run
  end

  test "sends a visitor without a session to sign in" do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(Phoenix.ConnTest.build_conn(), "/runs")
  end

  test "says so when there are no runs", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ "No runs"
  end

  test "lists runs from every agent, linked to the run and its agent", %{
    conn: conn,
    tenant: tenant
  } do
    a1 = create_agent(tenant, %{name: "alpha-agent"})
    a2 = create_agent(tenant, %{name: "beta-agent"})

    {:ok, conversation} =
      Norns.Conversations.find_or_create_conversation(a1.id, tenant.id, "slack-thread-9")

    r1 = create_run(tenant, a1, "completed", %{conversation_id: conversation.id})
    r2 = create_run(tenant, a2, "running", %{trigger_type: "cron"})

    {:ok, view, html} = live(conn, "/runs")

    assert html =~ "alpha-agent"
    assert html =~ "beta-agent"
    assert html =~ "slack-thread-9"
    assert html =~ "cron"
    assert has_element?(view, ~s(#run-#{r1.id} a[href="/runs/#{r1.id}"]))
    assert has_element?(view, ~s(#run-#{r1.id} a[href="/agents/#{a1.id}"]), "alpha-agent")
    assert has_element?(view, ~s(#run-#{r2.id} a[href="/runs/#{r2.id}"]))
    assert has_element?(view, ~s(#run-#{r2.id} a[href="/agents/#{a2.id}"]), "beta-agent")
  end

  test "shows nothing from another tenant", %{conn: conn, tenant: tenant} do
    mine = create_run(tenant, create_agent(tenant), "running")
    other = create_tenant()
    theirs = create_run(other, create_agent(other, %{name: "someone-elses-agent"}), "running")

    {:ok, view, html} = live(conn, "/runs")

    assert has_element?(view, "#run-#{mine.id}")
    refute has_element?(view, "#run-#{theirs.id}")
    refute html =~ "someone-elses-agent"
  end

  test "filters by status and agent through the URL", %{conn: conn, tenant: tenant} do
    a1 = create_agent(tenant)
    a2 = create_agent(tenant)
    pending = create_run(tenant, a1, "pending")
    running = create_run(tenant, a2, "running")
    failed = create_run(tenant, a1, "failed")
    waiting = create_run(tenant, a2, "waiting")

    {:ok, view, _html} = live(conn, "/runs")

    view |> element("#runs-filter") |> render_change(%{"status" => "running", "agent" => ""})
    assert_patch(view, "/runs?status=running")
    assert has_element?(view, "#run-#{pending.id}")
    assert has_element?(view, "#run-#{running.id}")
    refute has_element?(view, "#run-#{failed.id}")
    refute has_element?(view, "#run-#{waiting.id}")

    view
    |> element("#runs-filter")
    |> render_change(%{"status" => "running", "agent" => "#{a2.id}"})

    assert_patch(view, "/runs?status=running&agent=#{a2.id}")
    assert has_element?(view, "#run-#{running.id}")
    refute has_element?(view, "#run-#{pending.id}")

    {:ok, view, _html} = live(conn, "/runs?status=waiting")
    assert has_element?(view, "#run-#{waiting.id}")
    refute has_element?(view, "#run-#{failed.id}")

    {:ok, view, _html} = live(conn, "/runs?status=all&agent=#{a1.id}")
    assert has_element?(view, "#run-#{failed.id}")
    assert has_element?(view, "#run-#{pending.id}")
    refute has_element?(view, "#run-#{running.id}")
  end

  test "pages 50 at a time", %{conn: conn, tenant: tenant} do
    agent = create_agent(tenant)
    [oldest | _] = for _ <- 1..51, do: create_run(tenant, agent, "completed")

    {:ok, view, _html} = live(conn, "/runs")
    refute has_element?(view, "#run-#{oldest.id}")

    view |> element("a", "older") |> render_click()
    assert_patch(view, "/runs?page=2")
    assert has_element?(view, "#run-#{oldest.id}")
    assert has_element?(view, "a", "newer")
  end

  test "picks up a run as its agent starts it", %{conn: conn, tenant: tenant} do
    agent = create_agent(tenant)
    {:ok, view, _html} = live(conn, "/runs")

    run = create_run(tenant, agent, "running")
    refute has_element?(view, "#run-#{run.id}")

    Phoenix.PubSub.broadcast(
      Norns.PubSub,
      "agent:#{agent.id}",
      {:agent_started, %{run_id: run.id}}
    )

    # Same sender, so the broadcast is handled before this returns.
    :sys.get_state(view.pid)
    assert has_element?(view, "#run-#{run.id}")
  end

  test "appears in the nav", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ ~s(href="/runs")
  end
end
