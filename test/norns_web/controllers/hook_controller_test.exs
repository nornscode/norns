defmodule NornsWeb.HookControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.{Hooks, Runs}
  alias Norns.TestWorker.LLM

  setup %{conn: conn} do
    tenant = create_tenant()
    agent = create_agent(tenant)
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant, agent: agent}
  end

  defp create_hook(conn, agent, attrs \\ %{}) do
    params =
      Map.merge(
        %{"agent_id" => agent.id, "name" => "hook-#{System.unique_integer([:positive])}"},
        attrs
      )

    json_response(post(conn, "/api/v1/hooks", params), 201)["data"]
  end

  defp await_completion(_agent_id) do
    receive do
      {:completed, _} -> :ok
      {:error, _} -> :ok
    after
      5000 -> flunk("run did not finish")
    end
  end

  describe "management CRUD" do
    test "creates a hook with a server-generated token", %{conn: conn, agent: agent} do
      data = create_hook(conn, agent)

      assert String.length(data["token"]) == 43
      assert data["path"] == "/api/v1/hooks/#{data["token"]}"
      assert data["signature_type"] == "none"
      assert data["enabled"] == true
    end

    test "a signature type requires a secret", %{conn: conn, agent: agent} do
      conn =
        post(conn, "/api/v1/hooks", %{
          "agent_id" => agent.id,
          "name" => "gh",
          "signature_type" => "github"
        })

      assert %{"error" => %{"signing_secret" => _}} = json_response(conn, 422)
    end

    test "a client-supplied token is ignored", %{conn: conn, agent: agent} do
      data = create_hook(conn, agent, %{"token" => "attacker-chosen"})
      refute data["token"] == "attacker-chosen"
    end

    test "list and show are tenant-scoped", %{conn: conn, agent: agent} do
      created = create_hook(conn, agent)

      other = create_tenant()
      other_agent = create_agent(other)
      {:ok, theirs} = Hooks.create_hook(%{tenant_id: other.id, agent_id: other_agent.id, name: "theirs"})

      assert %{"data" => [%{"id" => id}]} = json_response(get(conn, "/api/v1/hooks"), 200)
      assert id == created["id"]
      assert json_response(get(conn, "/api/v1/hooks/#{theirs.id}"), 404)
    end

    test "update can disable; delete removes", %{conn: conn, agent: agent} do
      %{"id" => id} = create_hook(conn, agent)

      assert %{"data" => %{"enabled" => false}} =
               json_response(patch(conn, "/api/v1/hooks/#{id}", %{"enabled" => false}), 200)

      assert response(delete(conn, "/api/v1/hooks/#{id}"), 204)
      assert json_response(get(conn, "/api/v1/hooks/#{id}"), 404)
    end
  end

  describe "ingest" do
    test "a delivery starts a webhook-triggered run; payload is the message", %{conn: conn, agent: agent} do
      %{"token" => token} = create_hook(conn, agent)

      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "handled"}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

      # No auth header — ingest is public, the token is the credential.
      conn =
        Phoenix.ConnTest.build_conn()
        |> post("/api/v1/hooks/#{token}", %{"event" => "invoice.paid", "amount" => 42})

      assert %{"status" => "accepted", "run_id" => run_id} = json_response(conn, 202)
      await_completion(agent.id)

      run = Runs.get_run!(run_id)
      assert run.trigger_type == "webhook"
      assert run.input["user_message"] =~ "invoice.paid"
      assert run.input["user_message"] =~ "42"
    end

    test "message_path extracts a field; conversation_key_path keys history", %{conn: conn, agent: agent} do
      %{"token" => token} =
        create_hook(conn, agent, %{
          "message_path" => "Body",
          "conversation_key_path" => "From"
        })

      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "one"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "two"}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

      post(Phoenix.ConnTest.build_conn(), "/api/v1/hooks/#{token}", %{
        "From" => "+15551234567",
        "Body" => "first text"
      })

      await_completion(agent.id)

      post(Phoenix.ConnTest.build_conn(), "/api/v1/hooks/#{token}", %{
        "From" => "+15551234567",
        "Body" => "second text"
      })

      await_completion(agent.id)

      # Same sender → same conversation → the second call sees history.
      [first, second] = LLM.calls()
      assert length(first.messages) == 1
      assert length(second.messages) == 3
      assert %{"content" => "first text"} = hd(first.messages)
    end

    test "unknown and disabled tokens read identically", %{conn: conn, agent: agent} do
      %{"id" => id, "token" => token} = create_hook(conn, agent)
      patch(conn, "/api/v1/hooks/#{id}", %{"enabled" => false})

      unknown = post(Phoenix.ConnTest.build_conn(), "/api/v1/hooks/nope", %{"a" => 1})
      disabled = post(Phoenix.ConnTest.build_conn(), "/api/v1/hooks/#{token}", %{"a" => 1})

      assert json_response(unknown, 404) == json_response(disabled, 404)
    end

    test "a signed hook rejects bad and missing signatures, accepts valid ones", %{conn: conn, agent: agent} do
      secret = "gh_secret"

      %{"token" => token} =
        create_hook(conn, agent, %{"signature_type" => "github", "signing_secret" => secret})

      body = Jason.encode!(%{"action" => "opened"})

      unsigned =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/hooks/#{token}", body)

      assert json_response(unsigned, 401)["error"] == "missing_signature"

      forged =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=" <> String.duplicate("0", 64))
        |> post("/api/v1/hooks/#{token}", body)

      assert json_response(forged, 401)["error"] == "invalid_signature"

      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "ok"}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

      mac = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

      signed =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=" <> mac)
        |> post("/api/v1/hooks/#{token}", body)

      assert %{"run_id" => _} = json_response(signed, 202)
      await_completion(agent.id)
    end

    test "ingest does not require tenant auth but management does", %{agent: agent, conn: conn} do
      %{"token" => _token} = create_hook(conn, agent)

      unauthed = get(Phoenix.ConnTest.build_conn(), "/api/v1/hooks")
      assert unauthed.status in [401, 403]
    end
  end
end
