defmodule Norns.Conversations do
  @moduledoc "Conversation persistence and lookup."

  import Ecto.Query

  alias Norns.Conversations.Conversation
  alias Norns.Repo

  @doc """
  Every conversation of a tenant, newest first, each with its agent and its
  latest run. This is the session list a client shows: one row per
  conversation across every agent and gard.

  Conversations of archived agents are left out — retiring an agent is how
  you clear its sessions from the sidebar. They remain reachable by id.

  Archived sessions are left out too, unless `archived: true`, which lists
  only those: the drawer you go to when you want one back.
  """
  def list_sessions(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    archived? = Keyword.get(opts, :archived, false)

    conversations =
      Conversation
      |> join(:inner, [c], a in Norns.Agents.Agent, on: a.id == c.agent_id)
      |> where([c, a], c.tenant_id == ^tenant_id and is_nil(a.archived_at))
      |> archived_filter(archived?)
      |> order_by([c], desc: c.updated_at)
      |> limit(^limit)
      |> preload(:agent)
      |> Repo.all()

    with_latest_runs(conversations)
  end

  defp archived_filter(query, true), do: where(query, [c], not is_nil(c.archived_at))
  defp archived_filter(query, _), do: where(query, [c], is_nil(c.archived_at))

  @doc """
  Put a session away, or take it back out.

  Between closing a tab and deleting a conversation there was nothing.
  This is the middle: the session leaves the list and does not come back on
  restart, while its messages, runs, and events stay untouched — so it can
  be restored, and it is still readable by id in the meantime.

  Refuses while its latest run is in flight unless `force: true`. Archiving
  a session someone is waiting on is almost always a mistake.
  """
  def archive(tenant_id, id, opts \\ []), do: set_archived(tenant_id, id, DateTime.utc_now(), opts)

  @doc "Take a session back out of the archive. See `archive/3`."
  def restore(tenant_id, id), do: set_archived(tenant_id, id, nil, force: true)

  defp set_archived(tenant_id, id, at, opts) do
    force = Keyword.get(opts, :force, false)

    with %Conversation{} = conversation <- Repo.get_by(Conversation, id: id, tenant_id: tenant_id),
         false <- not force and has_active_run?(id) do
      {1, _} = Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [archived_at: at])

      # An archived session should not keep a process alive. Nothing is in
      # flight to lose: either no run is active, or the caller forced it.
      if at, do: Norns.Agents.Registry.stop_agent(tenant_id, conversation.agent_id, conversation.key)

      :ok
    else
      nil -> {:error, :not_found}
      true -> {:error, :active_run}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp has_active_run?(conversation_id) do
    Repo.exists?(
      from r in Norns.Runs.Run,
        where: r.conversation_id == ^conversation_id and r.status in ["pending", "running", "waiting"]
    )
  end

  @doc "One conversation of a tenant with its agent and latest run, or nil."
  def get_session(tenant_id, id) do
    case Repo.get_by(Conversation, id: id, tenant_id: tenant_id) do
      nil -> nil
      conversation -> conversation |> Repo.preload(:agent) |> List.wrap() |> with_latest_runs() |> hd()
    end
  end

  @doc """
  How each run of a conversation ended: id and status, oldest first.

  The envelope of the history — no content — for clients rendering run
  boundaries in a transcript they did not watch being made.
  """
  def run_outcomes(conversation_id) do
    from(r in Norns.Runs.Run,
      where: r.conversation_id == ^conversation_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      select: %{id: r.id, status: r.status}
    )
    |> Repo.all()
  end

  defp with_latest_runs([]), do: []

  defp with_latest_runs(conversations) do
    ids = Enum.map(conversations, & &1.id)

    latest =
      from(r in Norns.Runs.Run,
        where: r.conversation_id in ^ids,
        distinct: r.conversation_id,
        order_by: [asc: r.conversation_id, desc: r.inserted_at, desc: r.id]
      )
      |> Repo.all()
      |> Map.new(&{&1.conversation_id, &1})

    Enum.map(conversations, fn c -> %{conversation: c, run: Map.get(latest, c.id)} end)
  end

  def list_conversations(agent_id) do
    Conversation
    |> where([c], c.agent_id == ^agent_id)
    |> order_by([c], desc: c.updated_at)
    |> Repo.all()
  end

  def get_conversation(id), do: Repo.get(Conversation, id)
  def get_conversation!(id), do: Repo.get!(Conversation, id)

  def get_conversation_by_agent_key(agent_id, key) do
    Conversation
    |> where([c], c.agent_id == ^agent_id and c.key == ^key)
    |> Repo.one()
  end

  def get_conversation_by_agent_key!(agent_id, key) do
    Conversation
    |> where([c], c.agent_id == ^agent_id and c.key == ^key)
    |> Repo.one!()
  end

  def create_conversation(attrs) do
    attrs = with_message_metrics(attrs)

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conversation, attrs) do
    attrs = with_message_metrics(attrs)

    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  def delete_conversation(%Conversation{} = conversation) do
    Repo.delete(conversation)
  end

  def find_or_create_conversation(agent_id, tenant_id, key, attrs \\ %{}) do
    case get_conversation_by_agent_key(agent_id, key) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        attrs =
          attrs
          |> Map.new()
          |> Map.put(:agent_id, agent_id)
          |> Map.put(:tenant_id, tenant_id)
          |> Map.put(:key, key)

        create_conversation(attrs)
    end
  end

  defp with_message_metrics(attrs) do
    attrs = Map.new(attrs)

    case Map.fetch(attrs, :messages) do
      {:ok, messages} when is_list(messages) ->
        attrs
        |> Map.put_new(:message_count, length(messages))
        |> Map.put_new(:token_estimate, estimate_tokens(messages))

      _ ->
        attrs
    end
  end

  defp estimate_tokens(messages) do
    messages
    |> Enum.map(&message_size/1)
    |> Enum.sum()
    |> Kernel.div(4)
  end

  defp message_size(%{content: content}), do: encoded_size(content)
  defp message_size(%{"content" => content}), do: encoded_size(content)
  defp message_size(_message), do: 0

  defp encoded_size(content) do
    content
    |> Jason.encode!()
    |> byte_size()
  end
end
