# Custom Agent Workflows

## Problem

Norns runs a prescriptive LLM-tool loop: call LLM → dispatch tools → collect results → repeat. The developer has zero control over what happens between steps. This covers simple "chatbot with tools" agents but blocks real production use cases:

- Parallel tool execution
- Conditional branching (retry differently, escalate, fork)
- Multi-phase agents (research → synthesize → review)
- Human-in-the-loop gates
- Multi-persona patterns (writer → editor → writer)
- Custom retry/fallback logic per step

Today, if someone needs any of these, they can't use Norns.

## Design

### Two modes, one entrypoint

**Simple mode (default)** — Norns owns the loop. Exactly how it works today:

```python
from norns import Norns, Agent, tool

@tool
def search(query: str) -> str:
    return "..."

agent = Agent(
    name="support-bot",
    model="claude-sonnet-4-20250514",
    system_prompt="You are helpful.",
    tools=[search],
)

norns = Norns("http://localhost:4000", api_key="nrn_...")
norns.run(agent)
```

No new concepts. The built-in loop handles LLM calls, tool dispatch, retries, and checkpointing automatically.

**Custom mode** — the developer owns the loop. Norns provides durable primitives:

```python
from norns import Norns, agent, tool

@tool
def search(query: str) -> str:
    return "..."

@tool
def send_email(to: str, body: str) -> str:
    return "sent"

@agent(
    name="research-bot",
    model="claude-sonnet-4-20250514",
    system_prompt="You are a research assistant. Be thorough.",
)
async def research_bot(ctx, message):
    # First pass: research
    response = await ctx.llm_call(message, tools=[search])

    if response.tool_calls:
        results = await ctx.parallel([
            ctx.tool_call(tc) for tc in response.tool_calls
        ])
        response = await ctx.llm_call(results)

    # Human gate
    approval = await ctx.wait_for_signal("approval", timeout=3600)
    if not approval:
        return "Declined by reviewer."

    # Send result
    await ctx.tool_call("send_email", to="team@co.com", body=response.content)
    return response.content

norns = Norns("http://localhost:4000", api_key="nrn_...")
norns.run(research_bot)
```

Same `norns.run()`, same worker connection, same tools. The difference is who controls the flow.

### Durable primitives (the `ctx` API)

Every `ctx.*` call is a durable checkpoint. If the worker crashes, it resumes from the last completed primitive — never re-executing side effects.

| Primitive | Description |
|-----------|-------------|
| `ctx.llm_call(message, tools=[], system_prompt=None)` | Call LLM with optional tool list and system prompt override. Returns response with content and tool_calls. |
| `ctx.tool_call(tool_call)` | Execute a single tool. Idempotent on replay. |
| `ctx.parallel([...])` | Execute multiple tool calls concurrently. Returns when all complete. |
| `ctx.wait(seconds)` | Durable timer. Survives crashes. |
| `ctx.wait_for_signal(name, timeout=None)` | Pause until external signal arrives (human approval, webhook, etc). |
| `ctx.checkpoint()` | Explicit save point. |
| `ctx.log(message)` | Append to run event log without affecting control flow. |

### How it works under the hood

```
Simple mode (today):
  Norns GenServer runs loop → dispatches tasks → worker executes → returns result

Custom mode (proposed):
  Worker runs @agent function → calls ctx.llm_call() → SDK sends request to Norns
  → Norns persists event, dispatches to LLM worker, returns result to SDK
  → Worker continues to next ctx.* call → Norns persists, dispatches, returns
  → ...until function returns
```

In custom mode, the worker drives the loop. Each `ctx.*` call is a round-trip:

1. Worker SDK sends a "step request" to Norns over WebSocket
2. Norns persists the event (llm_request, tool_call, etc.)
3. Norns dispatches the task (to itself for LLM, or to the worker pool for tools)
4. Norns persists the result event
5. Norns sends the result back to the worker SDK
6. Worker SDK returns from the `await` and the `@agent` function continues

### Resume after crash

When a worker reconnects and resumes a run:

1. Norns sends the full event log for the run
2. The SDK replays the `@agent` function from the beginning
3. Each `ctx.*` call checks the event log — if a result already exists, it returns the stored result immediately (no re-execution)
4. Once past the last recorded event, execution continues live

This is the Temporal model: deterministic replay with stored results. The `@agent` function must be deterministic — same inputs produce same control flow. Non-deterministic work (API calls, DB queries) happens inside tools, which are idempotent on replay.

### Determinism constraint

The `@agent` function must not use:
- `time.time()`, `random.random()`, `uuid.uuid4()` directly (use `ctx.now()`, `ctx.random()`)
- External I/O outside of `ctx.*` calls
- Mutable global state

This is the same constraint Temporal imposes. The SDK can warn on common violations at runtime.

## Architecture changes

### What stays the same

- **WorkerRegistry** — dispatches tasks to workers, agnostic to who's driving
- **Events** — append-only event log, works for any workflow shape
- **RunEvent schema** — no changes needed
- **Token tracking** — accumulated per llm_response event regardless of mode
- **Conversations** — message persistence unchanged
- **Tenants, API keys, auth** — unchanged
- **UI (LiveView)** — event timeline renders the same events regardless of mode
- **nornsctl** — runs/events/agents commands work the same

### What changes

#### Norns server (Elixir)

**`lib/norns/agents/process.ex`** — the big one.

Today: hardcoded loop in `handle_continue(:llm_loop)`.

Proposed: two execution modes.

- **Simple mode**: keep the existing loop as-is. No refactoring needed.
- **Custom mode**: the GenServer becomes a "step executor." Instead of driving the loop, it waits for step requests from the worker and executes them one at a time.

```
Simple mode GenServer states:
  idle → running → awaiting_llm → running → awaiting_tools → running → idle

Custom mode GenServer states:
  idle → running → awaiting_step_request → executing_step → awaiting_step_request → ... → idle
```

In custom mode:
- Worker sends a step request ("call LLM with these params" or "execute this tool")
- GenServer persists the event, dispatches the task, waits for result
- On result, persists result event, sends result back to worker
- Waits for next step request

**`lib/norns/agents/agent_def.ex`** — add `mode: :simple | :custom` field.

**`lib/norns_web/channels/worker_channel.ex`** — new message types for custom mode:
- `"step_request"` — worker requests a step (llm_call, tool_call, etc.)
- `"step_result"` — Norns returns step result to worker
- `"signal"` — external signal delivery (for wait_for_signal)

#### Python SDK

**New: `@agent` decorator** — wraps an async function as a custom workflow.

**New: `AgentContext` (ctx)** — provides the durable primitives. Each method:
1. Sends a step request to Norns over WebSocket
2. Waits for the step result
3. On resume, checks event log and returns stored result if available

**New: replay engine** — on reconnect, replays the `@agent` function with stored results to reconstruct state.

**Existing: `Agent` class** — unchanged. Continues to work for simple mode.

**Existing: `@tool` decorator** — unchanged. Tools work in both modes.

**Existing: `Norns.run()`** — detects whether it's given an `Agent` (simple) or an `@agent` function (custom) and connects accordingly.

## Implementation roadmap

### Phase 1: Custom mode protocol (server-side)

Add the ability for a worker to drive the loop instead of Norns.

1. Add `mode` field to agent schema (`:simple` default, `:custom`)
2. Add `"step_request"` / `"step_result"` message handling to WorkerChannel
3. Add custom-mode state machine to Process GenServer (awaiting_step_request → executing_step → awaiting_step_request)
4. Persist events in custom mode using the same event types (llm_request, llm_response, tool_call, tool_result)
5. Handle resume: send event log to worker on reconnect so SDK can replay

**No changes to**: events, runs, checkpointing, UI, API, nornsctl.

### Phase 2: SDK primitives

Implement `ctx.*` in the Python SDK.

1. `@agent` decorator that wraps an async function
2. `AgentContext` class with `llm_call()`, `tool_call()`, `parallel()`, `wait()`, `checkpoint()`
3. Replay engine: on resume, replay function with stored results from event log
4. `norns.run()` dispatch: detect Agent vs @agent, connect with appropriate mode

### Phase 3: Signals and human-in-the-loop

1. Add signal storage to Norns (signals table or event type)
2. `ctx.wait_for_signal()` — pauses the @agent function, resumes on signal
3. API endpoint: `POST /api/v1/runs/:id/signal` — deliver a signal to a waiting run
4. UI: show waiting state, allow sending signals from dashboard

### Phase 4: Elixir SDK parity

Port the `@agent` / `ctx.*` API to the Elixir SDK.

### Phase 5: Default workflows as library

Package the built-in loop as a reusable `@agent` function in the SDK:

```python
from norns.workflows import standard_loop

# These become equivalent:
agent = Agent(name="bot", model="claude-sonnet-4-20250514", tools=[search])
agent = standard_loop(name="bot", model="claude-sonnet-4-20250514", tools=[search])
```

This makes simple mode a special case of custom mode, not a separate code path.

## Open questions

- **Determinism enforcement**: How strict? Temporal is very strict (fails on non-determinism). We could start lenient and tighten over time.
- **Parallel LLM calls**: Should `ctx.parallel()` support multiple LLM calls, or just tools? Multiple LLM calls in parallel is useful for multi-persona patterns.
- **Streaming**: How do streaming LLM responses work in custom mode? The worker needs chunks as they arrive.
- **Timeout policy**: Per-step timeouts, or per-run? Both?
- **Event log size**: Long workflows generate lots of events. Do we need continue-as-new (Temporal pattern) or is BEAM memory management sufficient?
- **Testing**: How do developers test `@agent` functions locally without a Norns server? Mock ctx? In-memory executor?
