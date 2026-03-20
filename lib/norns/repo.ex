defmodule Norns.Repo do
  use Ecto.Repo,
    otp_app: :norns,
    adapter: Ecto.Adapters.Postgres
end
