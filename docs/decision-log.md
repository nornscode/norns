# Decision Log

Last updated: 2026-09-09

## Product Decisions

### Pure orchestrator — no execution
- Norns is a state machine and event log. It never makes LLM calls or executes tools.
- All execution happens on workers. You need a connected worker to do anything.
- Built-in tools (wait, ask_human, launch_agent, list_agents) are intercepted by the orchestrator, never sent to workers. All other tools are worker-provided.
- The orchestrator's job: dispatch tasks, persist events, manage state, crash recovery.
- Purity means the orchestrator never touches the outside world — no credentials, no user data, no third-party APIs. Reading/writing the runtime's own state (runs, defs, events) does not break it; holding a Slack token would.

### Content is opaque (decided 2026-09-09)
- The data-plane half of purity. The orchestrator routes on the **envelope** (roles, kinds, tool names, tool-call ids, steps, usage, stop reasons, error classes, agent and gard ids) and never reads, transforms, or generates **content** (message text, tool arguments, tool results, system prompts, questions and answers, run output). A content position holds a string, a structured map, or an opaque block a worker encrypted with a key core does not hold — and core treats all three the same: store, forward, never look inside. `Norns.Runtime.Content`; the conformance suite is `test/norns/runtime/opaque_content_test.exs`.
- Why: the coding harness puts source code in the event log, and "we cannot read your log" is only credible if core never needed to. Writing the rule down before compaction and chains land is what keeps them from growing content reads; the audit that made it true was eight small fixes (`plan-harness-e2e.md`).
- Consequences: workers compose the system prompt (`summary` and `date` ride in the task envelope), report `final_output`, elide old tool results, and render every result core resolves itself from a `kind` plus envelope `data` — `Norns.LLM.Format.render_message/1` is the reference. What stays plain and core-written: diagnostic error text on `run_failed`/`retry` and the registry's `worker disconnected`, none of which carries tenant content. `runs.output` is still a string column; a block lands there JSON-encoded until encryption ships (E2).

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

### Provider-neutral LLM format
- Tool calls: separate `tool_calls` array with `arguments`, not Anthropic content blocks.
- Tool results: `role: "tool"` messages with `tool_call_id`, not content blocks in user messages.
- `finish_reason`: `stop` / `tool_call` / `length` — not Anthropic-specific values.
- `Norns.LLM.Format` translates neutral ↔ Anthropic at the worker boundary.

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

### Sub-agent crash recovery
- A resumed parent reattaches to its in-flight child by run id instead of relaunching it — a pending `launch_agent` is a reference to work already underway, not a request.
- Subscribe-before-read closes the completion race; `run_id` rides on every agent broadcast; a parent resumed alone restarts its own orphaned child.
- See `architecture.md` § "Recovering a parent that was awaiting a sub-agent".

---

## Open

### Multi-node
- Registry + DynamicSupervisor are single-node.
- Port to Horde when clustering is needed.

### Policy enforcement
- Pre-dispatch hook point in the orchestrator (not built, architecture supports it).
- Rule-based (orchestrator evaluates) and LLM-evaluated (worker evaluates) flavors.
- `SubagentPolicy` and `ToolPolicy` are both bespoke policy checks; a third one is the signal to build the generic hook.

### Cloud readiness
Gaps that become real the moment there is a hosted product (see `roadmap.md` § Cloud readiness):
- **API key scoping** — one bearer token is full tenant power today. A hosted builder holding a tenant token is the same trust problem the worker introspection toolkit was pruned for; scoped keys (read-only, def-write-only) are the pre-cloud form of the capability model.
- **Tenant self-serve** — signup → tenant → key issuance is cloud-repo work, but the core API must not preclude it.
- **Retention** — cron-triggered agents generate events unboundedly; needs a plan before cloud launch, not before growth.
- **Webhook signature verification** — per-hook tokens plus provider signatures (Slack signing secret, Stripe signature) belong in the hooks design from the start.
- **SDK hardening** — the Python serial-task bug and missing graceful shutdown are tolerable for dev workers, not for connectors running 24/7 in managed gards.
