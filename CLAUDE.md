# Norns

## Project Overview

Open-source (MIT) durable agent runtime on BEAM. The orchestrator is a pure state machine — it dispatches tasks to workers and persists events, but never executes LLM calls or tools directly. Think Temporal, but purpose-built for AI agents.

Product surface: REST API + WebSocket streaming + LiveView dashboard + SDKs.

## Tech Stack

- **Language:** Elixir on BEAM/OTP
- **Web Framework:** Phoenix (REST + Channels + LiveView)
- **Database:** PostgreSQL via Ecto
- **Background Jobs:** Oban
- **LLM:** Anthropic Messages API via Req (executed by workers, not the orchestrator)
- **Dev Environment:** Docker Compose (all mix commands run in containers)
- **License:** MIT

## Running Commands

All Elixir/mix commands must run through docker compose:

```bash
docker compose run --rm -e POSTGRES_HOST=db app mix test
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.migrate
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Project Structure

```
lib/norns/
  tenants/          — Tenant schema + context (multi-tenancy)
  agents/           — Agent, AgentDef, Process (state machine), Registry
  conversations/    — Conversation schema + context (persistent chat history)
  memories/         — Memory schema + context (cross-conversation knowledge)
  runs/             — Run + RunEvent schemas, Runs context (event log)
  runtime/          — Event contracts, error taxonomy, retry policy
  workers/          — DefaultWorker, WorkerRegistry, TaskQueue, ResumeAgents
  llm.ex            — LLM dispatcher (used by workers, not the orchestrator)
  llm/              — Behaviour, Anthropic adapter, Fake (test double)
  tools/            — Behaviour, Tool struct, Executor, Registry, Idempotency, built-in tools

lib/norns_web/
  endpoint.ex       — Phoenix endpoint (REST + WebSocket + LiveView)
  router.ex         — API routes + LiveView routes
  plugs/            — Auth (API bearer token), SessionAuth (browser cookies)
  controllers/      — AgentController, RunController, ConversationController
  channels/         — AgentSocket/Channel (streaming), WorkerSocket/Channel (task dispatch)
  live/             — AgentsLive, AgentLive, RunLive, ToolsLive, SetupLive
  components/       — Layouts (root + app)
  json.ex           — Serialization helpers
```

## Conventions

- Follow standard Phoenix project conventions
- Keep contexts (Ecto schemas + business logic) in `lib/norns/`
- Keep web layer (controllers, channels, plugs, live views) in `lib/norns_web/`
- Define tools as modules with `use Norns.Tools.Behaviour`
- The orchestrator (Agents.Process) NEVER executes anything directly — all work goes through workers
- Every table has `tenant_id` — multi-tenancy is enforced at the data model level

## Architecture Notes

### Orchestrator/Worker Split
- The agent GenServer is a pure state machine: it dispatches tasks and receives results
- All LLM calls and tool execution happen on workers, never in the orchestrator
- `DefaultWorker` runs in the same BEAM VM for self-hosted mode (no config needed)
- External workers connect via `/worker` WebSocket, register capabilities + tools
- Workers hold API keys and secrets — the orchestrator never sees them (in external mode)

### Agent Process States
- `:idle` — waiting for a message
- `:awaiting_llm` — dispatched LLM task, waiting for result
- `:awaiting_tools` — dispatched tool tasks, waiting for all results
- `:waiting` — paused for human input (ask_user)
- `:running` — transitioning between states (brief)

### Agent Configuration
- Agents configured via `AgentDef` struct: model, tools, mode, checkpoint_policy, on_failure, max_steps
- Two modes: `:task` (stateless) and `:conversation` (persistent context across messages)
- Conversation mode uses sliding window context management

### Runtime Contracts
- All events versioned (`schema_version: 1`) and validated via `Norns.Runtime.Events`
- 5-class error taxonomy with deterministic retry policy
- Idempotent side effects: deterministic keys prevent re-execution under replay
- Failure inspector for operator diagnosis

### Built-in Tools
- `web_search` (DuckDuckGo), `http_request`, `shell`, `ask_user`, `store_memory`, `search_memory`
- All execute on the DefaultWorker, not in the orchestrator

## Build Phases

1. **Core Primitive** ✓ — durable agent GenServer, event sourcing, crash recovery
2. **API + Transport** ✓ — Phoenix REST API + WebSocket channels
3. **Agent Definitions** ✓ — AgentDef, module-based tools, tool registry, checkpoint policies
4. **Worker Protocol** ✓ — persistent WebSocket connections, remote tool execution, task queue
5. **Conversations + Memory** ✓ — task vs conversation mode, sliding window, cross-conversation memory
6. **Dashboard** ✓ — LiveView UI, tenant setup, agent management
7. **Runtime Contracts** ✓ — typed events, error taxonomy, idempotency, failure inspector
8. **Orchestrator/Worker Split** ✓ — pure state machine orchestrator, all execution on workers
9. **SDKs** — TypeScript/Python clients
