defmodule NornsWeb.RunController do
  use NornsWeb, :controller

  alias Norns.Runs
  alias Norns.Agents.Registry

  def index(conn, params) do
    tenant = conn.assigns.current_tenant
    limit = params["limit"] && String.to_integer(params["limit"]) || 50
    runs = Runs.list_runs_for_tenant(tenant.id, limit: limit)
    json(conn, %{data: Enum.map(runs, &NornsWeb.JSON.run/1)})
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, run} <- fetch_run(id, tenant.id) do
      json(conn, %{data: NornsWeb.JSON.run(run)})
    end
  end

  def retry(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, run} <- fetch_run(id, tenant.id) do
      message = get_in(run.input, ["user_message"])

      cond do
        run.status not in ["failed", "completed"] ->
          conn |> put_status(409) |> json(%{error: "run is still in progress"})

        is_nil(message) ->
          conn |> put_status(422) |> json(%{error: "run has no user_message to retry"})

        true ->
          case Registry.send_message(tenant.id, run.agent_id, message) do
            {:ok, run_id} ->
              conn |> put_status(202) |> json(%{status: "accepted", run_id: run_id})

            {:error, :busy} ->
              conn |> put_status(409) |> json(%{error: "agent is busy"})

            {:error, reason} ->
              conn |> put_status(500) |> json(%{error: inspect(reason)})
          end
      end
    end
  end

  def events(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, _run} <- fetch_run(id, tenant.id) do
      events = Runs.list_events(String.to_integer(id))
      json(conn, %{data: Enum.map(events, &NornsWeb.JSON.run_event/1)})
    end
  end

  defp fetch_run(id, tenant_id) do
    run = Runs.get_run!(id)

    if run.tenant_id == tenant_id do
      {:ok, run}
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def action(conn, _) do
    case apply(__MODULE__, action_name(conn), [conn, conn.params]) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      conn ->
        conn
    end
  end
end
