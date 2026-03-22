# Decision Log

Last updated: 2026-03-22

## Product Decisions

### Durable agent runtime on BEAM
- Norns is an open-source (MIT), self-hostable, agent-native durable runtime
- The gap: no MIT-licensed, self-hostable, agent-native durable runtime exists. Temporal is MIT but general-purpose and operationally heavy. Everything else is platform-locked or BSL.
- BEAM is the differentiator: OTP supervisors, lightweight processes, built-in distribution, hot code reloading, GenServers as natural agent primitive

### Worker model, not HTTP callbacks
- Norns never calls out to user code via HTTP
- Workers make outbound persistent connections to the runtime, register tools, receive tasks
- Like Temporal's activity workers but with persistent connections instead of polling
- Workers execute locally with full access to user's DBs, APIs, secrets
- Self-hosted mode: worker and runtime share the same BEAM VM, tool calls are local function calls

### Three tool layers
- Built-in tools (ship with norns), user-defined tools (via SDK/worker), MCP tools (future)
- From the agent's perspective all tools look identical: name, description, schema, execute
- Durability wraps all tools uniformly: checkpoint before calling, persist result, skip on replay

### Don't build integrations
- Use managed integration platforms (Nango, Composio) or plain HTTP
- Build zero connectors until the core runtime is proven valuable

### Business model: open core
- Runtime + SDKs are MIT open source
- Norns Cloud is the paid managed offering (dashboard, observability, teams)

---

## Implemented

### Multi-tenancy from day one
- Every table has `tenant_id` (NOT NULL, FK to tenants)
- Agent names unique per tenant
- API keys stored per tenant

### Schema simplification — defer version pinning
- Removed all version columns from runs, removed `run_decisions` table
- Add back when policy gates or versioning logic exist

### Durable agent GenServer (Phase 1)
- Agents run as GenServers (`Agents.Process`) under a DynamicSupervisor
- LLM-tool loop: call LLM → if tool_use, execute tools → loop; if end_turn, complete
- Every step persisted as a RunEvent BEFORE executing the next step
- State reconstruction from events enables crash recovery
- Periodic checkpoints snapshot full message history to bound replay cost
- Orphan recovery on boot resumes interrupted runs

### LLM module with swappable backends
- `Norns.LLM` dispatches to configured backend via behaviour
- `Norns.LLM.Anthropic` — multi-turn Messages API with tool use support
- `Norns.LLM.Fake` — ETS-backed scripted responses for tests

### Tool execution framework
- `Tools.Tool` struct with name, description, input_schema, handler function
- `Tools.Executor` dispatches tool_use blocks to matching handlers
- Tools convert to Anthropic API format for LLM calls
- Future: module-based tools (`use Norns.Tool`) for worker protocol compatibility

### Agent lifecycle management
- `Agents.Registry` — start, stop, lookup, resume, send_message
- Process naming via Elixir Registry: `{tenant_id, agent_id}`
- DynamicSupervisor with `:temporary` restart (orphan recovery handles crash restart)

### Event-sourced run audit trail
- Every step logged as a `RunEvent` with sequence, event_type, payload
- Unique constraint on (run_id, sequence)
- Event types: agent_started, llm_request, llm_response, tool_call, tool_result, checkpoint, agent_completed, agent_error

### PubSub for real-time events
- Agent GenServer broadcasts events via Phoenix.PubSub
- Topic per agent: `"agent:<agent_id>"`
- Foundation for WebSocket channels in Phase 2

### Docker Compose for all dev tooling
- No local Elixir install. `Dockerfile.dev` + app service in docker-compose

### Error taxonomy
- Four error categories:
  1. **Transient** (network, rate limits) → automatic retry with backoff
  2. **LLM-recoverable** (bad tool call, parse failure) → feed error back to the LLM
  3. **User-fixable** (missing info, needs approval) → interrupt/resume (future)
  4. **Unexpected** → bubble up, mark run as failed

---

## Open

### A) API surface design (Phase 2)
- REST endpoints for agent CRUD, lifecycle, messaging, run history
- Bearer token auth against tenant api_keys
- WebSocket channel for real-time event streaming via Phoenix Channels

### B) Agent definitions (Phase 3)
- Declarative `AgentDef` struct: model, system_prompt, tools, checkpoint_policy, max_steps, on_failure
- Module-based tool definitions: `use Norns.Tool` with `@tool` attributes and `def execute/1`
- Tool registry mapping names to handler modules
- Configurable checkpoint policies: `:every_step`, `:on_tool_call`, `:manual`
- Failure recovery policies: `:stop` (current), `:retry_last_step` with backoff

### C) Worker protocol (Phase 4)
- Persistent connection management (WebSocket or TCP)
- Tool registration protocol (worker connects, advertises available tools)
- Task dispatch and result collection
- Reconnection handling (hold pending tasks, resume on reconnect)
- Self-hosted mode: local function calls, no network hop

### D) SDK design (Phase 5)
- TypeScript and Python SDKs
- Developers define agents and tools in their language
- SDK talks to Norns runtime over the REST/WS API

### E) Naming decisions before Phase 2
- Current table names (`runs`, `run_events`) become public via API
- Spec suggests `agent_runs`, `agent_events` — decide before API names are locked in
- Checkpoint storage: currently inline as event_type="checkpoint" in run_events. Separate `checkpoints` table may be needed when payloads get large.

### F) LLM provider abstraction
- Currently Anthropic-only via behaviour pattern
- Spec mentions supporting Anthropic + OpenAI — add OpenAI implementation when needed
