defmodule Mix.Tasks.GenReleaseNotes do
  @moduledoc """
  Generate release notes from git history using an AI agent.

  ## Usage

      mix gen_release_notes --since "3 days ago"
      mix gen_release_notes                       # defaults to 7 days
  """

  use Mix.Task

  @shortdoc "Generate release notes from recent git commits"

  @system_prompt """
  You are a release notes writer. Given a list of git commits, produce clean,
  user-facing release notes grouped by category (Features, Fixes, Improvements,
  Chores). Be concise. Skip merge commits and trivial formatting changes.
  Output markdown.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [since: :string])
    since = Keyword.get(opts, :since, "7 days ago")

    commits = get_git_log(since)

    if commits == "" do
      Mix.shell().info("No commits found since #{since}.")
    else
      Mix.shell().info("Found commits since #{since}. Running agent...\n")
      run_agent(commits)
    end
  end

  defp get_git_log(since) do
    {output, 0} = System.cmd("git", ["log", "--oneline", "--no-merges", "--since=#{since}"])
    String.trim(output)
  end

  defp run_agent(commits) do
    {:ok, tenant} = Norns.Tenants.ensure_default_tenant()
    agent = ensure_agent(tenant)

    # Insert the Oban job — in test/dev with inline mode, this runs synchronously.
    %{"agent_id" => agent.id, "tenant_id" => tenant.id, "input" => commits}
    |> Norns.Workers.RunAgent.new()
    |> Oban.insert!()

    # With inline testing mode the job already ran. In dev, drain the queue.
    unless Application.get_env(:norns, Oban)[:testing] == :inline do
      Oban.drain_queue(queue: :agents)
    end

    # Fetch the most recent completed run for this agent.
    import Ecto.Query

    run =
      Norns.Runs.Run
      |> where([r], r.agent_id == ^agent.id and r.status == "completed")
      |> order_by([r], desc: r.inserted_at)
      |> limit(1)
      |> Norns.Repo.one()

    case run do
      %{output: output} when is_binary(output) ->
        Mix.shell().info(output)

      _ ->
        Mix.shell().error("Agent run did not produce output. Check logs.")
    end
  end

  defp ensure_agent(tenant) do
    case Norns.Agents.get_agent_by_name(tenant.id, "release-notes-generator") do
      nil ->
        {:ok, agent} =
          Norns.Agents.create_agent(%{
            tenant_id: tenant.id,
            name: "release-notes-generator",
            purpose: "Generate user-facing release notes from git commit history",
            status: "idle",
            system_prompt: @system_prompt,
            model: "claude-sonnet-4-20250514"
          })

        agent

      agent ->
        agent
    end
  end
end
