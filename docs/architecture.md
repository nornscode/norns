# Architecture

## Product Vision

Norns is infrastructure for running LLM-powered agents that survive crashes and resume without losing progress. The product surface is a REST API + WebSocket streaming + SDKs — not a UI or chat builder.

## Current State

Durable agent runtime (Phase 1 complete):

```
Supervisor
├── Norns.Repo (Ecto/PostgreSQL)
├── Oban (background job processor)
├── Phoenix.PubSub (event broadcasting)
├── Registry (agent process lookup)
└── DynamicSupervisor (agent GenServers)
    └── Agents.Process — LLM-tool loop with event persistence
```

**Agent execution flow:**
1. `Agents.Registry.start_agent/3` spawns a GenServer under DynamicSupervisor
2. `send_message/3` delivers a user message to the running agent
3. Agent enters LLM-tool loop via `handle_continue`:
   - Log `llm_request` event → call `LLM.chat/5` → log `llm_response` event
   - If `stop_reason == "end_turn"` → complete the run
   - If `stop_reason == "tool_use"` → execute tools, log results, loop back
4. Every step is persisted as a RunEvent BEFORE the next step executes

**Durability rule:** persist events before executing the next step. On crash, state is reconstructed from the event log.

**Data model:**
- `tenants` — name, slug, api_keys (Anthropic key per tenant)
- `agents` — name, purpose, system_prompt, model, model_config, tools_config, max_steps, status, tenant_id
- `runs` — status, trigger_type, input, state, output, resumed_from_event_id, agent_id, tenant_id
- `run_events` — sequence, event_type, payload, source, metadata, run_id, tenant_id

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

## Key Design Principles

### Durable Execution via Event Sourcing

Every LLM call, tool execution, and state change is logged as a RunEvent. The event log is the source of truth. Agent state can be reconstructed from events at any point.

### Error Taxonomy

Four categories, each with a different recovery path:
1. **Transient** (network, rate limits) → automatic retry with backoff
2. **LLM-recoverable** (bad tool call, parse failure) → feed error back to the LLM
3. **User-fixable** (missing info, needs approval) → interrupt/resume (future)
4. **Unexpected** → bubble up, mark run as failed

### Multi-Tenancy Is Structural

Every table has `tenant_id`. Agent names unique per tenant. API keys per tenant. Enforced at the data model level.

### LLM Module Is Swappable

`Norns.LLM` dispatches to a configured backend module (`Norns.LLM.Behaviour`). Tests use `Norns.LLM.Fake` with scripted responses. Production uses `Norns.LLM.Anthropic`.

## Next: API Surface (Phase 2)

- Wire up Phoenix endpoint with REST controllers
- Bearer token auth against tenant api_keys
- WebSocket channel for real-time agent events via PubSub
- Endpoints for agent CRUD, start/stop, messaging, run history
