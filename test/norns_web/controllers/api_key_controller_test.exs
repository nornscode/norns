defmodule NornsWeb.ApiKeyControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.{Gards, Tenants}

  setup %{conn: conn} do
    tenant = create_tenant()
    {:ok, gard} = Gards.create_gard(%{tenant_id: tenant.id, name: "box"})
    %{conn: authenticated_conn(conn, tenant), tenant: tenant, gard: gard}
  end

  defp scope(gard, caps \\ ["tools"]), do: %{"kind" => "worker", "gard_id" => gard.id, "capabilities" => caps}

  defp scoped_conn(token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  describe "POST /api/v1/api_keys" do
    test "issues a worker key and returns the token exactly once", %{conn: conn, gard: gard} do
      conn = post(conn, "/api/v1/api_keys", %{name: "box-worker", scope: scope(gard)})

      assert %{"data" => %{"name" => "box-worker", "token" => "nrnw_" <> _, "scope" => returned}} =
               json_response(conn, 201)

      assert returned == %{"kind" => "worker", "gard_id" => gard.id, "capabilities" => ["tools"]}

      [listed] = json_response(get(recycle(conn), "/api/v1/api_keys"), 200)["data"]
      assert listed["name"] == "box-worker"
      refute Map.has_key?(listed, "token")
    end

    test "rejects a scope it cannot honour", %{conn: conn, gard: gard} do
      conn = post(conn, "/api/v1/api_keys", %{name: "k", scope: Map.put(scope(gard), "gard_id", gard.id + 100_000)})
      assert %{"error" => %{"scope" => ["gard not found"]}} = json_response(conn, 422)

      conn = post(recycle(conn), "/api/v1/api_keys", %{name: "k"})
      assert %{"error" => %{"scope" => _}} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/v1/api_keys/:name" do
    test "revokes the key; the token stops working", %{conn: conn, tenant: tenant, gard: gard} do
      {:ok, key} = Tenants.create_api_key(tenant.id, %{name: "k", scope: scope(gard)})

      assert response(delete(conn, "/api/v1/api_keys/k"), 204)
      assert json_response(delete(recycle(conn), "/api/v1/api_keys/k"), 404)

      assert :error = Tenants.authenticate(key.token)
      assert json_response(get(scoped_conn(key.token), "/api/v1/runs"), 401)
    end
  end

  describe "a scoped key on the REST API" do
    # Join the worker socket and serve tasks, nothing else: a key read out of
    # a gard's process environment must not be able to create runs, read
    # conversations, redefine agents, message agents, or mint another key.
    test "is refused everywhere with 403, not 401", %{tenant: tenant, gard: gard} do
      {:ok, key} = Tenants.create_api_key(tenant.id, %{name: "k", scope: scope(gard, ["llm", "tools"])})
      agent = create_agent(tenant)

      attempts = [
        {:get, "/api/v1/runs"},
        {:get, "/api/v1/agents"},
        {:post, "/api/v1/agents/#{agent.id}/messages", %{content: "hi"}},
        {:get, "/api/v1/agents/#{agent.id}/conversations"},
        {:get, "/api/v1/triggers"},
        {:get, "/api/v1/gards"},
        {:get, "/api/v1/tools"},
        {:get, "/api/v1/workers"},
        {:get, "/api/v1/api_keys"},
        {:post, "/api/v1/api_keys", %{name: "another", scope: scope(gard)}}
      ]

      for attempt <- attempts do
        conn =
          case attempt do
            {:get, path} -> get(scoped_conn(key.token), path)
            {:post, path, body} -> post(scoped_conn(key.token), path, body)
          end

        assert %{"error" => "forbidden"} = json_response(conn, 403), "#{inspect(attempt)} was not refused"
      end

      # And the scoped key minted nothing.
      assert Enum.map(Tenants.list_api_keys(tenant.id), & &1.name) == ["k"]
    end
  end
end
