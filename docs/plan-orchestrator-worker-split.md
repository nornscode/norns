# Plan: Orchestrator/Worker Architecture Split

## The Shift

Norns currently does too much. The orchestrator makes LLM calls, executes tools, holds API keys, and lets users define agents in a web form. This is convenient for demos but wrong architecturally.

The correct model: **Norns is a state machine and event log. Workers do all execution. Agent definitions live in user code.**

This aligns with Temporal: you define workflows in your codebase, deploy workers, and use the dashboard to monitor. You never define a workflow in the Temporal UI.

## Architecture

```
User's Infrastructure                    Norns Orchestrator

  Worker Application                       State Machine
  ├── agent definitions                   ├── run lifecycle (pending → running → completed)
  ├── tool implementations                ├── event log (append-only, versioned)
  ├── LLM API keys                        ├── checkpoint/restore
  ├── makes LLM calls                     ├── task dispatch queue
  ├── executes tools                      ├── conversation state
  ├── database credentials                ├── agent memory
  └── connects outbound to Norns          ├── REST API (read + lifecycle)
                                          ├── WebSocket (task push + events)
                                          └── Dashboard (read-only monitoring)
```

### What the orchestrator does
- Accepts agent registrations from workers
- Manages run state machine transitions
- Persists all events (versioned, validated)
- Decides "what happens next" based on last event
- Dispatches tasks (LLM calls and tool calls) to connected workers
- Manages conversations and memory
- Serves the dashboard (read-only)
- Serves the API (run lifecycle, events, conversations)

### What the orchestrator does NOT do
- Make LLM API calls
- Execute tool handlers
- Hold LLM API keys
- Define agents
- Block on any external call

### What workers do
- Define agents (model, system prompt, tools, policies)
- Register agents with the orchestrator on connect
- Hold all secrets (API keys, DB credentials)
- Receive `llm_task` dispatches → call the LLM API → return response
- Receive `tool_task` dispatches → execute tool → return result
- Handle rate limits, retries, backoff locally
- Reconnect automatically if connection drops

## Worker Protocol (revised)

### Connection and Registration

Worker connects via WebSocket to `/worker`, authenticates with tenant API key, and registers its agents and tools:

```json
// Worker → Norns: join
{
  "worker_id": "prod-worker-1",
  "agents": [
    {
      "name": "product-expert",
      "model": "claude-sonnet-4-20250514",
      "system_prompt": "You are a product expert...",
      "mode": "conversation",
      "context_strategy": "sliding_window",
      "context_window": 20,
      "max_steps": 50,
      "on_failure": "retry_last_step",
      "tools": ["search_docs", "post_to_slack"]
    }
  ],
  "tools": [
    {"name": "search_docs", "description": "Search product docs", "input_schema": {...}},
    {"name": "post_to_slack", "description": "Post to Slack", "input_schema": {...}, "side_effect": true}
  ],
  "capabilities": ["llm"]
}
```

When a worker connects:
1. Norns creates/updates agent records from the worker's definitions
2. Norns registers the worker's tools in WorkerRegistry
3. Norns marks the worker as capable of handling LLM tasks
4. If agents have pending runs, tasks are dispatched immediately

When a worker disconnects:
1. Pending tasks are held in TaskQueue
2. Agent status updates to reflect no worker available
3. On reconnect, queued tasks flush to the worker

### Task Dispatch

All tasks go through the same dispatch path:

```json
// Norns → Worker: LLM task
{
  "type": "llm_task",
  "task_id": "uuid",
  "agent_name": "product-expert",
  "run_id": 123,
  "step": 4,
  "model": "claude-sonnet-4-20250514",
  "system_prompt": "You are a product expert...\n\nCurrent date: 2026-03-24.",
  "messages": [...],
  "tools": [{"name": "search_docs", ...}, {"name": "post_to_slack", ...}]
}

// Worker → Norns: LLM result
{
  "task_id": "uuid",
  "type": "llm_result",
  "status": "ok",
  "content": [...],
  "stop_reason": "tool_use",
  "usage": {"input_tokens": 1500, "output_tokens": 80}
}

// Norns → Worker: tool task (same as current)
{
  "type": "tool_task",
  "task_id": "uuid",
  "tool_name": "search_docs",
  "input": {"query": "pricing API"},
  "agent_name": "product-expert",
  "run_id": 123,
  "idempotency_key": "run:123:step:4:tool:call_1:name:search_docs"
}

// Worker → Norns: tool result (same as current)
{
  "task_id": "uuid",
  "type": "tool_result",
  "status": "ok",
  "result": "Found 3 pricing docs..."
}
```

### Rate Limits

Rate limits are entirely the worker's problem. When the worker gets a 429:

1. Worker queues the task locally with backoff
2. Worker retries after the delay
3. Norns sees nothing — the task just takes longer
4. If the worker gives up, it returns an error result
5. Norns logs the error and applies the agent's `on_failure` policy

The orchestrator never sees a 429. From its perspective, LLM calls take varying amounts of time.

## Agent Lifecycle

### Registration (worker connects)

```
Worker connects → registers agents + tools
Norns creates/updates agent records
Agent status: "registered" (has a worker, ready to accept messages)
```

### Execution (message arrives)

```
1. API/WebSocket: POST /agents/:name/messages {content, conversation_key}
2. Orchestrator: create run, log run_started, determine next action
3. Orchestrator: dispatch llm_task to worker
4. Worker: call LLM API, return response
5. Orchestrator: log llm_response, determine next action
6. If tool_use: dispatch tool_task to worker
7. Worker: execute tool, return result
8. Orchestrator: log tool_result, dispatch next llm_task
9. Repeat until end_turn
10. Orchestrator: log run_completed, persist conversation
```

### Crash recovery

```
1. Orchestrator restarts, finds run with status "running"
2. Loads event log, rebuilds state from last checkpoint
3. Waits for worker to reconnect
4. Dispatches the next task based on last event
```

### No worker available

```
1. Message arrives for agent with no connected worker
2. Orchestrator creates run, logs run_started
3. Attempts to dispatch llm_task — no worker
4. Task goes to queue
5. Run status stays "pending" or "waiting_for_worker"
6. When worker connects, queue flushes, run proceeds
```

## What Changes

### Orchestrator (Norns core)

**Agent Process becomes a state machine:**
- No more `LLM.chat()` calls
- No more `Executor.execute()` calls
- Dispatches tasks, receives results, logs events, transitions state
- Always responsive to `get_state`, `stop`, messages

**Agent definitions come from workers, not the DB:**
- The `agents` table stores the registration (name, config) but the source of truth is the worker's code
- Worker re-registers on every connect, updating the definition
- No "create agent" form in the UI — agents appear when workers register them

**New task states in the state machine:**
- `:awaiting_llm` — dispatched LLM task, waiting for result
- `:awaiting_tool` — dispatched tool task, waiting for result
- `:awaiting_worker` — no worker available, task queued

**LLM module removed from orchestrator:**
- `Norns.LLM` and `Norns.LLM.Anthropic` are deleted from the orchestrator
- `Norns.LLM.Fake` stays for testing (or is replaced by a test worker)

### Worker Protocol

**Expanded registration:**
- Workers register agents (not just tools)
- Workers declare `capabilities: ["llm"]` to handle LLM tasks
- Worker identity tied to the agents it defines

**New task type:**
- `llm_task` alongside existing `tool_task`
- Same dispatch/result pattern

### Dashboard

**Read-only:**
- Remove "create agent" form
- Remove "start agent" / "send message" controls (these happen via API/SDK)
- Keep: agent list, run timelines, event logs, conversation view, memory view
- Add: worker connection status, task queue depth

**Or keep minimal controls for convenience:**
- Keep "send message" for testing (dispatches via API internally)
- Remove agent creation (agents come from workers)

### SDK (Python/TypeScript)

This is now the primary interface for users:

```python
from norns import Norns, Agent, tool

norns = Norns(url="http://norns:4000", api_key="nrn_...")

@tool
def search_docs(query: str) -> str:
    return vector_db.search(query)

@tool(side_effect=True)
def post_to_slack(channel: str, message: str) -> str:
    slack.post(channel, message)
    return f"Posted to {channel}"

agent = Agent(
    name="product-expert",
    model="claude-sonnet-4-20250514",
    system_prompt="You are a product expert...",
    tools=[search_docs, post_to_slack],
    mode="conversation",
    on_failure="retry_last_step",
)

# This:
# 1. Connects to Norns via WebSocket
# 2. Registers the agent + tools
# 3. Handles llm_task dispatches (calls Anthropic with user's API key)
# 4. Handles tool_task dispatches (calls search_docs, post_to_slack)
# 5. Blocks forever (like a Temporal worker)
norns.run(agent, api_key=os.environ["ANTHROPIC_API_KEY"])
```

### Default Worker (Elixir, ships with Norns)

For the self-hosted getting-started experience:

```elixir
# config/agents.exs or similar
config :norns_worker,
  norns_url: "http://localhost:4000",
  api_key: System.get_env("NORNS_API_KEY"),
  llm_api_key: System.get_env("ANTHROPIC_API_KEY"),
  agents: [
    %{
      name: "researcher",
      model: "claude-haiku-4-5-20251001",
      system_prompt: "You are a research assistant...",
      tools: [Norns.Tools.WebSearch, Norns.Tools.Http, Norns.Tools.Shell]
    }
  ]
```

The default worker runs as a separate OTP application in the same umbrella (or same release with a different supervisor tree). `docker compose up` starts both.

## Migration Path

### Phase 1: Async LLM dispatch
- Agent process dispatches LLM calls to a local GenServer (not blocking)
- Agent is responsive while waiting
- No worker protocol changes
- Rate limiting moves to the dispatch layer

### Phase 2: LLM tasks through worker protocol
- LLM calls dispatched as `llm_task` to workers
- Workers register `capabilities: ["llm"]`
- Default worker handles LLM calls in-process
- Agent definitions still in DB (backward compat)

### Phase 3: Agent definitions from workers
- Workers register agents on connect
- Remove "create agent" from UI
- Dashboard becomes read-only monitor
- API gains `POST /agents/:name/messages` (by name, not ID)

### Phase 4: Remove local execution
- Delete `Norns.LLM.Anthropic` from orchestrator
- All LLM calls must go through workers
- All tool calls must go through workers
- Orchestrator is a pure state machine

## What NOT to Change

- Event log structure — events are the same
- Conversation model — conversations still stored in Norns
- Memory — still agent-scoped, still in Norns DB
- Checkpoint/restore — same mechanism
- Idempotency — same keys, same duplicate detection
- Multi-tenancy — same model

## Open Questions

1. **Agent naming**: currently agents have integer IDs. Workers register by name. Should we switch to name-based routing? (`POST /agents/product-expert/messages` instead of `/agents/1/messages`)

2. **Multiple workers, same agent**: can two workers register the same agent? If yes, Norns load-balances tasks. If no, second registration fails. Temporal allows multiple workers for the same task queue.

3. **Agent versioning**: when a worker updates an agent definition (new system prompt, different tools), what happens to running conversations? Probably: new runs use new definition, existing runs complete with old definition.

4. **Where does conversation context live?** Messages are in Norns DB. But the system prompt is on the worker. If the worker disconnects, Norns has the conversation but can't continue it. This is fine — it's the same as Temporal: no worker = no progress.

5. **Built-in tools**: do `web_search`, `http_request`, `shell` move to the default worker? Probably yes — they're just tools, they should run on workers like everything else.
