# Norns

## Project Overview

Open-source (MIT) durable agent runtime on BEAM. The orchestrator is a pure state machine — it dispatches tasks to workers and persists events, but never executes LLM calls or tools directly.

## Tech Stack

- **Language:** Elixir on BEAM/OTP
- **Web Framework:** Phoenix (REST + Channels + LiveView)
- **Database:** PostgreSQL via Ecto
- **Background Jobs:** Oban
- **Dev Environment:** Docker Compose (all mix commands run in containers)
- **License:** MIT

## Running Commands

```bash
docker compose run --rm -e POSTGRES_HOST=db app mix test
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.migrate
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Project Structure

```
lib/norns/
  tenants/          — Tenant schema + context (multi-tenancy)
  agents/           — Agent, AgentDef, Process (state machine), Replay (rebuild from the log), Messages, Registry
  conversations/    — Conversation schema + context (persistent chat history)
  runs/             — Run + RunEvent schemas, Runs context (event log)
  runtime/          — Event contracts, error taxonomy, retry policy
  gards/            — Gard + GardPort schemas; Gards context (worker affinity)
  hooks/            — Hook schema, Signature verification; Hooks context (webhook ingress)
  triggers/         — Trigger schema + context (cron schedules that start runs)
  workers/          — WorkerRegistry, TaskQueue, ResumeAgents, TriggerScheduler
  tools/            — Tool struct (no handler), Builtins, Catalog, Idempotency

lib/norns_web/
  endpoint.ex       — Phoenix endpoint (REST + WebSocket + LiveView)
  router.ex         — API routes (authed + public hook ingest) + LiveView routes
  plugs/            — Auth (API bearer token), SessionAuth (browser cookies)
  cache_body_reader.ex — caches raw request body for hook signature verification
  controllers/      — Agent, Run, Conversation, Trigger, Hook, HookIngest, Gard, Tool, Telemetry
  channels/         — AgentSocket/Channel (streaming), WorkerSocket/Channel (task dispatch)
  live/             — AgentsLive, AgentLive, RunLive, ToolsLive, GardsLive, TelemetryLive, SetupLive
  components/       — Layouts (root + app)
  json.ex           — Serialization helpers
```

## Debugging with nornsctl

`nornsctl` is a CLI tool for inspecting the runtime. Use it to check agent state, inspect runs, and view event logs when debugging issues.

```bash
nornsctl agents list                          # List all agents
nornsctl agents show <id>                     # Agent details
nornsctl agents status <id>                   # Live process state (idle, running, awaiting_llm, etc.)
nornsctl runs list [--agent <id>] [--limit N] # List runs
nornsctl runs show <id>                       # Run details + failure inspector
nornsctl runs events <id> [--json]            # Full event log for a run
nornsctl runs retry <id>                      # Retry a failed run
nornsctl triggers list [--agent <id>]         # List cron triggers
nornsctl triggers fire <id>                   # Fire a trigger now, outside its schedule
nornsctl gards list                           # List gards (worker execution contexts)
nornsctl gards create [--name N]              # Create a gard, prints its claim token once
nornsctl hooks list                           # List inbound webhooks
nornsctl hooks create --agent <id> --name ... # Create a webhook, prints its delivery URL
nornsctl conversations list <agent_id>        # List conversations
nornsctl conversations show <agent_id> <key>  # Conversation details
```

Configuration is via environment (already set up in `.envrc`):
- `NORNS_URL` — API base URL
- `NORNS_API_KEY` — bearer token

When debugging a failing run, start with `nornsctl runs show <id>` to check the failure inspector, then `nornsctl runs events <id> --json` to see the full event log.

## Conventions

- The orchestrator NEVER executes anything — all work goes through connected workers
- Four built-in tools (`wait`, `ask_human`, `launch_agent`, `list_agents`) are intercepted by the orchestrator; all other tools are defined and registered by workers
- Follow standard Phoenix project conventions
- Keep contexts in `lib/norns/`, web layer in `lib/norns_web/`
- Every table has `tenant_id` — multi-tenancy enforced at the data model level
- Provider-neutral LLM format on the wire — workers translate to their LLM provider

## Architecture

- **Agent process** is a pure state machine (GenServer): dispatches tasks, receives results, persists events
- **States:** `:idle`, `:awaiting_llm`, `:awaiting_tools`, `:waiting` (human input)
- **Workers** connect via `/worker` WebSocket, register capabilities `[:llm, :tools]`, receive task pushes
- **Conversations:** persistent chat history, keyed by external ID (auto-generated if not provided)
- **Events:** versioned (`schema_version: 1`), validated, provider-neutral format
- **Crash recovery:** replay from last checkpoint, re-dispatch pending tools; a pending `launch_agent` reattaches to its in-flight child run instead of relaunching
- **Idempotency:** deterministic keys for side-effecting tools; core issues and records them, the worker skips the repeat and reports `tool_duplicate`

## Design docs

`docs/` holds the plans and decisions. Start with `docs/roadmap.md` (sequencing) and `docs/decision-log.md` (what's built and why). `docs/plan-agent-builder.md` is the current product direction; `docs/gards.md` is the worker-affinity design.
