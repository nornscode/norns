defmodule Norns.Runs.Introspection do
  @moduledoc """
  What an agent sees of the tenant's other runs: the `list_runs` and
  `inspect_run` built-ins.

  Both are reads over the event log, scoped to the caller's tenant, and both
  return small, fixed-shape maps. A run's raw log is too large for a model's
  context, so `inspect_run` hands back `Norns.Runs.TraceSummary` plus the
  run's task and outcome, each truncated. The summary's sequence ranges stay
  in the output so a human (or a future tool) can drill into the full log.
  """

  alias Norns.{Agents, Repo, Runs}
  alias Norns.Runs.Run

  @statuses ~w(pending running waiting completed failed)
  @default_limit 20
  @max_limit 50
  @list_excerpt 200
  @inspect_excerpt 1000

  @doc """
  The tenant's runs, newest first.

  Options (string keys, as the model sends them): `"agent_name"`, `"status"`
  and `"limit"` (default #{@default_limit}, capped at #{@max_limit}).

  Returns `{:ok, runs}` or `{:error, reason}`, where reason is
  `"unknown_agent"` or `"invalid_status"`.
  """
  def list_runs(tenant_id, args) when is_map(args) do
    with {:ok, agent_id} <- resolve_agent(tenant_id, args["agent_name"]),
         {:ok, status} <- validate_status(args["status"]) do
      runs =
        tenant_id
        |> Runs.list_runs_for_tenant(agent_id: agent_id, status: status, limit: limit(args["limit"]))
        |> Repo.preload(:agent)
        |> Enum.map(&list_entry/1)

      {:ok, runs}
    end
  end

  def list_runs(tenant_id, _args), do: list_runs(tenant_id, %{})

  @doc """
  One run in detail: the trace summary, the task it was given, its output or
  error, and the question it is parked on, if any.

  Returns `{:ok, map}` or `{:error, "run_not_found"}`. A run in another
  tenant is reported as not found.
  """
  def inspect_run(tenant_id, run_id) do
    with {:ok, id} <- parse_id(run_id),
         %Run{tenant_id: ^tenant_id} = run <- Runs.get_run(id),
         {:ok, summary} <- Runs.trace_summary(id) do
      {:ok,
       summary
       |> Map.put(:task, run |> task() |> truncate(@inspect_excerpt))
       |> Map.put(:output, outcome(run, @inspect_excerpt))
       |> Map.put(:pending_question, pending_question(run))}
    else
      _ -> {:error, "run_not_found"}
    end
  end

  defp list_entry(run) do
    %{
      "run_id" => run.id,
      "agent" => run.agent && run.agent.name,
      "status" => run.status,
      "trigger" => run.trigger_type,
      "parent_run_id" => run.parent_run_id,
      "started_at" => run.inserted_at,
      "updated_at" => run.updated_at,
      "task" => run |> task() |> truncate(@list_excerpt),
      "output" => outcome(run, @list_excerpt),
      "pending_question" => pending_question(run)
    }
  end

  defp resolve_agent(_tenant_id, name) when name in [nil, ""], do: {:ok, nil}

  defp resolve_agent(tenant_id, name) when is_binary(name) do
    case Agents.get_agent_by_name(tenant_id, name) do
      nil -> {:error, "unknown_agent"}
      agent -> {:ok, agent.id}
    end
  end

  defp resolve_agent(_tenant_id, _name), do: {:error, "unknown_agent"}

  defp validate_status(status) when status in [nil, ""], do: {:ok, nil}
  defp validate_status(status) when status in @statuses, do: {:ok, status}
  defp validate_status(_), do: {:error, "invalid_status"}

  defp limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp limit(_), do: @default_limit

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp task(%Run{input: %{"user_message" => msg}}) when is_binary(msg), do: msg
  defp task(_), do: nil

  defp outcome(%Run{status: "completed", output: output}, max), do: truncate(output, max)

  defp outcome(%Run{status: "failed", failure_metadata: meta}, max) do
    case meta do
      %{"error" => error} when is_binary(error) -> truncate("error: " <> error, max)
      _ -> "error"
    end
  end

  defp outcome(_run, _max), do: nil

  defp pending_question(%Run{status: "waiting"} = run) do
    case Runs.pending_question(run) do
      %{"question" => q} when is_binary(q) -> q
      _ -> nil
    end
  end

  defp pending_question(_run), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "… (truncated)", else: str
  end

  defp truncate(_other, _max), do: nil
end
