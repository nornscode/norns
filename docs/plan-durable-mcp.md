# Durable MCP — Implementation Plan

## Vision

Make MCP tool calls crash-safe, exactly-once, and replayable — without changing agent code or MCP servers. A developer using any agent framework (LangGraph, Claude Code, custom) drops in `DurableMCP` and their tool calls survive process death.

This is the entry point to the Norns ecosystem. Three tiers of the SDK, increasing commitment:

| Surface | What it does | Buy-in |
|---------|-------------|--------|
| `DurableMCP` | Crash-safe tool calls | Just durable tools |
| `Agent(name, model, tools)` | Full agent with built-in loop | Norns runs the loop |
| `@agent` + `ctx.*` | Custom workflow with durable primitives | Developer owns the loop |

This plan covers tier 1: `DurableMCP`.

## Developer experience

### Before (naked MCP call)

```python
result = await session.call_tool("run_tests", {"path": "src/"})
# If process dies here, result is lost. Retry may re-run tests.
```

### After (durable MCP call)

```python
from norns import DurableMCP

mcp = DurableMCP("http://localhost:4000", api_key="nrn_...")

result = await mcp.call("run_tests", {"path": "src/"})
# Checkpointed. Crash-safe. Idempotent on retry.
```

### What happens under the hood

```
mcp.call("run_tests", {"path": "src/"})
  │
  ├─ 1. SDK generates a stable call ID (deterministic from tool name + args + sequence)
  ├─ 2. SDK sends step_request to Norns: "execute tool 'run_tests' with these args"
  │     └─ Norns persists a tool_call event (recorded before execution)
  ├─ 3. Norns dispatches the tool to a worker (or the same process, via callback)
  │     └─ Tool runs: tests execute for 4 minutes
  ├─ 4. Result arrives. Norns persists a tool_result event (checkpointed)
  ├─ 5. Norns returns the result to the SDK
  └─ 6. SDK returns result to caller
```

If the process dies at step 3 (mid-execution):
- On restart, `mcp.call("run_tests", ...)` checks the event log
- Sees tool_call but no tool_result → re-dispatches (tool should be idempotent)
- Or if tool_result exists → returns cached result immediately

If the process dies at step 5 (result persisted but not returned):
- On restart, `mcp.call("run_tests", ...)` finds the cached tool_result → returns it
- No re-execution

### Session and resume

```python
mcp = DurableMCP("http://localhost:4000", api_key="nrn_...")

# Start a durable session (creates a Norns run)
async with mcp.session("my-task-123") as session:
    # Each call is checkpointed in order
    test_result = await session.call("run_tests", {"path": "src/"})
    lint_result = await session.call("lint", {"path": "src/"})
    
    if test_result["passed"]:
        await session.call("deploy", {"env": "staging"})
```

If the process crashes after `run_tests` completes but before `lint`:
- Restart with the same session ID `"my-task-123"`
- `session.call("run_tests", ...)` returns the cached result instantly (no re-run)
- `session.call("lint", ...)` executes live (first time)

The session ID is the resume key. Same session ID = replay from where you left off.

### Standalone usage (no agent)

DurableMCP doesn't require a Norns agent. No `Agent()`, no system prompt, no LLM. Just durable tool calls:

```python
from norns import DurableMCP

mcp = DurableMCP("http://localhost:4000", api_key="nrn_...")

async with mcp.session("migration-2024") as session:
    await session.call("backup_database", {})
    await session.call("run_migration", {"version": "042"})
    await session.call("verify_schema", {})
    # If we crash after backup but before migration,
    # restart replays backup (cached) and continues from migration
```

## Architecture

### What exists today (and can be reused)

**Norns server already has:**
- Event persistence (`RunEvent` with `tool_call` and `tool_result` event types)
- Idempotency keys (deterministic: `run:{id}:step:{step}:tool:{call_id}:name:{name}`)
- Idempotency checking (`Runs.find_duplicate_side_effect()` → returns cached result)
- Worker dispatch via WebSocket (`WorkerRegistry.dispatch_task()`)
- Run lifecycle (create, running, completed, failed)
- Resume from event log (`replay_from_events()`)

**Python SDK already has:**
- WebSocket connection to Norns (Phoenix v2 protocol)
- Tool registration and execution
- `@tool` decorator with JSON Schema inference

### What's new

#### Norns server

**1. Headless runs**

Today, runs require an agent. DurableMCP sessions need runs without agents — just a sequence of tool calls with event persistence.

Add a new run type:

```elixir
# New trigger_type
Runs.create_run(%{
  tenant_id: tenant_id,
  trigger_type: "durable_mcp",
  status: "running",
  input: %{"session_id" => session_id}
})
```

No agent_id required (nullable FK or a sentinel). The run is just a container for tool_call/tool_result events.

**2. Step request channel**

New WebSocket channel or new message types on the existing worker channel:

```
Client → Norns:
  "step_request" %{
    "session_id" => "my-task-123",
    "call_id" => "call_001",          # stable, deterministic
    "tool_name" => "run_tests",
    "arguments" => %{"path" => "src/"},
    "sequence" => 1                    # monotonic step counter
  }

Norns → Client:
  "step_result" %{
    "call_id" => "call_001",
    "status" => "ok" | "error",
    "result" => "...",
    "cached" => true | false           # was this replayed from log?
  }
```

**3. Step executor process**

A lightweight GenServer (or reuse of the existing Process) for durable_mcp runs:

- Receives step_request
- Checks event log for existing result (idempotency)
  - If found: return cached result immediately
  - If not found: persist tool_call event, dispatch to worker, wait for result, persist tool_result event, return
- Tracks sequence number to enforce ordering

This is much simpler than the full agent process — no LLM loop, no state machine, no checkpoint policy. Just: record, execute, record.

**4. Resume on reconnect**

When a client reconnects with a session_id:
- Load the run and its events
- Send the event log to the client
- Client SDK replays its call sequence against the log

#### Python SDK

**1. `DurableMCP` class**

```python
class DurableMCP:
    def __init__(self, url: str, api_key: str):
        # WebSocket connection to Norns
        
    def session(self, session_id: str) -> DurableSession:
        # Returns async context manager
        
class DurableSession:
    def __init__(self, mcp: DurableMCP, session_id: str):
        self._sequence = 0
        self._event_log = []  # populated on resume
        
    async def call(self, tool_name: str, arguments: dict) -> Any:
        self._sequence += 1
        call_id = f"{self.session_id}:{self._sequence}"
        
        # Check local event log (replay mode)
        cached = self._find_cached_result(call_id)
        if cached:
            return cached
        
        # Send step_request to Norns, wait for step_result
        result = await self._send_step_request(call_id, tool_name, arguments)
        return result
```

**2. Tool execution routing**

When Norns receives a step_request, it needs to actually execute the tool. Two options:

**Option A: Worker executes tools.** The DurableMCP client also registers as a worker with tool capabilities. Norns dispatches the tool_task back to it (or another worker). This reuses the existing dispatch infrastructure.

**Option B: Callback execution.** The client provides a callback for tool execution. The SDK executes the tool locally and sends the result to Norns for persistence. Simpler, but tools only run on the client process.

**Recommendation: Option A for v1.** It reuses WorkerRegistry and supports tools running on different workers. The DurableMCP client connects as both a step requester and a worker.

**3. MCP server wrapping**

To wrap an existing MCP server transparently:

```python
from norns import DurableMCP
from mcp import ClientSession

mcp_session = ClientSession(...)  # standard MCP connection
durable = DurableMCP("http://localhost:4000", api_key="nrn_...")

# Wrap the MCP session
async with durable.session("task-123") as session:
    # This calls the MCP server, but with durability
    result = await session.call("run_tests", {"path": "src/"},
                                 executor=mcp_session)
```

The `executor` parameter tells the SDK how to actually run the tool. If omitted, it dispatches through Norns workers (Option A). If provided, it calls the executor directly and persists the result.

## Implementation roadmap

### Phase 1: Headless runs (Norns server)

Allow runs without agents. This is the foundation.

Files:
- `lib/norns/runs/run.ex` — make `agent_id` optional
- `lib/norns/runs.ex` — `create_headless_run(tenant_id, session_id)`
- Migration — alter runs table, `agent_id` nullable

Tests:
- Create a run with no agent_id
- Append events to it
- List events

### Phase 2: Step request protocol (Norns server)

Add step_request/step_result message handling.

Files:
- `lib/norns_web/channels/worker_channel.ex` — handle `"step_request"` messages
- `lib/norns/agents/step_executor.ex` (new) — lightweight process for durable_mcp runs
  - Receives step requests
  - Checks idempotency (reuse `Runs.find_duplicate_side_effect()`)
  - Persists tool_call event
  - Dispatches to worker
  - Persists tool_result event
  - Returns result
- `lib/norns/agents/step_executor.ex` — handle resume (load events, send to client)

Tests:
- Send step_request, receive step_result
- Send same step_request twice, get cached result
- Disconnect mid-step, reconnect, resume

### Phase 3: DurableMCP client (Python SDK)

Implement the client-side library.

Files (in norns-sdk-python):
- `norns/durable_mcp.py` (new) — `DurableMCP` and `DurableSession` classes
- `norns/__init__.py` — export `DurableMCP`

Implementation:
- WebSocket connection (reuse existing Phoenix protocol code)
- Session management (create run, track sequence)
- Replay from event log on resume
- `call()` method with idempotency check

Tests:
- `DurableSession.call()` executes tool and returns result
- Process restart replays cached results
- Duplicate calls return cached results
- Parallel sessions work independently

### Phase 4: MCP server wrapping

Add the `executor` parameter so DurableMCP can wrap standard MCP servers.

Files:
- `norns/durable_mcp.py` — add executor support to `call()`
- `norns/mcp_adapter.py` (new) — adapter that wraps an MCP ClientSession

This lets someone take their existing MCP setup and add durability:

```python
durable = DurableMCP.wrap(mcp_session, norns_url="...", api_key="...")
result = await durable.call_tool("run_tests", {"path": "src/"})
```

### Phase 5: Documentation and examples

- README update with DurableMCP quickstart
- Example: durable MCP with Claude Code
- Example: durable MCP with LangGraph
- Example: standalone migration script with durable steps

## Open questions

- **Agent-id nullable**: Making agent_id nullable on runs is a schema change. Alternative: create a synthetic "durable_mcp" agent per tenant that owns all headless runs. Simpler FK handling but less clean.
- **Tool registration**: Does the DurableMCP client need to register tools with Norns upfront, or can it register them on-the-fly with each step_request? On-the-fly is simpler for the developer.
- **Concurrency**: Can a session have parallel in-flight step_requests? Phase 1 should probably be sequential (one step at a time). Parallel steps are a later optimization.
- **Session timeout**: How long does a session stay open? Should it auto-complete after inactivity?
- **Billing/limits**: If this is on nornscloud.com, how do we meter usage? Per step_request? Per session?

## Relationship to custom agent workflows

DurableMCP is **Phase 0** of the custom workflow plan. It builds the step_request/step_result protocol and the "Norns as durable execution backend" pattern. The custom workflow plan (`@agent` + `ctx.*`) builds on top of this:

- `ctx.tool_call()` uses the same step_request protocol as `DurableMCP.call()`
- `ctx.llm_call()` adds an LLM-specific step_request type
- The replay engine is the same: check event log, return cached results, continue live

Building DurableMCP first means the custom workflow plan gets the protocol and replay engine for free.
