import Config

config :automaton,
  ecto_repos: [Automaton.Repo]

config :automaton, Automaton.Repo,
  migration_timestamps: [type: :utc_datetime_usec]

config :automaton, Oban,
  repo: Automaton.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ],
  queues: [default: 10]

config :automaton,
  generators: [timestamp_type: :utc_datetime_usec]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
