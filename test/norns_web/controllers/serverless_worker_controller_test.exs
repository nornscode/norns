defmodule NornsWeb.ServerlessWorkerControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.Workers.{HttpSignature, WorkerRegistry}

  @tool %{
    "name" => "fetch_page",
    "description" => "Fetch a page",
    "input_schema" => %{"type" => "object"}
  }

  setup %{conn: conn} do
    Norns.WakeStub.install()
    tenant = create_tenant()
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant}
  end

  # The sandbox rolls the row back at test end, but the registry's copy of the
  # declaration is in memory and would outlive the test; withdraw it too.
  defp create(conn, attrs \\ %{}) do
    params =
      Map.merge(
        %{
          "worker_id" => "fn-#{System.unique_integer([:positive])}",
          "wake_url" => "https://fn.example.com/wake",
          "tools" => [@tool],
          "capabilities" => ["llm", "tools"]
        },
        attrs
      )

    resp = post(conn, "/api/v1/serverless_workers", params)
    data = json_response(resp, 201)["data"]
    tenant_id = resp.assigns.current_tenant.id
    on_exit(fn -> WorkerRegistry.unregister_serverless_worker(tenant_id, data["worker_id"]) end)
    data
  end

  test "create returns the secret once; later reads omit it", %{conn: conn} do
    data = create(conn)
    assert String.length(data["secret"]) == 43
    assert data["awake"] == false

    shown = json_response(get(conn, "/api/v1/serverless_workers/#{data["id"]}"), 200)["data"]
    refute Map.has_key?(shown, "secret")

    [listed] = json_response(get(conn, "/api/v1/serverless_workers"), 200)["data"]
    assert listed["worker_id"] == data["worker_id"]
    refute Map.has_key?(listed, "secret")
  end

  test "a client-supplied secret is ignored", %{conn: conn} do
    data = create(conn, %{"secret" => "attacker-chosen"})
    refute data["secret"] == "attacker-chosen"
  end

  test "validates the URL, tools and capabilities", %{conn: conn} do
    conn1 =
      post(conn, "/api/v1/serverless_workers", %{"worker_id" => "a", "wake_url" => "ftp://x"})

    assert %{"error" => %{"wake_url" => _}} = json_response(conn1, 422)

    conn2 =
      post(conn, "/api/v1/serverless_workers", %{
        "worker_id" => "b",
        "wake_url" => "https://x.test",
        "tools" => [%{"name" => "no_schema"}]
      })

    assert %{"error" => %{"tools" => _}} = json_response(conn2, 422)

    conn3 =
      post(conn, "/api/v1/serverless_workers", %{
        "worker_id" => "c",
        "wake_url" => "https://x.test",
        "capabilities" => ["gpu"]
      })

    assert %{"error" => %{"capabilities" => _}} = json_response(conn3, 422)
  end

  test "worker_id is unique per tenant", %{conn: conn} do
    create(conn, %{"worker_id" => "dup"})

    conn =
      post(conn, "/api/v1/serverless_workers", %{
        "worker_id" => "dup",
        "wake_url" => "https://x.test"
      })

    assert %{"error" => %{"worker_id" => _}} = json_response(conn, 422)
  end

  test "declared tools show in the tenant's tool list until the worker is disabled or deleted",
       %{conn: conn} do
    data = create(conn)

    names = fn ->
      conn
      |> get("/api/v1/tools")
      |> json_response(200)
      |> Map.get("data")
      |> Enum.map(& &1["name"])
    end

    assert "fetch_page" in names.()

    patch(conn, "/api/v1/serverless_workers/#{data["id"]}", %{"enabled" => false})
    Process.sleep(20)
    refute "fetch_page" in names.()

    patch(conn, "/api/v1/serverless_workers/#{data["id"]}", %{"enabled" => true})
    assert "fetch_page" in names.()

    assert response(delete(conn, "/api/v1/serverless_workers/#{data["id"]}"), 204)
    Process.sleep(20)
    refute "fetch_page" in names.()
  end

  test "awake reflects a connected incarnation", %{conn: conn, tenant: tenant} do
    data = create(conn)
    # Declared, never woken, nothing connected.
    assert %{"awake" => false, "last_woken_at" => nil} =
             json_response(get(conn, "/api/v1/serverless_workers/#{data["id"]}"), 200)["data"]

    :ok = WorkerRegistry.register_worker(tenant.id, data["worker_id"], self(), [@tool])

    assert json_response(get(conn, "/api/v1/serverless_workers/#{data["id"]}"), 200)["data"][
             "awake"
           ] == true

    assert [%{"serverless" => true}] = json_response(get(conn, "/api/v1/workers"), 200)["data"]

    WorkerRegistry.unregister_worker(tenant.id, data["worker_id"])
  end

  test "POST /wake sends a signed wake now", %{conn: conn} do
    data = create(conn)

    assert %{"status" => "waking"} =
             json_response(post(conn, "/api/v1/serverless_workers/#{data["id"]}/wake"), 202)[
               "data"
             ]

    wid = data["worker_id"]
    assert_receive {:wake, %{worker_id: ^wid, body: body, signature: signature}}, 1_000
    assert :ok = HttpSignature.verify(data["secret"], body, signature)
  end

  test "is tenant-scoped", %{conn: conn} do
    data = create(conn)

    other =
      authenticated_conn(
        Phoenix.ConnTest.build_conn(),
        create_tenant(%{api_keys: %{"norns" => "other-key"}})
      )

    assert json_response(get(other, "/api/v1/serverless_workers/#{data["id"]}"), 404)
    assert json_response(get(other, "/api/v1/serverless_workers"), 200)["data"] == []
  end
end
