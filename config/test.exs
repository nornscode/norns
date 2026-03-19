import Config

database_url =
  System.get_env("TEST_DATABASE_URL") ||
    "ecto://#{System.get_env("POSTGRES_USER", "automaton")}:#{System.get_env("POSTGRES_PASSWORD", "automaton")}@#{System.get_env("POSTGRES_HOST", "localhost")}/automaton_test#{System.get_env("MIX_TEST_PARTITION")}"

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
