defmodule NornsWeb.SessionController do
  @moduledoc """
  Sessions: every conversation across every agent and gard, with its latest
  run and the live state of its process. The list a client draws in a
  sidebar; `show` adds the messages.
  """

  use NornsWeb, :controller

  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.Agents.Registry
  alias Norns.Conversations

  def index(conn, params) do
    tenant = conn.assigns.current_tenant
    limit = parse_limit(Map.get(params, "limit"))
    archived = Map.get(params, "archived") in [true, "true"]

    sessions =
      tenant.id
      |> Conversations.list_sessions(limit: limit, archived: archived)
      |> Enum.map(&session_json(&1, tenant.id, false))

    json(conn, %{data: sessions})
  end

  @doc """
  Archive a session: out of the list, and it stays out across restarts. The
  messages, runs, and events are untouched — `restore` brings it back, and
  `show` reads it in the meantime.
  """
  def delete(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant
    force = Map.get(params, "force") in [true, "true"]

    case Conversations.archive(tenant.id, id, force: force) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :active_run} ->
        conn
        |> put_status(409)
        |> json(%{error: "session has an active run — pass force=true to archive anyway"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  @doc "Name a session. An empty title clears it."
  def update(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant

    case Conversations.rename(tenant.id, id, Map.get(params, "title")) do
      :ok -> json(conn, %{data: session_json(Conversations.get_session(tenant.id, id), tenant.id, false)})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  @doc "Take an archived session back out. See `delete`."
  def restore(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    case Conversations.restore(tenant.id, id) do
      :ok -> json(conn, %{data: session_json(Conversations.get_session(tenant.id, id), tenant.id, false)})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    case Conversations.get_session(tenant.id, id) do
      nil -> conn |> put_status(404) |> json(%{error: "not found"})
      session -> json(conn, %{data: session_json(session, tenant.id, true)})
    end
  rescue
    Ecto.Query.CastError -> conn |> put_status(404) |> json(%{error: "not found"})
  end

  defp session_json(%{conversation: c, run: run}, tenant_id, with_messages?) do
    base = %{
      id: c.id,
      key: c.key,
      agent_id: c.agent_id,
      agent_name: c.agent && c.agent.name,
      gard_id: run && run.gard_id,
      message_count: c.message_count,
      summary: c.summary,
      title: c.title,
      status: live_status(tenant_id, c),
      run: run && NornsWeb.JSON.run(run),
      # The first user turn, as content: the client renders a title from
      # it. Core forwards it whole rather than truncating what it must not
      # read.
      first_message: first_user_content(c.messages),
      archived_at: c.archived_at,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }

    if with_messages? do
      # Messages carry the run they belong to; these are how each of those
      # runs ended, so a client can draw the same boundaries whether it
      # watched the session happen or opened it afterwards. Envelope only.
      base
      |> Map.put(:messages, c.messages)
      |> Map.put(:runs, Norns.Conversations.run_outcomes(c.id))
    else
      base
    end
  end

  defp live_status(tenant_id, conversation) do
    case Registry.lookup(tenant_id, conversation.agent_id, conversation.key) do
      {:ok, pid} ->
        try do
          AgentProcess.get_state(pid).status
        catch
          :exit, _ -> "unknown"
        end

      :error ->
        "stopped"
    end
  end

  defp first_user_content(messages) when is_list(messages) do
    Enum.find_value(messages, fn
      %{"role" => "user", "content" => content} -> content
      %{role: "user", content: content} -> content
      _ -> nil
    end)
  end

  defp first_user_content(_), do: nil

  defp parse_limit(nil), do: 100

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, 500)
      _ -> 100
    end
  end

  defp parse_limit(_), do: 100
end
