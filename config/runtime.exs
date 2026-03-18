import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing"

  config :automaton, Automaton.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  # Kept for future Phoenix endpoint config.
  config :automaton, :secrets,
    secret_key_base: secret_key_base,
    phx_host: System.get_env("PHX_HOST") || "example.com",
    port: String.to_integer(System.get_env("PORT") || "4000")
end
