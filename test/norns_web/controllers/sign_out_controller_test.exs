defmodule NornsWeb.SignOutControllerTest do
  use NornsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    tenant = create_tenant()
    conn = Plug.Test.init_test_session(conn, %{tenant_id: tenant.id})
    %{conn: conn, tenant: tenant}
  end

  test "signed-in dashboard shows a sign out button", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/workers")
    assert html =~ "sign out"
  end

  test "signed-out dashboard does not show a sign out button" do
    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/workers")
    refute html =~ "sign out"
  end

  test "POST /sign-out drops the session and redirects home", %{conn: conn} do
    conn = post(conn, "/sign-out")
    assert redirected_to(conn) == "/"

    {:ok, _view, html} = live(recycle(conn), "/workers")
    assert html =~ "Not authenticated"
  end
end
