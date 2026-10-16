import Config

config :logger, level: :info

# Serve digested asset paths (app-<hash>.css) so edge and browser caches
# never hand out a stale stylesheet after a deploy. phx.digest writes the
# manifest during assets.deploy.
config :norns, NornsWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
