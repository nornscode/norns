defmodule Norns.Repo.Migrations.AddLastWokenAtToServerlessWorkers do
  use Ecto.Migration

  def change do
    alter table(:serverless_workers) do
      # When Norns last sent this worker a wake. Kept here as well as in the
      # registry so a restart does not turn every sleeping worker into
      # "never woken".
      add :last_woken_at, :utc_datetime_usec
    end
  end
end
