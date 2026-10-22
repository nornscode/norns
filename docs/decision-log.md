# Decision Log

Last updated: 2026-10-14

## Product Decisions

### Slowing down (decided 2026-10-14)

Active development on Norns is paused. Not abandoned, not announced, and
nothing is being deleted or turned off — the hosted instance keeps running,
Mimir and sleipnir keep using it, and bugs that bite a running system still
get fixed. What stops is building against an adopter who is not there.

**The reasoning.** Norns is a platform in search of a problem. Most people
building agents bring their own database and model transcripts, tool results
and context with ordinary tables; persistence is not their hard part. The
minority who do want durability reach for Temporal, where an agent loop on
top of durable execution is a couple hundred lines. Every step of that funnel
leaks — need durability at all, then want a platform rather than three tables,
then want one that is not Temporal, then accept a solo-maintained Elixir one
— and the product is the same multiplied four times. The model vendors also
keep absorbing this layer: server-side tool loops, hosted sessions, managed
agents.

The Elixir/Python split is real for generating buzz — no community owns a
thing whose surface is in another language — but it is not the cause.
Temporal is Go and nearly nobody who uses it writes Go. Implementation
language becomes a reason not to adopt only when there is no strong reason to
adopt.

**What is probably true.** We may simply be early. Agents that run for days,
coordinate in trees, and need crash recovery mid-tool-call likely do become a
real problem. But early is indistinguishable from wrong unless you can afford
to wait, and we can. What you do while waiting is keep the thing cheap and
alive, not spec D0 through D5.

**The test for resuming.** Build agents the way we would build them anyway,
picking the best tool each time with no loyalty to Norns. If we keep reaching
for it, it is earning its keep and the problem it solves will be discovered by
living it. If we keep reaching past it, that is the answer, arrived at without
having to decide it in the abstract. The failure mode to avoid is bending an
agent to fit the platform in order to justify the platform.

Someone external turning up and wanting this is the other resume condition.

**What this changes in the roadmap.** D0–D5, chains, P2a, tenant self-serve
and E1–E4 are parked — all of them serve an adopter who is not there.
`plan-differentiation.md` carries a parked header; its two durable findings
are the gard-is-a-runner split and the private-network exposure. Features are
now filtered by one question: does Mimir or sleipnir need it?

Also decided and not built, for the same reason: a docs site, and a Slack or
Discord community. An empty community channel is worse than none — it
advertises that nobody is home, where no channel reads as early. If a tripwire
is wanted, GitHub Discussions costs nothing and notifies us when a real person
arrives.


### Pure orchestrator — no execution
- Norns is a state machine and event log. It never makes LLM calls or executes tools.
- All execution happens on workers. You need a connected worker to do anything.
- Built-in tools (wait, ask_human, launch_agent, list_agents) are intercepted by the orchestrator, never sent to workers. All other tools are worker-provided.
- The orchestrator's job: dispatch tasks, persist events, manage state, crash recovery.
- Purity means the orchestrator never touches the outside world — no credentials, no user data, no third-party APIs. Reading/writing the runtime's own state (runs, defs, events) does not break it; holding a Slack token would.

### Content is opaque (decided 2026-09-09)
- The data-plane half of purity. The orchestrator routes on the **envelope** (roles, kinds, tool names, tool-call ids, steps, usage, stop reasons, error classes, agent and gard ids) and never reads, transforms, or generates **content** (message text, tool arguments, tool results, system prompts, questions and answers, run output). A content position holds a string, a structured map, or an opaque block a worker encrypted with a key core does not hold — and core treats all three the same: store, forward, never look inside. `Norns.Runtime.Content`; the conformance suite is `test/norns/runtime/opaque_content_test.exs`.
- Why: the coding harness puts source code in the event log, and "we cannot read your log" is only credible if core never needed to. Writing the rule down before compaction and chains land is what keeps them from growing content reads; the audit that made it true was eight small fixes (`plan-harness-e2e.md`).
- Consequences: workers compose the system prompt (`summary` and `date` ride in the task envelope), report `final_output`, elide old tool results, and render every result core resolves itself from a `kind` plus envelope `data` — `Norns.TestWorker.Format.render_message/1` is the reference. What stays plain and core-written: diagnostic error text on `run_failed`/`retry` and the registry's `worker disconnected`, none of which carries tenant content. `runs.output` is still a string column; a block lands there JSON-encoded until encryption ships (E2).

### Compaction is an LLM task (decided 2026-09-09)

Long-running agents outgrow the context window; the sliding window drops
history and the SDKs' 200-character elision of old tool results was a
stopgap that hurt coding sessions most. Compaction folds the older history
into a summary, and it is built as an ordinary LLM task (`purpose:
"compact"`) so core never reads the messages or the summary: the worker
writes the prose, core stores the block, and the same path works on
encrypted content. The trigger is `context_policy` on the def, on the
input-token count the last response reported (envelope). The event is
`context_compacted` (dropped, kept, summary, usage) followed by a checkpoint
whatever the policy, so replay from either restores the summary. The
summary is also stored on the conversation and rides in every later
`llm_task` envelope, which is the mechanism the conversation `summary`
column had waited for. Rejected: compacting in the SDK (every worker would
re-implement it, and the log would not show it); a core-side summariser
(reads content, and needs a provider key in core).

### Fork is a checkpoint in a new run (decided 2026-09-09)

`POST /runs/:id/fork` (`plan-coding-agent-runs.md` Phase F) is built on
what replay already does: rebuild the history up to a step, then write it
as the first checkpoint of a new run and resume from it. No new state
machine path, and any step is forkable whatever the checkpoint policy. The
history a run started from is taken from its first `llm_request`, not the
conversation row, because the row moves on after the run. Forks are
task-mode runs in a fresh conversation on the parent's gard; overrides
clone the def into a variant agent because the process re-reads its def
every step. Rejected: overrides on the run row (the process would ignore
them), and appending a fork to the parent's conversation (it would corrupt
the parent's history).

### Sleipnir is the tool (decided 2026-09-09)

The harness product is one command in your repository that is both the
worker (tools and model calls on your machine) and the client (the
sessions you look at), with the loop in Norns: pi's experience with pi's
loop replaced. Two processes to install and start was the usability gap.
Language: Python with Textual, because the worker and the SDK already
exist in Python, the worker loop and the TUI share one asyncio process,
and we have no user of the tool yet, so a week of use will change the
design more than the language will; `uv tool install` is close enough to
a binary for the developers it is for. Rust (single static binary,
in-process sandboxing, Codex's path) is the decision to revisit after H4,
and only as the whole shape: a Rust sleipnir absorbs the worker, and the
Python one becomes the reference and library path. Rejected: growing
`nornsctl chat` into the client (nornsctl is the operator tool; the
client is a daily driver for a different audience), and a Rust client
alone (a fourth language to draw text).

### Tools are infrastructure, agents are configuration
- Workers are the tenant's long-lived capability layer (the Slack worker, the DB worker), maintained like services.
- Agents are cheap, disposable data: prompt + model + tool selection + triggers, created and tested entirely through the API.
- The agent builder composes existing tools by default and only falls back to generating worker code (from templates) when a capability is missing. See `plan-agent-builder.md`.

### Triggers are Norns data
- Cron schedules and inbound webhook mappings live in Norns tables, managed via API — not in worker repos. Composed agents have no repo.
- Connector workers (Slack, Discord — anything needing credentials or a persistent connection) stay outside core. The line: if it speaks HTTP to us, core can receive it; if we must hold credentials or a connection, it's a connector.

### The fork: own the provisioner (decided 2026-08-08)
- We sell compute (managed gards), not just durability semantics. Fabricated workers need somewhere durable to run; that somewhere is ours to operate.
- The orchestrator stays pure — the provisioner is a separate product, per `gards.md`.
- Durable MCP → custom workflows is parked, not dead.

### The cloud boundary (decided 2026-08-10)
- The builder is an agent — it makes LLM calls and runs a loop — which is exactly what the orchestrator must never do. It cannot live in core without breaking purity. Structurally it is a client of the API: read the tool catalog, write defs, send test messages, read events.
- Open-core split: **core (OSS)** is the runtime plus the primitives — tool selection, triggers, webhooks, tool catalog, gard registry. Each is independently useful; none is builder-only. **Cloud** is the builder (run as an agent on Norns with a cloud-operated worker), the provisioner, managed gards, and managed connectors.
- Cloud sells "you don't run anything." Sharpened 2026-08-14: core ships *complete primitives* plus a documented self-host path (templates ship a Dockerfile; `docker run --restart unless-stopped --env-file .env` is the documented recipe) — no core capability is withheld. Volund, the operational layer on top of those primitives, is a cloud product (see below).
- **Managed connectors are the provisioner's first product.** A connector worker needs none of the hard parts of the coding-agent workload — no snapshots, no tunnels (Socket Mode is outbound), no code extraction. It is "run this container with these env vars, restart it if it dies": the provisioner's minimum viable form, answering a pain that exists before any builder does. Coding-agent gards come after. *(Corrected 2026-08-14: connectors run as no-gard workers — see below.)*

### The provisioner's unit is a deployment (decided 2026-08-14)
- Earlier framing had connectors as the first *gard* workload. That was wrong: dispatch is gard-strict in both directions, so a gard-bound connector's tools would be invisible to ordinary no-gard runs — the opposite of a tenant-wide capability layer. Connectors are supervised **no-gard** service workers; gards are for workloads needing filesystem affinity (coding agents).
- The provisioner is named **`volund`** (separate Go repo, **proprietary — decided 2026-08-14**) — Völundr the master smith, anglicized the way *garðr* became *gard*. Volund is the platform's killer feature and showcase, not an OSS component: the *interface* it programs against (gard API, claim tokens, worker registration, workers endpoint) is fully open and documented in `gards.md`, so anyone can build their own provisioner; volund itself — the CLI and drivers — is closed. *(The control plane was originally slated for volund too; relocated to the cloud app 2026-09-03 — see § The control plane is Elixir, in the cloud app.)* The repo starts private (easy to open later, impossible to unpublish), and the CLI and control plane co-evolve without a public-interface stability commitment. It manages **deployments** — name + image + secrets + workload shape — with a gard as an optional per-deployment property, not the unit itself.
- MVP shape: thin stateless CLI over Docker; `--restart unless-stopped` is the supervisor, no daemon. Secrets read from `--env-file` at `up`, baked into container env; state file remembers the env-file path, never values; nothing secret goes to Norns. Driver interface (`docker` now, `fly`/`firecracker` later) so the managed service is a control plane over the same interface, not a rewrite.
- Phasing: P0 connectors (`up`/`down`/`list`/`logs`/`restart`), P1 gard workloads (`up --gard`, workspace copy-in, code extraction, port mapping), P2 managed (control plane, prebuilt images, tunnels, snapshots, billing).
- Prerequisites in existing repos: `GET /api/v1/workers` (expose `WorkerRegistry.connected_workers/1` over REST so `list` can join container state with worker-connected state) and the Python SDK serial-task fix (24/7 connectors are the workload it bites). *Both shipped 2026-08-15 (workers endpoint; SDK 0.3.1).*

### LLM dispatch is gard-strict too (decided 2026-08-16)
- Phase 1 shipped tool dispatch gard-strict but LLM dispatch unfiltered — any `:llm` worker served any run, on the theory that LLM calls are stateless. Volund P1's first E2E surfaced why that's wrong: a lone gard deployment silently served *other* runs' LLM calls **with its own API key** (credential leakage as billing surprise), and a plain run against a gard-only fleet half-served — LLM succeeded, tools queued forever — instead of queueing whole. LLM tasks now carry the run's gard and match strictly, same as tools; queued LLM tasks flush gard-aware. Consequence: gard deployments must be LLM-capable (the SDK worker always is), and a run's entire execution — LLM and tools — lands on one worker: the deployment *is* the execution context.

### A gard-bound run reaches the no-gard workers' tools (decided 2026-10-21)
- Strict-both-ways dispatch made a gard an island: a run bound to a gard could call only that gard's worker's tools, so the tenant-wide service workers that the 2026-08-14 correction says "serve every run" served every run except the ones in a gard. Fulla hit it first — the manager cannot live in a box with a shell because its confirm cards, timers and people tools are served from outside any gard, and the only way around was a sub-agent hop per piece of work (issue #56).
- A gard-bound run is now offered its gard's workers' tools plus the no-gard workers' tools, the gard winning a name collision. The resolution happens where the list is composed (`available_tools`, each `Tool` tagged with the gard it will dispatch to), and the agent process dispatches each call on its tool's gard; the registry and the queue flush stay strict. Done in the registry instead — "gard worker first, no-gard otherwise" at dispatch time — a gard's `read_file` would silently land on a service worker with the same name while the gard's worker was reconnecting; with the tag it queues for its gard. A no-gard run is unchanged and never reaches a gard's tools. LLM dispatch stays strict in both directions, since that is what keeps a gard deployment's LLM key from serving other runs.
- Rejected: an agent bound to two gards. It needs a second claim, a second registry entry and a rule for which gard a tool goes to, and still leaves the tenant-wide workers unreachable from any gard.

### API keys scoped to a gard worker (decided 2026-10-21)
- Every key in a tenant had equal power. A worker in a gard needs a key to join, and a command the agent runs on that machine as the worker's user can read it from `/proc/<pid>/environ` — stripping it from the command's environment does not help. So a shell worker in a gard held a key that could create runs, read every conversation, redefine agents and message any agent in the tenant, and the only mitigation was a second tenant whose key was cheap to lose, which `launch_agent` cannot cross (issue #55).
- A key may now carry a scope (`Norns.Tenants.ApiKey`, its own table; the tenant's full keys stay in `tenants.api_keys` and behave as before). `POST /api/v1/api_keys` with a tenant key takes `{name, scope: {kind: "worker", gard_id, capabilities}}` and returns the token once. The key opens the worker socket and joins with capabilities no wider than its scope, claims only its gard (claim token still required), serves tasks and delivers results; every REST route answers 403, the agent socket and the dashboard session do not recognise it at all. `DELETE /api/v1/api_keys/:name` revokes; a channel joined on the key is told and closes, a socket opened on it before the revocation cannot join; destroying the gard revokes its keys. Reading the key from inside the gard now gains an attacker the ability to serve tools into a gard they are already in.
- Scopes are an enum of one. Read-only and def-write-only keys for a hosted builder (the cloud-readiness item) are the next members; the shape — a `scope` map on the key, checked where the scope's one capability is exercised, refused everywhere else — is meant to take them. Related: #53, agent definitions scoped to a gard, the other half of a gard being a real boundary.

### The control plane is Elixir, in the cloud app (decided 2026-09-03)
- The managed product's control plane is **not** a Go service in the volund repo. It lives in the private `norns-cloud` Phoenix app, which depends on `norns` core (git/path dep), mounts core's router, and adds its own contexts, migrations, and LiveView pages: deployments, secrets, reconciler, billing, builder. Same Postgres, extra tables, one deploy. Core stays what a self-hoster and local dev run; cloud is core plus the closed modules. Not a fork, not a compile flag in the open repo.
- Why: "easy to host" is not the axis — Go is the easiest thing to host. The control plane is long-lived, stateful service logic: Ecto records, an Oban reconciler, Cloak-encrypted secrets, a LiveView dashboard, tenants and auth that already exist. Building that in Go rebuilds the framework in a second language and puts an API boundary between the dashboard and the thing it manages.
- Volund stays Go and stays a CLI: the local dev tool, the self-host operational layer, the reference client for the open contract, and the Docker driver. Short-lived, shells out to Docker, static binary — exactly Go's shape. `list --json` / `status --json` (2026-09-03) is its machine-readable seam; the cloud app's deployment record takes the same shape.
- Consequences: the control plane calls core contexts in-process (gards, worker registry) — no tenant API key, so API key scoping leaves the P2a critical path (it stays a cloud-readiness item for the builder, a real external client). Because the cloud app deploys to Fly and cannot shell out to Docker on another host, the **first managed driver is Fly Machines**, called from Elixir over Fly's API — no fleet, no host agent, machines are the hosts. The Docker driver in volund is the local/self-host story; a per-host agent mode of volund is the fallback if raw VMs are ever preferred. The driver contract (build/pull/up/down/restart/status/logs/copy-out) exists in two languages; it is seven small methods and the Docker one is tested, so that cost is accepted.
- **Secrets exception, stated explicitly.** "Norns never sees user data or secrets" remains true for core. The cloud app's secrets context is the single exception: cloud-owned tables, encrypted at rest with a KMS key, write-only from the customer, decrypted only at machine start. Hosting a worker means holding its secrets — unavoidable, same as every hosting platform — and the self-host path stays the escape hatch for tenants who can't hand them over, since core never needs them.

### Workers own everything
- Workers hold API keys, database credentials, tool implementations.
- Workers connect outbound via WebSocket — works behind firewalls, no public endpoints needed.
- Norns never sees user data or secrets.
- Provider-neutral LLM format — the worker translates to/from whatever API it uses.

### Inspired by Temporal
- Worker/client split matches Temporal's model.
- Orchestrator manages workflow state, workers execute activities.
- Built for AI agents specifically — conversations, tool dispatch, LLM checkpointing.

### Multi-tenancy
- Every table has `tenant_id` (NOT NULL, FK).
- Agent names unique per tenant.
- API keys per tenant.
- Workers scoped to tenant.

---

## Implemented

### Durable agent process
- Agents run as GenServers under DynamicSupervisor.
- States: idle → awaiting_llm → awaiting_tools → idle (or waiting for human input).
- Every step persisted as a RunEvent before the next step executes.
- State reconstruction from event log on crash recovery.
- Orphan recovery on boot resumes interrupted runs.

### Orchestrator/worker split
- Agent process dispatches all work via WorkerRegistry.
- LLM tasks: `dispatch_llm_task` → worker calls LLM API → returns neutral response.
- Tool tasks: `dispatch_task` → worker executes function → returns result.
- Agent is never blocked — always responds to status queries, stop, messages.
- TaskQueue holds tasks when no worker is connected, flushes on reconnect.

### Linear storage, delta dispatch (decided 2026-10-16)

A run's storage and its traffic both grew with the square of its length.
Every `llm_request` wrote the whole message list into Postgres, and so did
every `checkpoint_saved`, by default on every tool call; every `llm_task`
carried the whole list to a worker that had seen all but the last two
messages one step earlier. None of it was a design choice anyone would
defend. Replay read the messages from the *first* request only, and
loaded every event of the run before it even looked for a checkpoint, so
the snapshots saved no read — only an in-memory fold.

Three changes, no new state-machine path. `llm_request` carries `messages`
on a run's first request (the opening history, which the conversation row
cannot stand in for: it moves on after the run and at compaction) and the
count after that. `checkpoint_saved` is a marker — step, count, summary —
and replay folds from the opening history; a checkpoint that does carry
`messages` (a fork's opening one, or any written before this) is still
honoured as a snapshot, so old logs replay unchanged. On the wire, a
worker that joins with `features: ["message_cache"]` keeps the list it was
last sent per run, and while the same connection serves the run core sends
`messages_delta: {base_count, drop, append}` instead (`HistoryDelta`). The
only invalidation is the worker's: a delta against a base it does not hold
gets `message_cache_miss` back and core resends in full at the same step,
no retry counted. Core never has to know why a worker forgot.

Rejected: moving the loop into the worker (saves the most bytes, costs the
thesis — see § Slowing down); and having the registry alone decide when a
delta is safe, since eviction is the worker's business and a miss protocol
is cheaper than being right about another process's memory.

What remains quadratic: nothing in the log. The conversation row is
rewritten whole at compaction and run end, which is O(n) per run, not per
step. A `context_policy` bounds n besides.

### Idempotency reaches the worker (decided 2026-09-13)

The keys had been computed since gards landed and nothing had ever read
one. `Idempotency.context/4` looked the tool up in `agent_def.tools`, which
holds the tools handed to an agent directly and not the ones a worker
advertises — so for every tool sleipnir has, the lookup missed, `side_effect`
came out false and the key came out nil. The key was also only computed when
`log_calls?` was true, which is to say never on the resume path, which is the
only path where it matters. And `dispatch_task` did not put it on the wire.
No SDK read it; nothing anywhere produced the `tool_duplicate` event that
core validates, replays, counts in `TraceSummary` and renders in `RunLive`.

`CLAUDE.md` said "skip on replay" and the Python SDK's README said "Norns can
enforce idempotency on replay". Both were false.

Now: the tool is resolved through `Tools.Catalog`, so a worker's declaration
is what decides; the key is computed on every dispatch including resume; it
rides on the task; and a worker that reports `duplicate` gets a
`tool_duplicate` event written before its `tool_result`, with
`original_event_sequence` filled in when core can point at the earlier result
(usually it cannot — the call was re-dispatched precisely because the first
result never landed, which is why that field is now optional).

The worker half is in Python SDK `_handle_tool_task`: a bounded record of
completed keys, failures not remembered. Superseded in part by
§ A lost tool call is re-dispatched below, which is what made any of it
reachable.

### A lost tool call is re-dispatched (decided 2026-09-22)

`reclaim_worker_tasks` used to tell the agent its tool had failed —
`worker disconnected` as the tool result — with a comment claiming the retry
policy would re-dispatch. Nothing did. Watched end to end on a live run: the
model reads the error, retries, and that retry is a *new* call at a new step
with a new idempotency key. No worker can recognise it, so the side effect
happens again. The keys we compute so carefully protected nothing, because
the case they exist for was the one case that never produced them.

Now the call itself is handed on — same task id, so the waiting agent's
bookkeeping still matches; same idempotency key, so a worker that already
ran it can say so. No worker free, it queues and flushes on connect, which
is what already happened to LLM tasks and is why a killed worker never
stalled a run. Capped at three attempts total, after which the agent is told.
Reclaim on re-registration runs after the new incarnation is in the registry,
so its predecessor's work goes to it rather than queueing behind a worker
that is already here.

The worker's record of completed calls is on disk from Python SDK 0.8.1
(`NORNS_STATE_DIR`), since a memory that dies with the process is no use for
the failure it guards.

**What this still does not give you, and nothing local will:** the record is
written after the handler returns, so a worker killed between the effect
landing and that write remembers nothing, and the re-dispatched call runs it
again. Recording first only moves the hole. This is at-least-once with a
strong duplicate suppressor, not exactly-once, and the README caption and
architecture doc now say that rather than implying otherwise. Where twice is
unacceptable, the key has to reach a destination that dedupes on it.

Found by building a scripted worker and killing it with `-9` at three
different moments. Every claim in this entry was watched, not reasoned about;
the previous version of this entry was reasoned about, and was wrong.

### No worker code in the orchestrator (decided 2026-09-13)

Purity was a rule about runtime behaviour; it was never true of the tree.
`lib/` held a whole worker in miniature: an LLM dispatcher and its fake, the
neutral ↔ Anthropic translator, a tool executor with remote dispatch, a
registry of locally-executable tools, and a `handler` function on the tool
struct. None of it ran in production — `Norns.LLM` had no caller outside its
own tests, `Tools.Executor` was reached only from `test/support`, and
`Tools.Registry.register/1` was never called by anything, so the catalog
concatenated an always-empty list. The one place `handler` was load-bearing
was `WorkerRegistry.available_tools/2`, which had to fabricate
`fn _ -> {:error, "remote tool — use dispatch"} end` to satisfy the struct's
`@enforce_keys`.

It was there because core was written before any worker existed and had to
prove itself against something. That something is a test worker, so it now
lives with the test worker: `Norns.TestWorker.{LLM,Format,Tools,Tool}` under
`test/support/`, compiled only in `:test`. Deleted outright: `Norns.LLM`,
`Norns.LLM.Behaviour`, `Norns.Tools.Behaviour`, `Norns.Tools.Registry`, and
`test/norns/llm_test.exs`, which asserted that a fake returns what you
scripted it to return.

`Norns.Tools.Tool` now carries name, description, schema, source and
`side_effect?` — what a model needs to choose a tool and a client needs to
show one — and no handler, because the orchestrator has nothing to execute.
Two places that used to insist on the struct now match on shape
(`Tool.to_api_format/1`, `Idempotency.side_effecting?/2`), so a worker may
hand core its own richer tool representation.

Consequence to keep: a reference implementation in `lib/` reads as product.
The SDKs are where a real worker's translation and execution live; the test
worker is the reference core tests against, and it is test support.

### Provider-neutral LLM format
- Tool calls: separate `tool_calls` array with `arguments`, not Anthropic content blocks.
- Tool results: `role: "tool"` messages with `tool_call_id`, not content blocks in user messages.
- `finish_reason`: `stop` / `tool_call` / `length` — not Anthropic-specific values.
- `Norns.TestWorker.Format` translates neutral ↔ Anthropic at the worker boundary.

### Conversations
- Task mode (default): each message starts fresh.
- Conversation mode: persistent history across runs, identified by external key.
- Sliding window context management.
- Multiple concurrent conversations per agent.

### Runtime contracts
- All events versioned (`schema_version: 1`) and validated before persistence.
- 5-class error taxonomy with deterministic retry policy.
- Idempotent side effects via deterministic keys.
- Failure inspector: error_class, error_code, retry_decision, last checkpoint/event.
- Replay conformance test suite.

### API + Dashboard
- REST API with bearer token auth, returns run_id from send_message.
- WebSocket channels for real-time events and worker connections.
- LiveView dashboard: agent list, agent detail with config editing, run timeline with event details, cancel/retry buttons.

### SDKs
- Python SDK: worker (`Norns`) + client (`NornsClient`). Published to PyPI.
- Elixir SDK: worker (`NornsSdk.Worker`) + client (`NornsSdk.Client`). Published to Hex.

### Multi-agent orchestration
- Built-in `launch_agent` and `list_agents` tools.
- Child agents launched via PubSub, tracked in `pending_subagents` (keyed by child run id).
- `subagent_launched` event type with replay support.
- Agents can discover and delegate to other agents within the same tenant.
- Run lineage: `parent_run_id` + `depth`, `max_depth` recursion bound (not a cost control).

### Human in the loop
- Built-in `ask_human` parks the run durably in `:waiting`; `POST /runs/:id/reply` (or `reply_to_human`) resumes it.
- `waiting_for_user` event + broadcast lets any surface (dashboard, connector, client SDK `wait=True`) relay the question and the answer.
- `POST /runs/:id/cancel` (decided 2026-10-16) stops a run from outside: the owning process fails it with `error_code: cancelled` through the same path as any other failure, so the broadcast and the run webhook fire, and then goes idle, keeping the conversation. The dashboard button used to terminate every process of the agent and write the failure by hand, which fired no webhook; it now calls the same `Norns.Runs.Cancel`. A dispatched task is not recalled: workers own execution, and the stale result is dropped on return. A task still queued for an absent worker is dropped from `TaskQueue` on cancel, and a flush never hands out a task whose owning process is dead, so a cancelled or crashed run's tool call is not carried out when the worker arrives. Any failure mid-step first settles the assistant's open tool calls with error results (`kind: unanswered`), because a history with a `tool_use` and no `tool_result` is refused by the provider on the conversation's next turn.

### Subagent allowlists
- `Norns.Agents.SubagentPolicy` — per-agent authorization for `launch_agent` / `list_agents`, with audit events. Defaults open; existing agents unaffected.
- Phase 1 of `plan-subagent-allowlists.md`; phases 2–3 remain proposed.

### Per-agent tool selection
- `Norns.Agents.ToolPolicy` — per-agent allowlist of worker-provided tools, parsed from `model_config["tools"]` (same shape and defaults philosophy as `SubagentPolicy`). Defaults open; existing agents unaffected.
- Enforced twice: the allowlist filters the tool list advertised to the LLM, and dispatch rejects a call outside it (error result back to the model, `tool_call_denied` audit event). Built-ins are exempt — `launch_agent`/`list_agents` are governed by `SubagentPolicy`.
- The compose-mode prerequisite from `plan-agent-builder.md`: agents can now be assembled from a subset of the tenant's capability layer.

### Cron triggers
- `Norns.Triggers` — `triggers` table (agent, cron, message, optional persistent `conversation_key`), full CRUD at `/api/v1/triggers`, plus `POST /triggers/:id/fire` to test outside the schedule (doesn't consume the scheduled minute).
- Fired by a minutely Oban job (`TriggerScheduler` via the Cron plugin). Dedupe is an atomic `last_fired_at` claim: at most one firing per trigger per matching minute, however many schedulers observe it.
- Runs started by a trigger carry `trigger_type: "schedule"`. Cron expressions validated with `Oban.Cron.Expression` at write time.
- Default is task mode (fresh conversation per firing); setting `conversation_key` opts into shared history across firings.

### Gards Phase 1
- `Norns.Gards` — gard registry with server-generated 256-bit claim tokens, atomic claim (one winner among simultaneous claimants), idempotent disconnect marking, soft-delete destroy with active-run guard and worker kick.
- Dispatch is gard-strict end to end: `find_worker` strict equality, `available_tools` gard-filtered, TaskQueue flush matches `{tenant, tool, gard}`. LLM dispatch deliberately unfiltered (no filesystem affinity).
- Gard binds per-run (`send_message gard_id:`), children inherit the parent's gard, resume restores affinity from the run row, idempotency keys include the gard (no-gard keys keep the historical shape, so pre-gard runs replay correctly).
- The disconnect status write runs in an isolated task — a database hiccup must not crash the registry that holds every worker connection.
- REST: gard CRUD (claim token returned exactly once, on create) + ports; workers register ports over their channel, gard inferred from the connection.
- Full surface: `nornsctl gards` commands, `/gards` dashboard page, Python SDK `gard`/`claim_token` on `run()` + `register_port` (fatal vs retryable claim failures distinguished — `already_claimed` retries because a quick reconnect can race the disconnect bookkeeping; bad token/destroyed gard raise instead of spinning).

### Fabricate toolkit (nornsctl repo, 2026-08-11)
- `nornsctl new --template default|slack-bot` — templates as generation targets; slack-bot ships outbound Slack tools with the token held only by the worker.
- Every scaffold ships `AGENTS.md` — the v0 builder: any coding agent dropped into the project learns the scaffold → worker → test message → read events → iterate loop, the tool conventions (docstring is the interface, `side_effect=True` for writes), and the debugging playbook.
- `nornsctl agents message --wait` — the missing loop primitive; terminal-state summary or the parked question with its reply command.
- Found and fixed en route: litellm 1.96.1 ships cp310-only wheels, breaking every fresh `norns-sdk` install on Python 3.11+ — excluded in the SDK (needs a PyPI release) and constrained in the templates until then.

### Inbound webhooks
- `POST /api/v1/hooks/:token` — public ingress that starts a run on the mapped agent (`trigger_type: "webhook"`). The server-generated token in the URL is the credential; unknown and disabled tokens answer identically.
- Provider signatures verified against the **raw body** (cached by a scoped `body_reader` before JSON parsing): `github` (X-Hub-Signature-256), `stripe` (t/v1 with replay bound), `slack` (v0 with replay bound). Constant-time comparison throughout; a signature type requires a secret at write time.
- `message_path` extracts the run message from the payload (default: the whole payload as pretty JSON); `conversation_key_path` keys persistent history per sender, namespaced `hook_{id}_` so hook-derived keys can't collide with client keys.
- Busy conversations return 409 — webhook providers retry non-2xx, which is the desired backoff for free.

### Serverless workers wake, then connect (decided 2026-10-15)
- A serverless worker is an ordinary worker with a wake URL in front of it. Its tools and capabilities are declared in Postgres (`serverless_workers`, `POST /api/v1/serverless_workers`) so the registry can advertise them while nothing is connected. A task with no connected worker queues as before, and Norns POSTs a signed wake (`{"type":"wake"}`, Stripe-style HMAC) to the declaring worker; it connects over `/worker` and the queue flushes to it on join. See `serverless-workers.md`.
- Rejected: an HTTP task transport (POST the task, read the result from the response). It would have been a second protocol — a result callback for anything longer than the platform's request cap, its own timeout and retry semantics, and no `drain`, ports or streaming. Waking the worker reuses everything that exists.
- The worker holds the wake request open while it serves: on Fly, Cloud Run and Lambda an instance lives as long as it has an inbound request, and the outbound WebSocket does not count. Norns holds its side for up to an hour and ignores the response.
- One wake per worker per 30 s cooldown, re-sent while work is still queued and the worker still absent; the queue's stale sweep bounds it. Serverless workers have no gard, same rule as connectors.

### Run webhooks push the three moments a poller waits for (decided 2026-10-16)
- A run parking on `ask_human`, completing, or failing had no outbound signal, so a chat channel relaying questions and outputs had to poll `GET /runs` and therefore stay awake. `run_webhooks` (`POST /api/v1/run_webhooks`) are a tenant-scoped URL plus a subset of `run.waiting`, `run.completed`, `run.failed`; Norns POSTs a signed event at each, Stripe-style HMAC under a once-shown secret. See `run-webhooks.md`.
- Fed from the agent process's single `broadcast/3`, the same call the dashboard and agent channel hear, so there is no second account of what a run is doing.
- Fire-and-forget in a supervised task: no delivery log, no replay. A receiver that misses one reconciles from `GET /runs` on its next wake. Adding a log before a receiver needs it would be speculation.
- The wake and the webhook are the two halves of a fully sleeping deployment: the wake brings a worker up to serve a tool call, the webhook brings a channel up to relay a state change. Fulla is the first deployment with both halves asleep.

### Sub-agent crash recovery
- A resumed parent reattaches to its in-flight child by run id instead of relaunching it — a pending `launch_agent` is a reference to work already underway, not a request.
- Subscribe-before-read closes the completion race; `run_id` rides on every agent broadcast; a parent resumed alone restarts its own orphaned child.
- See `architecture.md` § "Recovering a parent that was awaiting a sub-agent".

### A sub-agent can keep its conversation (decided 2026-09-14)

Every `launch_agent` used to mint a fresh conversation key. That is right for
a read-only explorer and wrong for a coder: sleipnir's team hands one coder a
sequence of assignments in a session, and a coder that forgets the last one
re-reads the tree to find out what it just did. Worse, two launches in a row
started two coders editing the same working tree at once.

Now the child opts in with `model_config["subagent_conversation"]`:
`"per_launch"` (the default, unchanged) or `"per_parent"`, which keys the
child's conversation `subagent:<parent conversation id>`. It is the child's
setting because it describes the child — whether it is safe to run twice is
not the launcher's call. A parent run with no conversation falls back to
per-launch. `Norns.Agents.SubagentConversation` holds it, in the same
parsed-from-`model_config`, permissive-defaults shape as the two policies.

One conversation is one process, and a busy process already refuses
messages, so the second writer is ruled out by what was there: a launch into
a child that is still working returns a `subagent_busy` result
(`data: {"agent_name"}`, `is_error`) instead of the generic
`subagent_launch_failed`. No audit event: nothing was decided, the launch was
allowed and `subagent_launch_allowed` already says so; the kinded result is
the record. Refused rather than queued, because the model can wait for the
launch it already has, and a queue would be a second writer on a delay.

The reuse opened a hole that had been closed only by accident. A message
arriving at a conversation parked on `ask_human` is taken as the answer —
the primary path for chat clients. With per-launch keys no launch could ever
reach a parked conversation. With a reusable one, a parent's instructions
could land as the user's reply to the child's question, and sleipnir asks
permission through `ask_human`. So a `send_message` carrying lineage
(`parent_run_id`, or a depth above zero) to a parked process is refused as
busy, and the question stays open for the human it was put to.

Recovery needed nothing: resume already restarts a child under the key its
run's conversation records, whatever shape that key has. There is a test
that says so.

Sessions: `GET /api/v1/sessions` keeps listing child conversations — a client
drawing a session tree needs them, and a child parked on a question is what
marks its parent session as needing you. Every child key starts with
`subagent`, and the embedded run carries `parent_run_id`. `?subagents=false`
leaves out conversations whose runs all have a parent, for a client that
wants only the top level.

Found while checking the worker side: worker routing never looked at agents.
LLM tasks go to any `llm` worker in the tenant and gard, tool tasks to any
worker advertising the tool in the gard, and the `agents` list in a join
payload is not read at all (the SDK registers agents over REST). A worker
listing several agents already serves all of them; a channel test now pins
that.

---

## Open

### Multi-node
- Single-node is the supported deployment. Durability comes from the
  Postgres event log, not from clustering, so one node restarting loses
  no run state. Only the live worker/task view (`WorkerRegistry`,
  `TaskQueue`) is node-local.
- Multi-node is planned: libcluster for discovery, Horde for the agent
  registry/supervisor and `WorkerRegistry`, and either a clustered or
  Postgres-backed `TaskQueue`. Pull requests welcome. Until then the hosted
  instance is held at one machine (`fly scale count 1`, boot-time guard in
  `Norns.Application`). `nornscode/norns#17` is the one time this bit,
  from an unclustered multi-machine Fly setup.

### A content-blind core
- Core already routes on the envelope and stores content without reading it
  (`Norns.Runtime.Content`, the opaque-content suite). What a hosted core
  that *cannot* read content would take, who would buy it, and what still
  touches plaintext (webhook ingress, the dashboard, the def's prompt) is
  in `plan-opaque-core.md` (2026-10-16). Documented, not scheduled: it
  only matters when someone other than the tenant runs core.

### Policy enforcement
- Pre-dispatch hook point in the orchestrator (not built, architecture supports it).
- Rule-based (orchestrator evaluates) and LLM-evaluated (worker evaluates) flavors.
- `SubagentPolicy` and `ToolPolicy` are both bespoke policy checks; a third one is the signal to build the generic hook.

### Cloud readiness
Gaps that become real the moment there is a hosted product (see `roadmap.md` § Cloud readiness):
- **API key scoping** — a tenant token is full tenant power. A hosted builder holding one is the same trust problem the worker introspection toolkit was pruned for; scoped keys (read-only, def-write-only) are the pre-cloud form of the capability model. The first scope, a gard worker's key, shipped 2026-10-21 (see § API keys scoped to a gard worker); the builder's scopes are not built.
- **Tenant self-serve** — signup → tenant → key issuance is cloud-repo work, but the core API must not preclude it.
- **Retention** — cron-triggered agents generate events unboundedly; needs a plan before cloud launch, not before growth.
- **Webhook signature verification** — per-hook tokens plus provider signatures (Slack signing secret, Stripe signature) belong in the hooks design from the start.
- **SDK hardening** — the Python serial-task bug and missing graceful shutdown are tolerable for dev workers, not for connectors running 24/7 in managed gards.
