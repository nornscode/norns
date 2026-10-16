defmodule NornsWeb.RunWebhookControllerTest do
  use NornsWeb.ConnCase, async: false

  setup %{conn: conn} do
    Norns.RunWebhookStub.install()
    tenant = create_tenant()
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant}
  end

  defp create(conn, attrs \\ %{}) do
    params = Map.merge(%{"url" => "https://channel.example.com/norns/events"}, attrs)
    json_response(post(conn, "/api/v1/run_webhooks", params), 201)["data"]
  end

  test "create returns the secret once; later reads omit it", %{conn: conn} do
    data = create(conn)
    assert String.length(data["secret"]) == 43
    assert data["events"] == ["run.waiting", "run.completed", "run.failed"]
    assert data["enabled"] == true

    shown = json_response(get(conn, "/api/v1/run_webhooks/#{data["id"]}"), 200)["data"]
    refute Map.has_key?(shown, "secret")

    [listed] = json_response(get(conn, "/api/v1/run_webhooks"), 200)["data"]
    assert listed["id"] == data["id"]
    refute Map.has_key?(listed, "secret")
  end

  test "a client-supplied secret is ignored", %{conn: conn} do
    data = create(conn, %{"secret" => "attacker-chosen"})
    refute data["secret"] == "attacker-chosen"
  end

  test "validates the URL and events", %{conn: conn} do
    assert %{"error" => %{"url" => _}} =
             json_response(post(conn, "/api/v1/run_webhooks", %{"url" => "ftp://x"}), 422)

    assert %{"error" => %{"events" => _}} =
             json_response(
               post(conn, "/api/v1/run_webhooks", %{"url" => "https://x.test", "events" => ["nope"]}),
               422
             )
  end

  test "update narrows events and disables; delete removes", %{conn: conn} do
    data = create(conn)

    updated =
      json_response(
        patch(conn, "/api/v1/run_webhooks/#{data["id"]}", %{"events" => ["run.waiting"], "enabled" => false}),
        200
      )["data"]

    assert updated["events"] == ["run.waiting"]
    assert updated["enabled"] == false

    assert response(delete(conn, "/api/v1/run_webhooks/#{data["id"]}"), 204)
    assert json_response(get(conn, "/api/v1/run_webhooks/#{data["id"]}"), 404)
  end

  test "is tenant-scoped", %{conn: conn} do
    mine = create(conn)

    {:ok, theirs} =
      Norns.Runs.RunWebhooks.create_run_webhook(%{
        tenant_id: create_tenant().id,
        url: "https://theirs.example.com/events"
      })

    assert json_response(get(conn, "/api/v1/run_webhooks/#{theirs.id}"), 404)
    assert json_response(patch(conn, "/api/v1/run_webhooks/#{theirs.id}", %{"enabled" => false}), 404)
    assert json_response(delete(conn, "/api/v1/run_webhooks/#{theirs.id}"), 404)

    assert [%{"id" => id}] = json_response(get(conn, "/api/v1/run_webhooks"), 200)["data"]
    assert id == mine["id"]
  end

  test "POST /test delivers a sample event and reports the answer", %{conn: conn} do
    data = create(conn)

    assert %{"data" => %{"status" => "delivered"}} =
             json_response(post(conn, "/api/v1/run_webhooks/#{data["id"]}/test"), 200)

    assert_receive {:run_webhook, %{event: "run.test", body: body}}, 2000
    assert %{"type" => "run.test", "status" => "test"} = Jason.decode!(body)

    Norns.RunWebhookStub.install(500)

    assert %{"data" => %{"status" => "rejected", "http_status" => 500}} =
             json_response(post(conn, "/api/v1/run_webhooks/#{data["id"]}/test"), 502)
  end
end
