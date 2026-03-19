# Automaton

A chat-based builder for **AI-enabled workflows**.

Users describe what they want in natural language. Automaton generates deterministic workflow code — real Elixir modules with loops, conditionals, and integrations — where some steps call out to an LLM for reasoning. The product is the builder; the engine executes what it generates.

## What Works Today

The workflow engine foundation: **trigger → LLM call → output**, with event-sourced audit trail and multi-tenant data model.

- **Agents** are database rows with a system prompt, model config, and lifecycle status
- **Runs** execute synchronously via Oban workers, with every step logged as a RunEvent
- **Multi-tenancy** from day one — every row has `tenant_id`, API keys per tenant

### Example: Release Notes Generator

```bash
docker compose run --rm app mix gen_release_notes --since "7 days ago"
```

## Local Development

```bash
cp .env.example .env
# Set ANTHROPIC_API_KEY in .env

docker compose up -d db
docker compose run --rm app mix do deps.get, ecto.setup
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

All mix commands run through docker compose — no local Elixir install needed.

## Design Docs

- `docs/architecture.md` — runtime model, workflow engine design, product direction
- `docs/orchestration-path.md` — Temporal-compatible, Elixir-first strategy
- `docs/decision-log.md` — architecture decisions and open questions
- `docs/ux.md` — chat-first UX vision (not yet implemented)
- `docs/plan-workflow-engine.md` — current implementation plan

## Tech Stack

- Elixir / Phoenix
- PostgreSQL
- Oban (background jobs)
- Req (HTTP client for Anthropic API)
- Docker Compose for local dev
