defmodule NornsWeb.AgentChannel do
  use NornsWeb, :channel

  alias Norns.Agents

  @impl true
  def join("agent:" <> agent_id_str, _params, socket) do
    agent_id = String.to_integer(agent_id_str)
    tenant_id = socket.assigns.tenant_id

    # Verify the agent belongs to this tenant
    agent = Agents.get_agent!(agent_id)

    if agent.tenant_id == tenant_id do
      # Subscribe to the agent's PubSub topic for process events
      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent_id}")
      {:ok, assign(socket, :agent_id, agent_id)}
    else
      {:error, %{reason: "not found"}}
    end
  rescue
    Ecto.NoResultsError -> {:error, %{reason: "not found"}}
  end

  @impl true
  def handle_in("send_message", %{"content" => content}, socket) do
    tenant_id = socket.assigns.tenant_id
    agent_id = socket.assigns.agent_id

    case Norns.Agents.Registry.send_message(tenant_id, agent_id, content) do
      {:ok, run_id} -> {:reply, {:ok, %{run_id: run_id}}, socket}
      {:error, :busy} -> {:reply, {:error, %{reason: "agent is busy"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  # Forward PubSub broadcasts from the agent process to the WebSocket client
  @impl true
  def handle_info({event, payload}, socket) when is_atom(event) do
    push(socket, Atom.to_string(event), payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
