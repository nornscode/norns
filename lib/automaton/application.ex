defmodule Automaton.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Automaton.Repo,
      {Oban, Application.fetch_env!(:automaton, Oban)}
    ]

    opts = [strategy: :one_for_one, name: Automaton.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
