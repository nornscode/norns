defmodule Norns.Workers.ResumeAgents do
  @moduledoc """
  Finds runs with status "running" that have no live process and resumes them.
  Called on application boot.
  """

  require Logger

  import Ecto.Query

  alias Norns.Repo
  alias Norns.Runs.Run
  alias Norns.Agents.Registry

  def resume_orphans do
    orphaned_runs()
    |> Enum.each(fn run ->
      Logger.info("Resuming orphaned run #{run.id} for agent #{run.agent_id}")

      case Registry.resume_agent(run.id, run.agent_id, run.tenant_id) do
        {:ok, _pid} ->
          Logger.info("Successfully resumed run #{run.id}")

        {:error, reason} ->
          Logger.error("Failed to resume run #{run.id}: #{inspect(reason)}")
      end
    end)
  end

  defp orphaned_runs do
    Run
    |> where([r], r.status == "running")
    |> Repo.all()
    |> Enum.reject(fn run ->
      Registry.alive?(run.tenant_id, run.agent_id)
    end)
  end
end
