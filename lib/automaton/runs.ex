defmodule Automaton.Runs do
  @moduledoc """
  Context for durable workflow runs and their event logs.
  """

  import Ecto.Query

  alias Automaton.Repo
  alias Automaton.Runs.{Run, RunEvent}

  def get_run(id), do: Repo.get(Run, id)
  def get_run!(id), do: Repo.get!(Run, id)

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
    Repo.transaction(fn ->
      sequence = next_sequence(run.id)

      params =
        attrs
        |> Map.new()
        |> Map.put(:run_id, run.id)
        |> Map.put(:tenant_id, run.tenant_id)
        |> Map.put(:sequence, sequence)

      case %RunEvent{} |> RunEvent.changeset(params) |> Repo.insert() do
        {:ok, event} -> event
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def list_events(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], asc: e.sequence)
    |> Repo.all()
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
end
