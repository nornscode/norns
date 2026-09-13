defmodule Norns.GardsTest do
  use Norns.DataCase, async: false

  alias Norns.{Gards, Runs}
  alias Norns.Tools.Idempotency

  setup do
    %{tenant: create_tenant()}
  end

  defp create_gard(tenant, attrs \\ %{}) do
    {:ok, gard} = Gards.create_gard(Map.merge(%{tenant_id: tenant.id, name: "test-gard"}, attrs))
    gard
  end

  describe "create_gard/1" do
    test "generates a server-side claim token and starts pending", %{tenant: tenant} do
      gard = create_gard(tenant)

      assert gard.status == "pending"
      assert is_binary(gard.claim_token)
      # 32 bytes, url-base64, no padding
      assert String.length(gard.claim_token) == 43
    end
  end

  describe "claim/3" do
    test "a valid token claims a pending gard", %{tenant: tenant} do
      gard = create_gard(tenant)

      assert Gards.claim(tenant.id, gard.id, gard.claim_token) == :ok
      assert Gards.get_gard(tenant.id, gard.id).status == "ready"
    end

    test "only one of two claimants wins", %{tenant: tenant} do
      gard = create_gard(tenant)

      assert Gards.claim(tenant.id, gard.id, gard.claim_token) == :ok
      assert Gards.claim(tenant.id, gard.id, gard.claim_token) == {:error, :already_claimed}
    end

    test "a wrong token is rejected", %{tenant: tenant} do
      gard = create_gard(tenant)
      assert Gards.claim(tenant.id, gard.id, "wrong") == {:error, :invalid_claim_token}
      assert Gards.claim(tenant.id, gard.id, nil) == {:error, :invalid_claim_token}
    end

    test "claims are tenant-scoped", %{tenant: tenant} do
      other = create_tenant()
      gard = create_gard(tenant)

      assert Gards.claim(other.id, gard.id, gard.claim_token) == {:error, :not_found}
    end

    test "a destroyed gard cannot be claimed", %{tenant: tenant} do
      gard = create_gard(tenant)
      :ok = Gards.destroy(tenant.id, gard.id)

      assert Gards.claim(tenant.id, gard.id, gard.claim_token) == {:error, :gard_destroyed}
    end

    test "a disconnected gard can be reclaimed", %{tenant: tenant} do
      gard = create_gard(tenant)
      :ok = Gards.claim(tenant.id, gard.id, gard.claim_token)
      :ok = Gards.mark_disconnected(tenant.id, gard.id)

      assert Gards.claim(tenant.id, gard.id, gard.claim_token) == :ok
      assert Gards.get_gard(tenant.id, gard.id).status == "ready"
    end
  end

  describe "mark_disconnected/2" do
    test "is idempotent — both disconnect paths can fire", %{tenant: tenant} do
      gard = create_gard(tenant)
      :ok = Gards.claim(tenant.id, gard.id, gard.claim_token)

      assert Gards.mark_disconnected(tenant.id, gard.id) == :ok
      assert Gards.mark_disconnected(tenant.id, gard.id) == :ok
      assert Gards.get_gard(tenant.id, gard.id).status == "disconnected"
    end

    test "does not resurrect a destroyed gard", %{tenant: tenant} do
      gard = create_gard(tenant)
      :ok = Gards.destroy(tenant.id, gard.id)
      :ok = Gards.mark_disconnected(tenant.id, gard.id)

      assert Gards.get_gard(tenant.id, gard.id).status == "destroyed"
    end
  end

  describe "destroy/3" do
    test "soft-deletes and removes ports; the row survives for run FKs", %{tenant: tenant} do
      gard = create_gard(tenant)
      {:ok, _} = Gards.register_port(gard.id, %{"internal_port" => 3000, "url" => "http://localhost:3000"})

      agent = create_agent(tenant)

      {:ok, run} =
        Runs.create_run(%{
          tenant_id: tenant.id,
          agent_id: agent.id,
          trigger_type: "message",
          status: "completed",
          gard_id: gard.id
        })

      assert Gards.destroy(tenant.id, gard.id) == :ok
      assert Gards.get_gard(tenant.id, gard.id).status == "destroyed"
      assert Gards.list_ports(gard.id) == []
      assert Runs.get_run!(run.id).gard_id == gard.id
    end

    test "refuses while a run is active, unless forced", %{tenant: tenant} do
      gard = create_gard(tenant)
      agent = create_agent(tenant)

      {:ok, _run} =
        Runs.create_run(%{
          tenant_id: tenant.id,
          agent_id: agent.id,
          trigger_type: "message",
          status: "running",
          gard_id: gard.id
        })

      assert Gards.destroy(tenant.id, gard.id) == {:error, :active_run}
      assert Gards.destroy(tenant.id, gard.id, force: true) == :ok
    end
  end

  describe "ports" do
    test "registers and lists ports with valid schemes", %{tenant: tenant} do
      gard = create_gard(tenant)

      {:ok, port} =
        Gards.register_port(gard.id, %{
          "internal_port" => 3000,
          "url" => "https://abc-3000.tunnel.dev",
          "name" => "react"
        })

      assert port.protocol == "http"
      assert [%{internal_port: 3000}] = Gards.list_ports(gard.id)
    end

    test "rejects dangerous URL schemes", %{tenant: tenant} do
      gard = create_gard(tenant)

      assert {:error, changeset} =
               Gards.register_port(gard.id, %{
                 "internal_port" => 3000,
                 "url" => "javascript:alert(1)"
               })

      assert Keyword.has_key?(changeset.errors, :url)
    end

    test "rejects out-of-range ports", %{tenant: tenant} do
      gard = create_gard(tenant)

      assert {:error, _} = Gards.register_port(gard.id, %{"internal_port" => 0})
      assert {:error, _} = Gards.register_port(gard.id, %{"internal_port" => 70_000})
    end
  end

  describe "idempotency keys" do
    test "the gard rides in the key; no-gard keys keep the historical shape" do
      assert Idempotency.key(1, 2, "tc_1", "write_file") ==
               "run:1:step:2:tool:tc_1:name:write_file"

      assert Idempotency.key(1, 2, "tc_1", "write_file", 7) ==
               "run:1:step:2:tool:tc_1:name:write_file:gard:7"
    end

    test "context derives the gard from the run" do
      tool = %Norns.Tools.Tool{
        name: "write_file",
        description: "",
        input_schema: %{},
        side_effect?: true
      }

      tc = %{"id" => "tc_1", "name" => "write_file", "arguments" => %{}}

      ctx = Idempotency.context(%{id: 1, gard_id: 7}, 2, tc, tool)
      assert ctx.idempotency_key == "run:1:step:2:tool:tc_1:name:write_file:gard:7"

      ctx = Idempotency.context(%{id: 1, gard_id: nil}, 2, tc, tool)
      assert ctx.idempotency_key == "run:1:step:2:tool:tc_1:name:write_file"
    end
  end
end
