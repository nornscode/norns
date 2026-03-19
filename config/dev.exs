import Config

# Runtime values are loaded from environment variables when present.
# .env can be loaded by your shell or direnv before running mix tasks.
database_url = System.get_env("DATABASE_URL") || "ecto://automaton:automaton@localhost/automaton_dev"

config :automaton, Automaton.Repo,
  url: database_url,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

config :automaton, Oban,
  repo: Automaton.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [default: 10]

# Disable live-reload file watcher — no web UI yet, and containers lack inotify-tools.
config :phoenix_live_view, enable_expensive_runtime_checks: false

# No web UI yet — skip tailwind.
config :tailwind, version: "4.1.12"

# Default logger to info to avoid noisy SQL debug output in mix tasks.
config :logger, level: :info
