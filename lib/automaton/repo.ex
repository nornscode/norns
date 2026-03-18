defmodule Automaton.Repo do
  use Ecto.Repo,
    otp_app: :automaton,
    adapter: Ecto.Adapters.Postgres
end
