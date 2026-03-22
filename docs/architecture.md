# Architecture

## What Is This

Norns is an open-source (MIT), Elixir/BEAM-based durable agent runtime. Developers define AI agents that survive crashes, restarts, and infrastructure failures by checkpointing every LLM call and tool execution. Think Temporal, but purpose-built for AI agents and running on the Erlang VM.

## Why BEAM

BEAM provides properties that no other durable agent runtime has:

- **OTP supervisors** are native durable process managers. "Let it crash" is the original durable execution philosophy.
- **Lightweight processes** mean thousands of concurrent agents per node, each with isolated state.
- **Built-in distribution** enables agent migration across nodes and free clustering (future phase).
- **Hot code reloading** allows updating agent logic without stopping running agents.
- **GenServers** are a natural primitive for stateful, long-lived agent processes.

Every competitor (Temporal, Restate, Inngest, Cloudflare, Vercel) is built on Go, Rust, JS, or JVM. Nobody is building on BEAM.

## Core Primitive

Each agent is a GenServer managed by a DynamicSupervisor. The agent process runs the core loop:

```
receive message → call LLM → if tool call, execute tool → checkpoint → repeat
```

State is persisted to Postgres at each checkpoint as an event log. On restart, the process replays events rather than re-executing LLM calls.

## Process Model (Temporal-style Workers)

Norns never calls out to user code via HTTP. Instead, workers pull tasks — like Temporal's activity workers, but using persistent connections instead of polling.

```
Norns Runtime (BEAM)                     User's Infrastructure
  │                                         │
  Agent GenServer                           Norns Worker
  │  runs LLM loop                          │  connects to runtime
  │  checkpoints state                      │  registers available tools
  │  hits tool call                         │  waits for tasks
  │    ↓                                    │
  │  puts task on queue ─── persistent ───► │  receives tool task
  │                         connection      │  executes locally
  │                                         │  (full access to user's DBs,
  │  ◄── result ──────────────────────────  │   APIs, secrets)
  │                                         │
  │  checkpoint result                      │
  │  continue LLM loop                     │
```

Key properties:
- **Workers make outbound connections only** — works behind firewalls/NATs, no public endpoints needed
- **Norns never touches user data** — it orchestrates; workers execute
- **If a worker disconnects**, norns holds pending tasks and resumes when it reconnects
- **Self-hosted mode**: worker and runtime share the same BEAM VM, tool calls are local function calls with no network hop

BEAM advantage over Temporal: instead of workers long-polling a queue, norns uses persistent connections and pushes tasks instantly.

## Tool Layers

From the agent's perspective, all tools look identical: name, description, schema, execute. Norns wraps them uniformly with durability (checkpoint before calling, persist result, skip on replay).

Three sources of tools:

1. **Built-in tools** — ship with norns (web search, HTTP, file I/O). These are just user-defined tools that happen to be bundled.
2. **User-defined tools** — functions registered via the SDK. Run in the user's worker process.
3. **MCP tools** (future) — norns connects to external MCP servers as a client, discovers tools automatically.

## API Surface

Phoenix serves two channels:

- **REST API** — lifecycle management: create agent, send message, get status, list runs
- **WebSocket (Phoenix Channels)** — streaming: agent output tokens, tool call progress, state changes in real time

Phoenix PubSub connects agent processes to transport. Agent processes publish events, channels subscribe. Decoupled from transport and scales to multi-node via distributed Erlang or Redis-backed PubSub.

## Data Model

Event-sourced persistence in Postgres via Ecto.

Core tables:
- `tenants` — name, slug, api_keys (multi-tenancy enforced at schema level)
- `agents` — agent definitions (model, system prompt, tool config, checkpoint policy)
- `runs` — individual execution instances (status, input, output, trigger)
- `run_events` — append-only event log per run (message received, LLM response, tool call, tool result, checkpoint, error)

On restart: find last checkpoint event, replay events since that checkpoint.

## Current State (Phase 1 Complete)

```
Supervisor
├── Norns.Repo (Ecto/PostgreSQL)
├── Oban (background job processor)
├── Phoenix.PubSub (event broadcasting)
├── Registry (agent process lookup)
└── DynamicSupervisor (agent GenServers)
    └── Agents.Process — LLM-tool loop with event persistence
```

What works today:
- Agent GenServer with full LLM-tool loop
- Event-sourced persistence with periodic checkpoints
- Crash recovery via state reconstruction from event log
- Orphan recovery on boot (resumes interrupted runs)
- DynamicSupervisor + Registry for agent lifecycle
- Swappable LLM backend (Anthropic impl + test fake)
- Tool execution framework (struct-based, local handlers)
- PubSub broadcasting of agent events
- 35 tests passing

## Crash Recovery

State reconstruction from the event log:
1. Find the last `checkpoint` event (periodic full message snapshot)
2. Replay events after the checkpoint to rebuild the message history
3. Resume the LLM-tool loop from where it left off

Resume logic based on last event type:
- `llm_response` with tool_use → re-execute tool calls
- `tool_result` → call LLM with updated history
- `checkpoint` → clean state, call LLM

On boot, `Workers.ResumeAgents` finds runs with status "running" and no live process, and resumes them.

## Build Phases

### Phase 1: Core Primitive ✓
Durable agent process end-to-end. GenServer with LLM-tool loop, event-sourced persistence, crash recovery, orphan recovery on boot.

### Phase 2: API + Transport
Phoenix REST API for lifecycle management. Phoenix Channels (WebSocket) for streaming. PubSub connecting agent processes to channels.

### Phase 3: Generic Agent Definitions
Replace ad-hoc agent config with declarative `AgentDef` struct. Module-based tool definitions (`use Norns.Tool`). Tool registry. Configurable checkpoint policies and failure recovery.

### Phase 4: Worker Protocol
Worker connection management (persistent WebSocket/TCP). Tool registration protocol. Task dispatch and result collection. Reconnection handling.

### Phase 5: TypeScript/Python SDKs
Developers define agents and tools in their language, SDK talks to Norns runtime over the API. BEAM is the engine, not the interface.

### Skip For Now
- Multi-node clustering
- MCP tool integration
- Agent builder / chat UI
- Dashboard / observability UI
- Auth, teams, billing
- LLM streaming

## Business Model

- **Norns Runtime** (open source, MIT) — the durable agent execution engine
- **Norns SDKs** (open source, MIT) — define agents in TypeScript/Python
- **Norns Cloud** (hosted, paid) — managed runtime, dashboard, observability, team features

## Integrations

Norns is complementary to real-time media platforms like LiveKit. Norns owns the reasoning/durability plane; LiveKit owns the audio/video plane. A LiveKit agent worker acts as a thin voice I/O adapter that forwards transcripts to a Norns agent and streams responses back through TTS. The Norns agent maintains full context across calls, disconnections, and multi-hour waits.

Same pattern applies to other transports: Slack adapter, Twilio SMS adapter, web chat — all pointing at the same durable agent process.
