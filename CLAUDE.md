# Norns

## Project Overview

Open-source (MIT) durable agent runtime on BEAM. Infrastructure for running LLM-powered agents that survive crashes, restarts, and infrastructure failures by checkpointing every LLM call and tool execution. Think Temporal, but purpose-built for AI agents and running on the Erlang VM.

Product surface: REST API + WebSocket streaming + SDKs. No UI.

## Tech Stack

- **Language:** Elixir on BEAM/OTP
- **Web Framework:** Phoenix (REST + Channels)
- **Database:** PostgreSQL via Ecto
- **Background Jobs:** Oban
- **LLM:** Anthropic Messages API via Req (multi-turn + tool use, swappable via behaviour)
- **Dev Environment:** Docker Compose (all mix commands run in containers)
- **License:** MIT

## Running Commands

All Elixir/mix commands must run through docker compose:

```bash
docker compose run --rm app mix test
docker compose run --rm app mix ecto.migrate
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Project Structure

```
lib/norns/
  tenants/          — Tenant schema + context (multi-tenancy)
  agents/           — Agent schema, CRUD, Process (GenServer), Registry
  runs/             — Run + RunEvent schemas, Runs context (event log)
  workers/          — Oban workers (RunAgent), ResumeAgents (orphan recovery)
  llm.ex            — LLM dispatcher (behaviour + Anthropic impl + fake for tests)
  llm/              — Behaviour, Anthropic adapter, Fake (test double)
  tools/            — Tool struct, Executor, WebSearch (stub)
```

## Conventions

- Follow standard Phoenix project conventions
- Keep contexts (Ecto schemas + business logic) in `lib/norns/`
- Keep web layer (controllers, channels, plugs) in `lib/norns_web/` (not yet used)
- Minimal, clean code — avoid over-engineering
- Every table has `tenant_id` — multi-tenancy is enforced at the data model level

## Architecture Notes

- Agents run as GenServers (`Agents.Process`) under a DynamicSupervisor
- Core loop: receive message → call LLM → if tool call, execute tool → checkpoint → repeat
- Every step persisted as a RunEvent BEFORE executing the next step (durability)
- State reconstruction from events enables crash recovery (replay from last checkpoint)
- Orphan recovery on boot resumes interrupted runs
- PubSub broadcasts agent events for real-time consumers
- `Agents.Registry` manages lifecycle: start, stop, lookup, resume
- `Agents.Runner` is legacy one-shot execution (kept for backward compat)
- Agent lifecycle: inactive (off), idle (listening), running (doing work)

## Build Phases

1. **Core Primitive** ✓ — durable agent GenServer, event sourcing, crash recovery
2. **API + Transport** — Phoenix REST + WebSocket channels
3. **Agent Definitions** — declarative AgentDef, module-based tools, tool registry
4. **Worker Protocol** — persistent connections, remote tool execution
5. **SDKs** — TypeScript/Python clients
