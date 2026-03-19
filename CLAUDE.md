# Automaton

## Project Overview

Agent builder and hosting platform. Currently a working backend that can define agents, execute them against the Anthropic API, and log the results. No UI yet.

## Tech Stack

- **Backend:** Elixir, Phoenix (endpoint not yet wired up)
- **Database:** PostgreSQL (via Ecto)
- **Background Jobs:** Oban
- **LLM:** Anthropic Messages API via Req
- **Dev Environment:** Docker Compose (all mix commands run in containers)

## Running Commands

All Elixir/mix commands must run through docker compose:

```bash
docker compose run --rm app mix test
docker compose run --rm app mix ecto.migrate
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Project Structure

```
lib/automaton/
  tenants/          — Tenant schema + context (multi-tenancy)
  agents/           — Agent schema, CRUD context, Runner (execution logic)
  runs/             — Run + RunEvent schemas, Runs context (event log)
  workers/          — Oban workers (RunAgent)
  llm.ex            — Anthropic API client (Req-based)
lib/mix/tasks/      — Mix tasks (gen_release_notes)
```

## Conventions

- Follow standard Phoenix project conventions
- Keep contexts (Ecto schemas + business logic) in `lib/automaton/`
- Keep web layer (controllers, live views, components) in `lib/automaton_web/` (not yet used)
- Minimal, clean code — avoid over-engineering
- Every table has `tenant_id` — multi-tenancy is enforced at the data model level

## Architecture Notes

- Agents are currently synchronous — no GenServers yet
- Runner.execute/3 is the core path: create run → log events → call LLM → store output
- Oban workers wrap Runner for async/scheduled execution
- Run events provide an append-only audit trail of each execution step
- Agent lifecycle: inactive (off), idle (listening), running (doing work)
