defmodule Norns.Triggers do
  @moduledoc """
  Cron triggers: schedules that start runs on agents.

  Norns is the system of record for schedules. A minutely Oban job
  (`Norns.Workers.TriggerScheduler`) calls `fire_due/1`; each due trigger is
  claimed by an atomic `last_fired_at` update so it fires at most once per
  matching minute, then a run starts on the mapped agent with
  `trigger_type: "schedule"`.
  """

  import Ecto.Query

  require Logger

  alias Norns.Repo
  alias Norns.Triggers.Trigger
  alias Norns.Agents.Registry

  def list_triggers(tenant_id) do
    Repo.all(from t in Trigger, where: t.tenant_id == ^tenant_id, order_by: t.id)
  end

  def list_triggers(tenant_id, agent_id) do
    Repo.all(
      from t in Trigger,
        where: t.tenant_id == ^tenant_id and t.agent_id == ^agent_id,
        order_by: t.id
    )
  end

  def get_trigger(tenant_id, id) do
    Repo.get_by(Trigger, id: id, tenant_id: tenant_id)
  end

  def create_trigger(attrs) do
    %Trigger{}
    |> Trigger.changeset(attrs)
    |> Norns.Agents.validate_agent_in_tenant()
    |> Repo.insert()
  end

  def update_trigger(%Trigger{} = trigger, attrs) do
    trigger
    |> Trigger.changeset(attrs)
    |> Norns.Agents.validate_agent_in_tenant()
    |> Repo.update()
  end

  def delete_trigger(%Trigger{} = trigger) do
    Repo.delete(trigger)
  end

  @doc """
  Fire every enabled trigger whose cron matches `minute` (a UTC datetime,
  truncated to the minute by the caller).

  Firing is claim-then-run: `last_fired_at` is advanced with a conditional
  update before the run starts, so a retried or concurrently-running
  scheduler cannot double-fire. Returns `{fired, skipped}` counts.
  """
  def fire_due(minute) do
    triggers = Repo.all(from t in Trigger, where: t.enabled == true)

    Enum.reduce(triggers, {0, 0}, fn trigger, {fired, skipped} ->
      with {:ok, expr} <- parse_cron(trigger),
           true <- Oban.Cron.Expression.now?(expr, minute),
           :claimed <- claim(trigger, minute),
           {:ok, _run_id} <- fire(trigger) do
        {fired + 1, skipped}
      else
        false -> {fired, skipped}
        :already_fired -> {fired, skipped}
        {:error, reason} ->
          Logger.warning("Trigger #{trigger.id} (#{trigger.name}) did not fire: #{inspect(reason)}")
          {fired, skipped + 1}
      end
    end)
  end

  @doc """
  Fire a trigger immediately, outside its schedule. Does not touch
  `last_fired_at` — a manual test firing shouldn't eat the next scheduled one.
  Returns `{:ok, run_id}` or `{:error, reason}`.
  """
  def fire(%Trigger{} = trigger) do
    opts = [trigger_type: "schedule"]

    opts =
      if trigger.conversation_key,
        do: Keyword.put(opts, :conversation_key, trigger.conversation_key),
        else: opts

    Registry.send_message(trigger.tenant_id, trigger.agent_id, trigger.message, opts)
  end

  defp parse_cron(trigger) do
    case Oban.Cron.Expression.parse(trigger.cron) do
      {:ok, expr} -> {:ok, expr}
      {:error, _} -> {:error, :invalid_cron}
    end
  end

  # Atomic claim: only one scheduler run wins a given minute. `last_fired_at`
  # strictly before the minute (or never) is claimable; anything else means a
  # concurrent or earlier scheduler already fired this minute.
  defp claim(trigger, minute) do
    query =
      from t in Trigger,
        where:
          t.id == ^trigger.id and t.enabled == true and
            (is_nil(t.last_fired_at) or t.last_fired_at < ^minute)

    case Repo.update_all(query, set: [last_fired_at: minute, updated_at: DateTime.utc_now()]) do
      {1, _} -> :claimed
      {0, _} -> :already_fired
    end
  end
end
