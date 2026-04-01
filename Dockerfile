# Build stage
FROM elixir:1.18-otp-27-alpine AS build

RUN apk add --no-cache git build-base

WORKDIR /app

ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Cache deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy app source
COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

# Compile and build assets
RUN mix compile
RUN mix tailwind.install
RUN mix assets.deploy
RUN mix release

# Runtime stage
FROM elixir:1.18-otp-27-alpine AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs postgresql-client

WORKDIR /app

ENV MIX_ENV=prod
ENV PORT=4000

COPY --from=build /app/_build/prod/rel/norns ./

# Migration script
COPY --from=build /app/priv/repo/migrations ./priv/repo/migrations

# Entrypoint: run migrations then start
COPY <<'EOF' /app/entrypoint.sh
#!/bin/sh
set -e

echo "Running migrations..."
./bin/norns eval "Norns.Release.migrate()"
echo "Migrations complete."

echo "Starting Norns on port ${PORT}..."
exec ./bin/norns start
EOF

RUN chmod +x /app/entrypoint.sh

EXPOSE 4000

CMD ["/app/entrypoint.sh"]
