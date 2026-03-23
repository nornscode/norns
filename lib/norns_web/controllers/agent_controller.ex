defmodule NornsWeb.AgentController do
  use NornsWeb, :controller

  alias Norns.{Agents, Runs}
  alias Norns.Agents.{Process, Registry}

  def index(conn, _params) do
    tenant = conn.assigns.current_tenant
    agents = Agents.list_agents(tenant.id)
    json(conn, %{data: Enum.map(agents, &NornsWeb.JSON.agent/1)})
  end

  def create(conn, params) do
    tenant = conn.assigns.current_tenant
    attrs = Map.put(params, "tenant_id", tenant.id)

    case Agents.create_agent(attrs) do
      {:ok, agent} ->
        conn |> put_status(201) |> json(%{data: NornsWeb.JSON.agent(agent)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(id, tenant.id) do
      json(conn, %{data: NornsWeb.JSON.agent(agent)})
    end
  end

  def start(conn, %{"agent_id" => agent_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id) do
      tools = Norns.Tools.Registry.all_tools()
      case Registry.start_agent(agent.id, tenant.id, tools: tools) do
        {:ok, _pid} ->
          json(conn, %{status: "started"})

        {:error, {:already_started, _}} ->
          conn |> put_status(409) |> json(%{error: "agent already running"})

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    end
  end

  def stop(conn, %{"agent_id" => agent_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id) do
      case Registry.stop_agent(tenant.id, agent.id) do
        :ok -> json(conn, %{status: "stopped"})
        {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "agent not running"})
      end
    end
  end

  def status(conn, %{"agent_id" => agent_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id) do
      case Registry.lookup(tenant.id, agent.id) do
        {:ok, pid} ->
          state = Process.get_state(pid)
          json(conn, %{data: state})

        :error ->
          json(conn, %{data: %{status: :stopped, agent_id: agent.id}})
      end
    end
  end

  def send_message(conn, %{"agent_id" => agent_id, "content" => content}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id) do
      case Registry.send_message(tenant.id, agent.id, content) do
        :ok -> conn |> put_status(202) |> json(%{status: "accepted"})
        {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "agent not running"})
      end
    end
  end

  def send_message(conn, %{"agent_id" => _}) do
    conn |> put_status(422) |> json(%{error: "missing required field: content"})
  end

  def runs(conn, %{"agent_id" => agent_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id) do
      runs = Runs.list_runs(agent.id)
      json(conn, %{data: Enum.map(runs, &NornsWeb.JSON.run/1)})
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

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Override action/2 to handle {:error, :not_found} from with clauses
  def action(conn, _) do
    args = [conn, conn.params]

    case apply(__MODULE__, action_name(conn), args) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      conn ->
        conn
    end
  end
end
