defmodule Automaton.DataCase do
  @moduledoc "Test case template for tests that need database access."

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Automaton.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Automaton.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Automaton.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "Create a default tenant for tests."
  def create_tenant(attrs \\ %{}) do
    {:ok, tenant} =
      Automaton.Tenants.create_tenant(
        Map.merge(
          %{name: "Test Tenant", slug: "test-#{System.unique_integer([:positive])}", api_keys: %{"anthropic" => "test-key"}},
          attrs
        )
      )

    tenant
  end

  @doc "Create a test agent."
  def create_agent(tenant, attrs \\ %{}) do
    {:ok, agent} =
      Automaton.Agents.create_agent(
        Map.merge(
          %{
            tenant_id: tenant.id,
            name: "test-agent-#{System.unique_integer([:positive])}",
            system_prompt: "You are a test agent.",
            status: "idle"
          },
          attrs
        )
      )

    agent
  end
end
