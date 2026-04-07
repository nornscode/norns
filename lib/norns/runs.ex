defmodule Norns.Runs do
  @moduledoc """
  Context for durable workflow runs and their event logs.
  """

  import Ecto.Query

  alias Norns.Repo
  alias Norns.Runtime.Event
  alias Norns.Runtime.EventValidator
  alias Norns.Runs.{Run, RunEvent}

  def get_run(id), do: Repo.get(Run, id) |> Repo.preload(:conversation)
  def get_run!(id), do: Repo.get!(Run, id) |> Repo.preload(:conversation)

  def list_runs(agent_id) do
    Run
    |> where([r], r.agent_id == ^agent_id)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  def list_runs_for_tenant(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Run
    |> where([r], r.tenant_id == ^tenant_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  def append_event(%Run{} = run, attrs) do
    with {:ok, normalized} <- normalize_event(attrs) do
      Repo.transaction(fn ->
        sequence = next_sequence(run.id)

        params =
          normalized
          |> Map.put(:run_id, run.id)
          |> Map.put(:tenant_id, run.tenant_id)
          |> Map.put(:sequence, sequence)

        case %RunEvent{} |> RunEvent.changeset(params) |> Repo.insert() do
          {:ok, event} -> event
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  def list_events(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], asc: e.sequence)
    |> Repo.all()
  end

  def find_duplicate_side_effect(run_id, idempotency_key) when is_binary(idempotency_key) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> where([e], e.event_type == "tool_result")
    |> where([e], fragment("?->>'idempotency_key' = ?", e.payload, ^idempotency_key))
    |> order_by([e], asc: e.sequence)
    |> limit(1)
    |> Repo.one()
  end

  def find_duplicate_side_effect(_run_id, _idempotency_key), do: nil

  def last_checkpoint(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> where([e], e.event_type in ["checkpoint_saved", "checkpoint"])
    |> order_by([e], desc: e.sequence)
    |> limit(1)
    |> Repo.one()
  end

  def last_event(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], desc: e.sequence)
    |> limit(1)
    |> Repo.one()
  end

  def failure_inspector(%Run{} = run) do
    metadata = run.failure_metadata || %{}

    %{
      "error_class" => metadata["error_class"],
      "error_code" => metadata["error_code"],
      "retry_decision" => metadata["retry_decision"],
      "last_checkpoint" => summarize_event(last_checkpoint(run.id)),
      "last_event" => summarize_event(last_event(run.id))
    }
  end

  defp next_sequence(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> select([e], max(e.sequence))
    |> Repo.one()
    |> case do
      nil -> 1
      n -> n + 1
    end
  end

  defp normalize_event(%Event{} = event), do: EventValidator.validate(event)
  defp normalize_event(attrs) when is_map(attrs), do: EventValidator.validate(attrs)

  defp summarize_event(nil), do: nil

  defp summarize_event(event) do
    %{
      "sequence" => event.sequence,
      "event_type" => event.event_type,
      "payload" => event.payload,
      "inserted_at" => event.inserted_at
    }
  end
end
