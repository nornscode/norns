import Config

database_url =
  System.get_env("TEST_DATABASE_URL") ||
    "ecto://#{System.get_env("POSTGRES_USER", "norns")}:#{System.get_env("POSTGRES_PASSWORD", "norns")}@#{System.get_env("POSTGRES_HOST", "localhost")}/norns_test#{System.get_env("MIX_TEST_PARTITION")}"

config :norns, Norns.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :norns, Oban,
  repo: Norns.Repo,
  plugins: false,
  queues: false,
  testing: :inline

config :norns, Norns.LLM, module: Norns.LLM.Fake

config :logger, level: :warning
