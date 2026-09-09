# Architecture

## What Is This

Norns is a durable agent runtime. It orchestrates LLM-powered agents — managing state, checkpointing, retries, and crash recovery — while workers handle all actual execution (LLM calls, tool functions, external API access).

The orchestrator is a pure state machine. It never makes LLM calls or executes tools. You must connect at least one worker for agents to do anything.

## Orchestrator / Worker Split

```
Orchestrator (state machine)              Worker (your code)
  │                                           │
  │  dispatch llm_task ─────────────────────► │  calls LLM API
  │  ◄── llm_response ──────────────────────  │
  │  log event, dispatch tool_task ─────────► │  executes tool
  │  ◄── tool_result ───────────────────────  │
  │  log event, checkpoint                    │
```

Workers connect via `/worker` WebSocket, register their tools and LLM capability, and receive task pushes. Workers hold all API keys and secrets. Norns never sees them.

If a worker disconnects, pending tasks are queued and flushed when it reconnects.

## Agent States

Each agent is a GenServer managed by a DynamicSupervisor:

- `:idle` — waiting for a message
- `:running` — driving the LLM loop between dispatches
- `:awaiting_llm` — dispatched LLM task, waiting for response
- `:awaiting_tools` — dispatched tool tasks, waiting for results
- `:waiting_timer` — paused on the `wait` builtin until a timer fires
- `:waiting` — paused on the `ask_human` builtin until a human answers

A run parked in `:waiting` stays parked indefinitely. There are two ways to
answer it:

- **Just send a message.** `POST /api/v1/agents/:id/messages` to a parked
  agent is treated as the answer. Conversational clients (a Slack bot, a chat
  UI) don't have to track agent state or switch endpoints mid-conversation.
  This is the primary path.
- **Answer a specific run.** `POST /api/v1/runs/:id/reply` (`{"answer": "..."}`)
  targets one run explicitly — useful for programmatic clients and for agents
  with several conversations parked at once.

The run's own `status` becomes `"waiting"` while parked, and the run JSON
carries a `waiting_for` object (`question`, `tool_call_id`, `asked_at`), so
polling clients can tell "working" from "waiting on you" without scraping the
event log.

Because the pause is re-derived from the still-pending `ask_human` tool call, a
parked run that crashes re-parks on resume and re-broadcasts its question
rather than resuming the LLM loop.

The agent is never blocked — it always responds to status queries. Agent processes start automatically when a message is sent and stop when idle.

## Agent Modes

**Task mode** (default) — each message starts a fresh run. No history between runs.

**Conversation mode** — messages append to a persistent conversation. The LLM sees full history from previous runs. One agent can handle multiple concurrent conversations, each identified by an external key (e.g., Slack channel ID).

Context management via sliding window (configurable size) prevents unbounded token growth.

## Worker Protocol

Workers join `"worker:lobby"` with their registration:

```json
{
  "worker_id": "my-worker",
  "tools": [{"name": "search", "description": "...", "input_schema": {...}}],
  "capabilities": ["llm", "tools"]
}
```

Task dispatch uses a provider-neutral format. The worker translates to/from whatever LLM provider it uses (Anthropic, OpenAI, etc).

| Direction | Event | Payload |
|-----------|-------|---------|
| Server → Worker | `llm_task` | model, system_prompt, summary, date, messages, tools |
| Worker → Server | `tool_result` | task_id, status, content/tool_calls, finish_reason, usage, final_output |
| Server → Worker | `tool_task` | task_id, tool_name, input |
| Worker → Server | `tool_result` | task_id, status, result/error |
| Worker → Server | `register_port` | internal_port, name, protocol, url (gard workers only) |
| Worker → Server | `drain` | — : stop dispatching to me; I will finish my in-flight tasks, then leave |
| Server → Worker | `gard_destroyed` | — : the gard this worker claimed is gone; the channel closes |

**Content is opaque to the orchestrator** (`Norns.Runtime.Content`,
`decision-log.md` § Content is opaque). Core routes on the envelope — roles,
kinds, tool names, ids, steps, usage — and never reads or writes the text
the model sees. Consequences on the wire: the def's `system_prompt` goes out
verbatim and the worker composes the prompt (appending `summary` and
`date`); the worker reports `final_output` because deciding what the run
said needs to read text; tool results older than the last two turns are
elided by the LLM worker, not by core; and every result core resolves
itself carries a `kind` plus envelope `data` (`timer_completed`,
`tool_denied`, `subagent_completed`, `list_agents`, …) that the worker
renders to prose. `Norns.LLM.Format.render_message/1` is the reference
rendering. Any content position — message text, tool arguments, tool
results, questions, output — may hold a string, a map, or an opaque block
`{"$enc": "v1", ...}` that only a worker holding a key can read.

A worker shutting down cleanly sends `drain`, finishes and reports the
tasks it already holds, then leaves. New work that would have reached it
queues (or goes to another matching worker) until a replacement registers.
A worker that just disconnects has its in-flight tasks failed with
`worker disconnected`, which the agent's retry policy re-dispatches.

## Runtime Contracts

### Events

All state is captured as versioned, validated events (`schema_version: 1`). Events are constructed via `Norns.Runtime.Events` which validates payloads before persistence.

- **Lifecycle:** `run_started`, `run_completed`, `run_failed`
- **LLM:** `llm_request`, `llm_response`
- **Tools:** `tool_call`, `tool_result`, `tool_duplicate`
- **Checkpointing:** `checkpoint_saved`
- **Human-in-the-loop:** `waiting_for_user`, `user_response`
- **Sub-agents:** `subagent_launched`, `subagent_launch_allowed`, `subagent_launch_denied`, `subagent_list_allowed`, `subagent_list_denied`
- **Retry:** `retry`

`llm_request` records `tools`: the names of every tool offered to the model on
that step. It's what makes it possible to tell after the fact that a model
called something it was never given, or was given tools and ignored them.
Names only — full schemas would bloat every row for no analytical gain. The
field is optional, so events written before it existed still validate.

### Sub-agent authorization

`launch_agent` and `list_agents` are authorized server-side, in the built-in
tool path — not by prompting. Policy lives in the agent's `model_config`:

```json
{
  "subagents": {
    "mode": "allowlist",
    "allowed_agents": ["hello-bot"],
    "allow_list_agents": false,
    "max_depth": 3
  }
}
```

| Mode | `launch_agent` |
|------|----------------|
| `open` (default) | any agent in the same tenant |
| `allowlist` | only agents named in `allowed_agents` |
| `disabled` | denied |

`allow_list_agents` (default `true`) controls `list_agents`. Agent lookup is
tenant-scoped, so a cross-tenant target is never launchable regardless of mode.

Every decision — allowed or denied — is recorded as an event carrying
`requesting_agent_id`, `requesting_agent_name`, `mode`, the `target_agent_name`
where applicable, and a `reason` code on denials (`disabled`,
`not_allowlisted`, `list_agents_disabled`, `max_depth`). Denials also return an
error tool result, so the model learns it was refused rather than silently
losing the call.

Defaults are permissive, so agents without a `subagents` block behave exactly as
before.

### Tool catalog

`GET /api/v1/tools` returns the tools an agent in this tenant can currently
call. It answers the question you have to settle before writing an agent
definition: will the tools I name actually be there?

The list comes from `Norns.Tools.Catalog`, which is also what the `/tools`
dashboard reads. The composition — built-ins, then locally registered tools,
then tools advertised by connected workers, deduplicated by name — used to be
repeated at each call site, which let a page describe a surface that didn't
match what agents were given. A worker cannot shadow a built-in, because
dispatch resolves built-ins first.

Each entry carries `source` (`builtin`, `local`, `worker`), `input_schema`, and
`side_effect`. Worker tools exist only while their worker is connected, so
`meta` reports what's there to serve them:

```json
{
  "meta": {
    "workers_connected": 1,
    "workers": [{"worker_id": "docs-worker", "capabilities": ["tools"], "tool_count": 2}],
    "llm_available": true
  }
}
```

Without that, an empty tool list is ambiguous — nothing registered, or nothing
connected, are different problems. Note that `llm_available` has wider scope
than `workers_connected`: LLM dispatch falls back to `:default`-tenant workers
that serve every tenant, while tool dispatch does not. The two disagreeing is
expected.

### Trace summaries

`GET /api/v1/runs/:id/summary` returns a fixed-size account of what a run did:
verdict, counters, per-tool usage, a collapsed timeline, and detected signals.

It exists because the event log doesn't scale as a *reading* surface. A
200-step run holds several megabytes of events — `llm_request` carries the
entire message array on every step — so anything trying to reason about a run
either drowns or has to page through it. The summary stays a few kilobytes
regardless: consecutive steps calling the same tool with the same result class
collapse into one entry carrying a count and a sequence range, and the middle
of a long timeline elides to a single marker. Nothing is discarded; every
elision carries the range needed to fetch the detail from `/events`.

Measured on synthetic runs: 200 steps produced 6.4 MB of event payloads and a
5.4 KB summary, barely larger than the 50-step case.

Signals are observations, not advice — `loop`, `max_steps`, `tool_failing`,
`unknown_tool`, `no_tool_use`, `parked_unanswered`, `retry_storm`,
`unreturned_call`. Each carries a severity and the sequence range that
evidences it. They deliberately don't suggest fixes.

`unknown_tool` and `no_tool_use` depend on `llm_request` recording the names of
the tools offered to the model. Runs predating that field report neither rather
than guessing.

Message content, system prompts, and full tool results are never included.
Results are truncated; arguments are inspected so a string is distinguishable
from a number.

### Run lineage and nesting depth

Every run records `parent_run_id` and `depth`. A user-initiated run is a root:
`parent_run_id` is `nil` and `depth` is `0`. A run launched via `launch_agent`
points at its parent and sits one level deeper.

`max_depth` (default `3`) bounds nesting, counted absolutely from the root.
It exists to stop runaway recursion — agent A launching B launching A. It is
deliberately *not* a cost control: one agent launching fifty children at depth 1
costs far more than a chain of five, and depth says nothing about that. Bound
fan-out separately if you need a spend ceiling.

The check runs before the child is spawned, so a denied launch creates no run.
Previously nesting was unbounded, so the default only affects agents that were
already recursing more than three levels deep.

The `launch_agent` tool result is a JSON object rather than the child's bare
output:

```json
{"run_id": 482, "status": "completed", "output": "..."}
```

The `run_id` lets a parent inspect *how* a sub-agent reached its answer through
the run's event log, not just what it said.

### Recovering a parent that was awaiting a sub-agent

A pending `launch_agent` is re-dispatched on resume like any other tool call,
but it must not re-run: the child is the expensive half of a delegation, and
the parent's event log already names the run it started.

So `subagent_launched` tags the pending call with its `child_run_id`, and
resume reattaches instead of relaunching. If the child is already `completed`
or `failed`, its result is synthesized from the run row. If it's still in
flight, the parent subscribes and waits — and resumes the child itself if no
process is behind it, since a partial crash can leave the parent recovered and
the child not.

The parent subscribes before reading the child's status, so a child that
finishes in that window is caught by the broadcast rather than missed. Both
paths firing is fine: the first resolution clears the pending call and the
second is dropped.

Pending sub-agents are tracked by child *run* id. One step can launch the same
agent twice, and the completion broadcast is per-agent, so the run id is the
only thing that tells the two results apart.

If the child run is gone entirely, the call returns an error. Relaunching would
look like recovery while quietly paying for the work a second time.

### Error Classification

| Class | Example | Retry behavior |
|-------|---------|---------------|
| `transient` | timeout | up to 3 retries, exponential backoff |
| `external_dependency` | rate limit, upstream down | up to 10 retries, linear backoff |
| `validation` | invalid payload | terminal |
| `policy` | policy violation, cancelled | terminal |
| `internal` | unexpected error | terminal |

### Idempotency

Tools marked `side_effect?: true` get deterministic idempotency keys. On replay, the executor checks for an existing result with the same key and skips re-execution.

### Checkpoint / Restore

- `checkpoint_saved` snapshots messages and step
- Replay restores from the latest checkpoint, then replays subsequent events
- Pending tool calls with no result trigger re-dispatch on resume
- Proven by the replay conformance test suite

### Failure Inspector

Failed runs expose `error_class`, `error_code`, `retry_decision`, last checkpoint, and last event — enough to diagnose failures in under 60 seconds.

## Data Model

```
tenants        — name, slug, api_keys
agents         — name, purpose, system_prompt, model, model_config, max_steps, status
conversations  — agent_id, key, messages (jsonb), summary, message_count
runs           — status, trigger_type, input, output, failure_metadata, agent_id, conversation_id
run_events     — sequence, event_type, payload (schema_version: 1), source, metadata, run_id
```

## REST API

```
POST   /api/v1/agents                         — create agent
GET    /api/v1/agents                         — list agents
GET    /api/v1/agents/:id                     — show agent
POST   /api/v1/agents/:id/messages           — send message (returns run_id)
GET    /api/v1/agents/:id/runs               — list runs
GET    /api/v1/agents/:id/conversations      — list conversations
GET    /api/v1/runs/:id                      — run details + failure inspector
GET    /api/v1/runs/:id/events               — event log
GET    /api/v1/runs/:id/summary              — fixed-size trace summary
GET    /api/v1/tools                         — tools callable in this tenant
```

Auth via `Authorization: Bearer <token>`. Real-time events via WebSocket at `/socket`.

## Supervision Tree

```
Norns.Supervisor
├── Repo (PostgreSQL)
├── PubSub
├── DynamicSupervisor
│   └── Agent processes (state machines)
├── WorkerRegistry (tracks connected workers)
├── TaskQueue (holds tasks for disconnected workers)
└── Phoenix Endpoint (REST, WebSocket, LiveView)
```

## Dashboard

LiveView UI at `/`:
- Agent list with live status
- Agent detail with config editing, message input, live event stream
- Run detail with event timeline, failure inspector, retry/cancel buttons
- Tools view showing worker-provided tools
- Tenant setup on first visit
