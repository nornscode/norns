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

config :norns, NornsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix",
  server: false

# Wakes for serverless workers go to a Req.Test plug instead of the network,
# and the re-wake cooldown is short enough to observe in a test.
config :norns, :wake_req_options, plug: {Req.Test, Norns.Workers.Wake}
config :norns, :wake_cooldown_ms, 150

config :logger, level: :warning
