# Decision Log

Last updated: 2026-03-25

## Product Decisions

### Scope reset (execution reliability first)
- Norns is framed as a reliable execution layer, not a broad "agent OS".
- Durable value focus:
  1. correctness under failure
  2. operator control
  3. queryable execution state without re-inference
- Transcript persistence is often sufficient for simple single-agent flows; Norns focuses on production execution guarantees.
- Worker-hosted execution remains deferred.
- Broader framework/platform expansion is explicitly de-prioritized until reliability core is hardened.

### Durable agent runtime on BEAM
- Norns is an open-source (MIT), self-hostable, agent-native durable runtime
- The gap: no MIT-licensed, self-hostable, agent-native durable runtime exists. Temporal is MIT but general-purpose and operationally heavy. Everything else is platform-locked or BSL.
- BEAM is the differentiator: OTP supervisors, lightweight processes, built-in distribution, hot code reloading, GenServers as natural agent primitive

### Self-hosted first, cloud as convenience
- The framework builds trust and adoption as open source
- Norns Cloud monetizes convenience (managed hosting, dashboard, observability)
- Not "give us your AI brain" — more like "Heroku for your agent framework"

### Worker model, not HTTP callbacks
- Norns never calls out to user code via HTTP
- Workers make outbound persistent WebSocket connections to the runtime, register tools, receive tasks
- Like Temporal's activity workers but with persistent connections instead of polling
- Workers execute locally with full access to user's DBs, APIs, secrets
- Self-hosted mode: worker and runtime share the same BEAM VM, tool calls are local function calls

### Three tool layers
- Built-in tools (ship with norns), user-defined tools (via SDK/worker), MCP tools (future)
- From the agent's perspective all tools look identical: name, description, schema, execute
- Durability wraps all tools uniformly: checkpoint before calling, persist result, skip on replay
- Executor transparently handles local vs remote tools via `source` field on Tool struct

### Don't build integrations
- Use managed integration platforms (Nango, Composio) or plain HTTP
- Build zero connectors until the core runtime is proven valuable

---

## Implemented

### Multi-tenancy from day one
- Every table has `tenant_id` (NOT NULL, FK to tenants)
- Agent names unique per tenant
- API keys stored per tenant

### Durable agent GenServer (Phase 1)
- Agents run as GenServers (`Agents.Process`) under a DynamicSupervisor
- LLM-tool loop: call LLM → if tool_use, execute tools → loop; if end_turn, complete
- Every step persisted as a RunEvent BEFORE executing the next step
- State reconstruction from events enables crash recovery
- Orphan recovery on boot resumes interrupted runs

### REST API + WebSocket channels (Phase 2)
- Phoenix REST API: agent CRUD, start/stop, status, messaging, run history, conversations
- Bearer token auth matching against tenant api_keys
- Agent WebSocket channel (`/socket`): real-time event streaming via PubSub
- `send_message` auto-starts the agent process if not already running
- All endpoints scoped to authenticated tenant

### AgentDef + configurable policies (Phase 3)
- `AgentDef` struct: model, system_prompt, mode, tools, checkpoint_policy, max_steps, on_failure, context_strategy, context_window
- `AgentDef.from_agent/2` builds from Agent schema, reads all config from model_config map
- Checkpoint policies: `:every_step`, `:on_tool_call` (default), `:manual`
- Failure recovery: `:stop` (default) or `:retry_last_step` (exponential backoff, max 3 retries)
- Rate limits (429) get longer backoff: 15s base, up to 10 retries
- Retry events logged for observability

### Module-based tool definitions (Phase 3)
- `Norns.Tools.Behaviour` with callbacks: `name/0`, `description/0`, `input_schema/0`, `execute/1`
- `use Norns.Tools.Behaviour` macro auto-generates `__tool__/0` returning a `%Tool{}` struct
- ETS-backed `Tools.Registry` for built-in tools, auto-registered on boot

### Built-in tools
- `web_search` — DuckDuckGo HTML search, parsed with Floki, returns top 5 results
- `http_request` — GET/POST via Req, HTML stripped to text, body truncated to 1.5K chars
- `shell` — execute allowlisted commands with 30s timeout
- `ask_user` — interrupt/resume for human-in-the-loop (agent pauses, surfaces question, waits)
- `store_memory` — persist a fact to agent memory (upsert by key)
- `search_memory` — keyword search across agent memory

### Worker protocol (Phase 4)
- Worker WebSocket at `/worker` with tenant token auth
- Workers join `"worker:lobby"` with worker_id and tool definitions
- `WorkerRegistry` GenServer tracks connected workers, their tools, and pending tasks
- Server pushes `tool_task` to workers via channel; workers reply with `tool_result`
- `TaskQueue` GenServer holds tasks when no worker available, flushes on reconnect
- Worker disconnect detected via process monitoring; cleanup automatic

### Task vs conversation mode (Phase 5)
- `:task` mode (default): each message starts fresh, no memory between runs
- `:conversation` mode: persistent message history across runs, identified by external key
- Registry key: `{tenant_id, agent_id, conversation_key}` — supports concurrent conversations per agent
- Sliding window context management (configurable window size, default 20 messages)
- Conversation summary prepended to system prompt if present
- Conversations persisted to `conversations` table on run completion
- Crash recovery loads conversation from DB, then replays run events on top

### Agent memory (Phase 5)
- `memories` table: agent_id, key (unique per agent), content, metadata
- `store_memory` tool — agent decides what's worth remembering
- `search_memory` tool — keyword search on key + content via ILIKE
- Memory is shared across all conversations for an agent
- System prompt auto-appended with memory instructions when memory tools are available

### Human-in-the-loop (Phase 5)
- `ask_user` tool intercepted by Process before reaching Executor
- Regular tool calls in the same response execute first, then agent pauses
- Run status transitions: running → waiting → running → completed
- `waiting_for_user` and `user_response` event types in the audit log
- Fully durable: crash while waiting resumes to waiting state

### LiveView dashboard (Phase 6)
- `/` — agents list with live status badges, start/stop, create agent form
- `/agents/:id` — agent detail, message input, live event stream, run history
- `/runs/:id` — run timeline with color-coded events and payload details
- `/tools` — built-in and worker-provided tools
- `/setup` — tenant creation with auto-generated API key
- Session auth via cookie; first visit redirects to setup if no tenants exist
- Real-time updates via PubSub subscriptions in LiveView mount

### LLM module with swappable backends
- `Norns.LLM` dispatches to configured backend via behaviour
- `Norns.LLM.Anthropic` — multi-turn Messages API with tool use support
- `Norns.LLM.Fake` — ETS-backed scripted responses + call recording for tests
- Current date auto-injected into system prompt
- Old tool results compacted to 200 chars before sending to LLM (token management)

### Runtime contracts (Phase 7)
- All events versioned (`schema_version: 1`) and validated via `Norns.Runtime.Events` before persistence
- 5-class error taxonomy with deterministic retry policy (`Norns.Runtime.ErrorPolicy`)
- Idempotent side effects: deterministic keys prevent duplicate execution under replay/retry
- Tools can declare `side_effect?: true` via behaviour callback
- Failure inspector: `failure_metadata` on runs + structured API response for operator diagnosis
- Replay conformance test suite proves checkpoint/restore invariants

### Orchestrator/Worker split (Phase 8)
- The agent GenServer is now a pure state machine — dispatches tasks, never executes
- All LLM calls dispatched via `WorkerRegistry.dispatch_llm_task` → worker handles API call
- All tool calls dispatched via `WorkerRegistry.dispatch_task` → worker handles execution
- Agent states: `:idle`, `:awaiting_llm`, `:awaiting_tools`, `:waiting`
- Agent is never blocked — always responds to get_state, stop, messages
- `DefaultWorker` runs in same BEAM VM for self-hosted mode (handles LLM + built-in tools)
- External workers connect via `/worker` WebSocket, register capabilities `[:llm, :tools]`
- Rate limits are the worker's problem — orchestrator never sees a 429
- Workers hold API keys — orchestrator never sees them in external mode

### Docker Compose for all dev tooling
- No local Elixir install. `Dockerfile.dev` + app service in docker-compose

---

## Open

### A) SDK design (Phase 9)
- TypeScript and Python SDKs
- `@tool` decorator generates JSON schema from type hints
- `run.stream()` as WebSocket iterator over agent events
- `Worker.connect()` as long-lived WebSocket to `/worker`

### B) LLM provider abstraction
- Currently Anthropic-only via behaviour pattern
- Add OpenAI implementation when needed

### C) Vector memory
- Currently keyword search via ILIKE
- pgvector for semantic search, embeddings computed on store_memory

### D) Multi-node distribution
- Current Registry + DynamicSupervisor are single-node
- Port to Horde for multi-node when clustering is needed
- PubSub already supports distributed Erlang or Redis backend

### E) Context summarization
- Currently sliding window only (discard old messages)
- Future: LLM-powered summarization of old context into a paragraph
