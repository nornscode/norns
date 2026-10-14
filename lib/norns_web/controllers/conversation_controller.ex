defmodule NornsWeb.ConversationController do
  use NornsWeb, :controller

  alias Norns.{Agents, Conversations}
  alias Norns.Agents.Registry, as: AgentRegistry

  def index(conn, %{"agent_id" => agent_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id) do
      conversations = Conversations.list_conversations(agent.id)
      json(conn, %{data: Enum.map(conversations, &NornsWeb.JSON.conversation/1)})
    end
  end

  def show(conn, %{"agent_id" => agent_id, "key" => key}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id),
         %{} = conversation <- Conversations.get_conversation_by_agent_key(agent.id, key) do
      json(conn, %{data: NornsWeb.JSON.conversation(conversation)})
    else
      nil -> conn |> put_status(404) |> json(%{error: "not found"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def delete(conn, %{"agent_id" => agent_id, "key" => key}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id),
         %{} = conversation <- Conversations.get_conversation_by_agent_key(agent.id, key),
         {:ok, _conversation} <- Conversations.delete_conversation(conversation) do
      # A deleted conversation should have no live process. One left running
      # holds the row it was started with, so the next message on the thread
      # routes into a process whose conversation is gone and 500s — the
      # thread stays wedged until the process ages out (issue #8). Stopping
      # it means the next message starts fresh and re-creates the row.
      AgentRegistry.stop_agent(tenant.id, agent.id, key)

      json(conn, %{status: "deleted"})
    else
      nil -> conn |> put_status(404) |> json(%{error: "not found"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  defp fetch_agent(id, tenant_id) do
    agent = Agents.get_agent!(id)

    if agent.tenant_id == tenant_id do
      {:ok, agent}
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
