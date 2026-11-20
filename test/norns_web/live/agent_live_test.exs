defmodule NornsWeb.AgentLiveTest do
  use NornsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    tenant = create_tenant()
    conn = Plug.Test.init_test_session(conn, %{tenant_id: tenant.id})
    %{conn: conn, tenant: tenant}
  end

  describe "system prompt" do
    test "a short prompt is shown whole, with no toggle", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant, %{system_prompt: "You are a test agent."})

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}")

      refute has_element?(view, "button[phx-click=toggle_prompt]")
      refute has_element?(view, "#system-prompt.overflow-hidden")
    end

    test "a long prompt starts clamped and expands on request", %{conn: conn, tenant: tenant} do
      prompt = Enum.map_join(1..40, "\n", &"Rule #{&1}: do the thing.")
      agent = create_agent(tenant, %{system_prompt: prompt})

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}")

      assert has_element?(view, "#system-prompt.overflow-hidden")
      assert has_element?(view, "button[phx-click=toggle_prompt]", "show all")

      view |> element("button[phx-click=toggle_prompt]") |> render_click()

      refute has_element?(view, "#system-prompt.overflow-hidden")
      assert has_element?(view, "button[phx-click=toggle_prompt]", "collapse")
      assert render(view) =~ "Rule 40: do the thing."

      view |> element("button[phx-click=toggle_prompt]") |> render_click()

      assert has_element?(view, "#system-prompt.overflow-hidden")
    end
  end
end
