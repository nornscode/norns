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

  def update(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(id, tenant.id) do
      attrs = Map.drop(params, ["id", "tenant_id"])

      case Agents.update_agent(agent, attrs) do
        {:ok, agent} ->
          json(conn, %{data: NornsWeb.JSON.agent(agent)})

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: format_errors(changeset)})
      end
    end
  end

  @doc """
  Archive an agent. The runs stay — this retires the definition, it does not
  erase the history.
  """
  def delete(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant
    force = Map.get(params, "force") in [true, "true"]

    with {:ok, agent} <- fetch_agent(id, tenant.id) do
      case Agents.archive(tenant.id, agent.id, force: force) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :active_run} ->
          conn
          |> put_status(409)
          |> json(%{error: "agent has an active run — pass force=true to archive anyway"})

        {:error, _} ->
          conn |> put_status(404) |> json(%{error: "not found"})
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

  def send_message(conn, %{"agent_id" => agent_id, "content" => content} = params) do
    tenant = conn.assigns.current_tenant
    conversation_key = Map.get(params, "conversation_key")
    context = Map.get(params, "context")
    opts = if is_binary(conversation_key) and conversation_key != "", do: [conversation_key: conversation_key], else: []
    opts = if is_map(context), do: Keyword.put(opts, :context, context), else: opts

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id),
         {:ok, opts} <- put_gard_opt(opts, tenant.id, Map.get(params, "gard_id")) do
      case Registry.send_message(tenant.id, agent.id, content, opts) do
        {:ok, run_id} -> conn |> put_status(202) |> json(%{status: "accepted", run_id: run_id})
        {:error, :busy} -> conn |> put_status(409) |> json(%{error: "agent is busy"})
        {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    end
  end

  def send_message(conn, %{"agent_id" => _}) do
    conn |> put_status(422) |> json(%{error: "missing required field: content"})
  end

  # A gard id from another tenant (or a typo) would create a run no worker can
  # ever serve — reject it as not-found rather than letting it queue to timeout.
  defp put_gard_opt(opts, _tenant_id, nil), do: {:ok, opts}

  defp put_gard_opt(opts, tenant_id, gard_id) do
    case Norns.Gards.get_gard(tenant_id, gard_id) do
      nil -> {:error, :not_found}
      gard -> {:ok, Keyword.put(opts, :gard_id, gard.id)}
    end
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
