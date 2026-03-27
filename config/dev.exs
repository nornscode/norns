import Config

# Runtime values are loaded from environment variables when present.
# .env can be loaded by your shell or direnv before running mix tasks.
database_url = System.get_env("DATABASE_URL") || "ecto://norns:norns@localhost/norns_dev"

config :norns, Norns.Repo,
  url: database_url,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

config :norns, Oban,
  repo: Norns.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [default: 10]

config :norns, NornsWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix",
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:norns, ~w(--watch)]}
  ]

config :norns, NornsWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/norns_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

# Default logger to info to avoid noisy SQL debug output in mix tasks.
config :logger, level: :info
