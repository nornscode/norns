defmodule Norns.Runs.Cancel do
  @moduledoc """
  Stop a run that is under way.

  The process that owns the run does the work (`Norns.Agents.Process.cancel/2`):
  it fails the run with the policy code `cancelled`, sends the same broadcast
  as any other failure, so the dashboard, the agent channel and run webhooks
  all hear `run.failed`, and goes idle for the conversation's next message.
  A task already dispatched to a worker finishes there; its result comes back
  as a stale `task_result` and is dropped.

  A run with no live process (orphaned by a crash, before `ResumeAgents` has
  picked it up) is failed here directly, with the same event, metadata and
  notifications, so a caller cannot tell the two apart.
  """

  alias Norns.Runs
  alias Norns.Runs.RunWebhooks
  alias Norns.Runtime.{Errors, Events, EventValidator}

  @message "Cancelled by user"

  @doc "The error a cancelled run fails with."
  def error, do: Errors.classify({:policy, :cancelled, @message})

  @doc """
  Cancel `run`. `{:ok, run}` with the run as it now stands; `{:error, :finished}`
  if it had already completed or failed.
  """
  def cancel(%Runs.Run{status: status}) when status in ["completed", "failed"], do: {:error, :finished}

  def cancel(%Runs.Run{} = run) do
    case Norns.Agents.Registry.cancel_run(run.tenant_id, run) do
      :ok -> {:ok, Runs.get_run!(run.id)}
      {:error, :not_running} -> cancel_orphan(run)
      {:error, reason} -> {:error, reason}
    end
  end

  # No process holds the run. Do what the process would have done, minus the
  # conversation bookkeeping it alone owns.
  defp cancel_orphan(run) do
    error = error()

    payload =
      error
      |> Errors.to_metadata()
      |> Map.put("retry_decision", "terminal")

    {:ok, event} = Events.run_failed(payload)
    {:ok, _} = Runs.append_event(run, event)

    {:ok, run} =
      Runs.update_run(run, %{
        status: "failed",
        failure_metadata: Map.put(payload, "schema_version", EventValidator.schema_version())
      })

    notification = %{error: error.message, agent_id: run.agent_id, run_id: run.id}
    Phoenix.PubSub.broadcast(Norns.PubSub, "agent:#{run.agent_id}", {:error, notification})
    RunWebhooks.notify(run.tenant_id, run, :error, notification)
    {:ok, run}
  end
end
