# SDK Design Plan

## Problem

Today, using Norns from a client application requires managing async plumbing:

1. POST a message to start a run (202 Accepted)
2. Open a WebSocket or poll for completion
3. If your agent has tools, run a separate worker process connected to `/worker`

For a Slack bot or simple integration, this means the user needs to understand workers, WebSockets, and the async lifecycle before they can send a single message. In sync Python, tool dispatch requires a second process.

## Design Principle

**The SDK is the worker.** The user defines tool functions and calls `agent.message()`. The SDK handles tool dispatch internally — no separate worker process, no WebSocket management, no async boilerplate.

## Target Experience

```python
import norns

agent = norns.Agent(
    name="support-bot",
    system_prompt="You help customers.",
    model="claude-sonnet-4-6",
    tools=[lookup_order, check_inventory],  # plain functions
)

# One call. Tools execute locally. Blocks until done.
response = agent.message("Where's my order #1234?")
print(response.output)
```

```typescript
import { Agent } from "@norns/sdk";

const agent = new Agent({
  name: "support-bot",
  systemPrompt: "You help customers.",
  model: "claude-sonnet-4-6",
  tools: [lookupOrder, checkInventory],
});

const response = await agent.message("Where's my order #1234?");
console.log(response.output);
```

## Architecture

```
  SDK Process (user's code)             Norns Runtime
  ┌─────────────────────────┐          ┌─────────────────────┐
  │                         │          │                     │
  │  agent.message("...")   │          │  Orchestrator       │
  │    │                    │          │    │                │
  │    ├─ POST /messages ──────────>   │    ├─ create run    │
  │    │   (sync: true)     │          │    ├─ call LLM      │
  │    │                    │          │    │                │
  │    │  ┌─ tool dispatch ─────────── │    ├─ tool_use      │
  │    │  │  (over same     │          │    │  "lookup_order" │
  │    │  │   connection)   │          │    │                │
  │    │  │                 │          │    │                │
  │    │  ├─ execute        │          │    │                │
  │    │  │  lookup_order() │          │    │                │
  │    │  │                 │          │    │                │
  │    │  └─ tool_result ──────────>   │    ├─ continue loop │
  │    │                    │          │    │                │
  │    │  <── response ────────────    │    └─ completed     │
  │    │                    │          │                     │
  │    └─ return output     │          └─────────────────────┘
  │                         │
  └─────────────────────────┘
```

The SDK opens a single WebSocket to Norns that serves as both client (send messages, receive events) and worker (receive tool tasks, return results). From the user's perspective, `agent.message()` is a blocking call that returns the final output.

## Server-Side Changes

### 1. Sync message endpoint

Add optional blocking mode to the existing messages endpoint.

```
POST /api/v1/agents/:id/messages
{
  "content": "...",
  "sync": true,
  "timeout": 30000,
  "conversation_key": "default"
}
```

When `sync: true`, the controller subscribes to PubSub for the run's completion event and holds the connection open. Returns 200 with the full response on completion, or 408 on timeout.

```json
{
  "run_id": 42,
  "status": "completed",
  "output": "Our refund policy is...",
  "conversation_key": "default"
}
```

The async 202 path remains the default for backward compatibility.

**Implementation:** In `AgentController.send_message/2`, after dispatching, subscribe to `"agent:#{agent_id}"` and `receive` the `:completed` or `:error` event with a timeout. No new GenServer needed.

### 2. Webhook callbacks

Add optional callback URL for fire-and-forget integrations.

```
POST /api/v1/agents/:id/messages
{
  "content": "...",
  "callback_url": "https://myapp.com/norns-hook"
}
```

On completion, Norns POSTs the result to the callback URL:

```json
{
  "run_id": 42,
  "agent_id": 1,
  "status": "completed",
  "output": "...",
  "conversation_key": "default"
}
```

**Implementation:** Store `callback_url` on the Run schema. Add an Oban worker that fires on run completion and delivers the webhook with retries.

### 3. Implicit agent start

Remove the need for `POST /agents/:id/start` before sending messages. The `ensure_started` logic already exists internally — just make it the default behavior so the API is: create agent, send messages.

### 4. SSE streaming

Add `GET /api/v1/runs/:id/stream` returning Server-Sent Events for real-time event streaming without WebSocket complexity. Most HTTP clients handle SSE natively.

### 5. Unified client+worker socket

Allow a single WebSocket connection to act as both client and worker. The SDK connects once and can:
- Send messages to agents
- Receive agent events (streaming)
- Receive tool tasks and return results

This is what makes `agent.message()` work as a single blocking call with local tool execution.

## SDK Design

### Connection lifecycle

```python
# On Agent() construction:
# 1. Ensure agent exists (POST /agents, ignore 409 conflict)
# 2. Open WebSocket to /socket
# 3. Join agent:{id} channel
# 4. Register local tools on the connection

# On agent.message():
# 1. Send message via channel
# 2. Enter event loop:
#    - On tool_task: execute local function, return result
#    - On completed: return output
#    - On error: raise exception
#    - On timeout: raise TimeoutError
```

### Tool registration

Tools are plain functions with type hints or decorators for schema generation:

```python
@norns.tool(description="Look up an order by ID")
def lookup_order(order_id: str) -> str:
    order = db.orders.find(order_id)
    return f"Order {order_id}: {order.status}, shipped {order.shipped_at}"
```

The SDK inspects the function signature, generates the JSON schema, and registers it with Norns on connect.

### Conversation management

```python
# Implicit conversation (uses "default" key)
agent.message("Hello")
agent.message("What did I just say?")  # has context

# Explicit conversation key
agent.message("Help me", conversation_key="slack-U12345")

# New conversation
agent.message("Start fresh", conversation_key="new-thread-abc")
```

### Async variant

```python
# For long-running tasks or streaming
async for event in agent.stream("Research quantum computing"):
    if event.type == "tool_call":
        print(f"Calling {event.name}...")
    elif event.type == "completed":
        print(event.output)
```

## User Personas

### Simple integration (90% of users)
- Slack bot, API endpoint, CLI tool
- Defines a few tool functions
- Wants `agent.message()` → string
- **SDK handles everything**

### Advanced deployment (10% of users)
- Long-lived worker pool on internal infra
- Tools need access to databases, internal APIs
- Separate worker process from the client
- **Uses the worker protocol directly**

## Implementation Order

1. **Sync message endpoint** — highest leverage, makes the simplest SDK possible
2. **Unified client+worker socket** — enables local tool execution in the SDK
3. **Python SDK** with `Agent.message()` and `@tool` decorator
4. **TypeScript SDK** with equivalent API
5. **Webhook callbacks** — for serverless integrations
6. **SSE streaming** — for HTTP-only clients

## Open Questions

- Should the sync endpoint support streaming (chunked transfer encoding) for partial results while blocking?
- Rate limiting strategy for sync mode — long-held connections consume server resources differently than async.
- Should the SDK support running without a Norns server at all (embedded mode, LLM calls local)?
- Tool timeout handling — if a local tool hangs, the SDK needs to timeout and report back.
