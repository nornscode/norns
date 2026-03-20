defmodule Norns.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Norns.Repo,
      {Oban, Application.fetch_env!(:norns, Oban)}
    ]

    opts = [strategy: :one_for_one, name: Norns.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
