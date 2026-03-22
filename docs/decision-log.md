# Decision Log

Last updated: 2026-03-22

## Product Decisions

### Pivot: durable agent runtime, not chat-based workflow builder
- Originally planned as a Lua-based workflow engine with a chat builder that generates Lua scripts
- Pivoted to a durable agent runtime — infrastructure for running LLM-powered agents that survive crashes
- The product surface is a REST API + WebSocket streaming + SDKs
- Agents run as GenServers with an LLM-tool loop, not as Lua script execution

### Don't build integrations
- Use managed integration platforms (Nango, Composio) or plain HTTP
- Build zero connectors until the core runtime is proven valuable

---

## Implemented

### Multi-tenancy from day one
- Every table has `tenant_id` (NOT NULL, FK to tenants).
- Agent names unique per tenant.
- API keys stored per tenant.

### Schema simplification — defer version pinning
- Removed all version columns from runs, removed `run_decisions` table.
- Add back when policy gates or versioning logic exist.

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
- Backward-compatible `complete/5` wrapper preserved

### Tool execution framework
- `Tools.Tool` struct with name, description, input_schema, handler function
- `Tools.Executor` dispatches tool_use blocks to matching handlers
- Tools convert to Anthropic API format for LLM calls

### Agent lifecycle management
- `Agents.Registry` — start, stop, lookup, resume, send_message
- Process naming via Elixir Registry: `{tenant_id, agent_id}`
- DynamicSupervisor with `:temporary` restart (agents don't auto-restart on crash — orphan recovery handles it)

### Event-sourced run audit trail
- Every step logged as a `RunEvent` with sequence, event_type, payload.
- Unique constraint on (run_id, sequence).
- Event types: agent_started, llm_request, llm_response, tool_call, tool_result, checkpoint, agent_completed, agent_error

### PubSub for real-time events
- Agent GenServer broadcasts events via Phoenix.PubSub
- Topic per agent: `"agent:<agent_id>"`
- Foundation for WebSocket channels in Phase 2

### Docker Compose for all dev tooling
- No local Elixir install. `Dockerfile.dev` + app service in docker-compose.

### Error taxonomy
- Four error categories, each with a different recovery path:
  1. **Transient** (network, rate limits) → automatic retry with backoff
  2. **LLM-recoverable** (bad tool call, parse failure) → feed error back to the LLM
  3. **User-fixable** (missing info, needs approval) → interrupt/resume (future)
  4. **Unexpected** → bubble up, mark run as failed

---

## Open

### A) API surface design (Phase 2)
- REST endpoints for agent CRUD, lifecycle, messaging, run history
- Bearer token auth against tenant api_keys
- WebSocket channel for real-time event streaming

### B) Failure recovery policies
- Currently agents stop on error. Future: configurable `:retry_last_step` with backoff.

### C) LLM provider abstraction
- Currently Anthropic-only. When/how to support multiple providers.

### D) Agent definitions
- Declarative agent config: model, system_prompt, tools, checkpoint_policy, max_steps, on_failure
- Tool registry mapping names to handler modules
