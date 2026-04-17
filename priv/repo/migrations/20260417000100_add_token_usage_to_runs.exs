defmodule Norns.Repo.Migrations.AddTokenUsageToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
    end
  end
end
