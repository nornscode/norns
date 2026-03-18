import Config

database_url =
  System.get_env("TEST_DATABASE_URL") ||
    "ecto://automaton:change_me_to_a_long_random_password@localhost/automaton_test#{System.get_env("MIX_TEST_PARTITION")}"

config :automaton, Automaton.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :automaton, Oban,
  repo: Automaton.Repo,
  plugins: false,
  queues: false,
  testing: :inline

config :logger, level: :warning
