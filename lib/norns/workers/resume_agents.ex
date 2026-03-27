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
    case orphaned_runs() do
      {:ok, runs} ->
        Enum.each(runs, fn run ->
          Logger.info("Resuming orphaned run #{run.id} for agent #{run.agent_id}")

          conversation_key =
            case run.conversation do
              %{key: key} -> key
              _ -> "default"
            end

          case Registry.resume_agent(run.id, run.agent_id, run.tenant_id,
                 conversation_key: conversation_key
               ) do
            {:ok, _pid} ->
              Logger.info("Successfully resumed run #{run.id}")

            {:error, reason} ->
              Logger.error("Failed to resume run #{run.id}: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.warning("Could not check for orphaned runs: #{inspect(reason)}")
    end
  end

  defp orphaned_runs do
    runs =
      Run
      |> where([r], r.status in ["running", "waiting"])
      |> preload(:conversation)
      |> Repo.all()
      |> Enum.reject(fn run ->
        conversation_key =
          case run.conversation do
            %{key: key} -> key
            _ -> "default"
          end

        Registry.alive?(run.tenant_id, run.agent_id, conversation_key)
      end)

    {:ok, runs}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
