# Plan: Task vs Conversation Agent Modes

## Context

Agents currently run in task mode only: receive message → run to completion → forget everything. A Slack bot, support agent, or any interactive agent needs to maintain context across multiple interactions. This plan adds a conversation mode where agents accumulate context across runs.

A single agent may handle multiple concurrent conversations. A product expert bot tagged in #engineering, #support, and a DM simultaneously needs separate context for each. Conversations are identified by an external key (e.g., Slack channel ID, user ID, session token) so the caller controls the grouping.

## What changes

**New concept: Conversation.** A conversation is a persistent message history scoped to an agent + external key. Multiple runs happen within one conversation. Each run adds to the conversation history. Between runs, the history is persisted to Postgres.

**Agent modes:**
- `:task` (default, current behavior) — each `send_message` starts fresh. Messages reset after completion. Runs are independent.
- `:conversation` — each `send_message` targets a conversation (identified by key). The LLM sees full history from previous runs in that conversation. Context persists across process restarts.

## Data model

### New table: `conversations`

```
conversations
  id              bigint PK
  agent_id        bigint FK NOT NULL
  tenant_id       bigint FK NOT NULL
  key             text NOT NULL         — external identifier (channel ID, user ID, session, etc.)
  messages        jsonb NOT NULL DEFAULT '[]'
  summary         text                  — compressed summary of older messages
  message_count   integer DEFAULT 0
  token_estimate  integer DEFAULT 0
  inserted_at     utc_datetime_usec
  updated_at      utc_datetime_usec

  unique index: [agent_id, key]
```

The `key` is caller-provided. Examples:
- Slack: `"slack:C04ABCDEF"` (channel ID) or `"slack:U01ABCDEF"` (DM user ID)
- Web chat: `"session:abc123"`
- API: any string the caller chooses
- Default: `"default"` if no key provided

This supports multiple concurrent conversations per agent — one per unique key.

### Schema changes

- `runs`: add `conversation_id` (nullable FK). Task-mode runs have no conversation. Conversation-mode runs link to one.
- `AgentDef`: add `mode: :task | :conversation`. Read from `model_config["mode"]` with default `:task`.

## Process model

### One process per agent vs one per conversation

Currently there's one GenServer process per agent, registered as `{tenant_id, agent_id}`. With multiple conversations, two options:

**Option A: One process per agent, handles all conversations sequentially.** The process receives messages with a conversation key, loads the right conversation, runs to completion, then handles the next. Simple but serialized — if two channels message simultaneously, one waits.

**Option B: One process per conversation.** Registry key becomes `{tenant_id, agent_id, conversation_key}`. Each conversation runs independently. Parallel handling, but more processes.

**Recommendation: Option B.** Agents are cheap (one GenServer each). A Slack bot in 10 channels spawns 10 processes — trivial for BEAM. No serialization bottleneck. Each conversation is fully independent.

Registry key: `{tenant_id, agent_id, conversation_key}`
- Task mode: key is `"task:#{run_id}"` (unique per run, no reuse)
- Conversation mode: key is the caller-provided conversation key

### API changes for send_message

`send_message` gains an optional `conversation_key` parameter:

```
POST /api/v1/agents/:id/messages
{
  "content": "What does the pricing API return?",
  "conversation_key": "slack:C04ABCDEF"
}
```

If `conversation_key` is omitted:
- Task mode: creates a one-off run (current behavior)
- Conversation mode: uses `"default"` as the key

The system finds or creates the conversation, finds or spawns the process for that conversation, and delivers the message.

### Registry changes

`Agents.Registry` API evolves:

```elixir
# Task mode (current)
start_agent(agent_id, tenant_id, opts)

# Conversation mode
start_conversation(agent_id, tenant_id, conversation_key, opts)

# Unified send — routes to the right process
send_message(tenant_id, agent_id, content, opts \\ [])
  # opts: [conversation_key: "slack:C04ABCDEF"]
```

## Context management

When the conversation gets long, old messages need to be compressed. Two strategies, configured on AgentDef:

- `:sliding_window` (default) — keep last N messages (default N=20), discard older ones
- `:none` — keep everything (for short-lived conversations)

Future: `:summarize` — when messages exceed threshold, ask the LLM to summarize older messages into a paragraph, store in `conversations.summary`, drop the originals. Not in scope for initial build.

The summary (if present) is prepended as a system-level context block:

```
System prompt: "You are a product expert..."

[If summary exists]
"Summary of earlier conversation: {summary}"

[Recent messages]
user: "What does the pricing API return?"
assistant: "The pricing API returns..."
user: "What about error codes?"
```

## Process changes

### `init/1`

- If mode is `:conversation`, load (or create) the conversation record using `agent_id` + `conversation_key`
- Populate `state.messages` from `conversation.messages`
- Store `conversation` in state

### `handle_cast({:send_message, content}, %{status: :idle})`

- Task mode: current behavior (create run, start fresh)
- Conversation mode: append message to existing history, create a new run linked to the conversation, enter LLM loop

### `complete_successfully/2`

- Task mode: current behavior (status → idle)
- Conversation mode: persist updated messages to the conversation record, status → idle, messages stay for next interaction

### `rebuild_state/2` (crash recovery)

- Task mode: current behavior (replay from events)
- Conversation mode: load conversation from DB first, then replay run events on top

## Agent lifecycle in conversation mode

```
First message to conversation "slack:C04ABCDEF":
  1. Spawn process for {agent_id, "slack:C04ABCDEF"}
  2. Create conversation record (empty messages)
  3. Append user message
  4. Create run (linked to conversation)
  5. LLM loop → tool calls → completion
  6. Persist messages to conversation
  7. Process stays alive, idle

Second message to same conversation:
  1. Process already exists, receives message
  2. Apply context strategy (maybe compact old messages)
  3. Append new user message
  4. Create new run (linked to same conversation)
  5. LLM loop (sees full history) → completion
  6. Persist updated messages to conversation
  7. Process idle

Meanwhile, message to "slack:U01ABCDEF" (different conversation):
  1. Spawn separate process for {agent_id, "slack:U01ABCDEF"}
  2. Independent conversation, independent context
  3. Runs in parallel with no contention

After crash:
  1. Orphan recovery finds run with status "running"
  2. Load conversation from DB (persisted after last completed run)
  3. Replay events from current run on top
  4. Resume in the right conversation context
```

## Agent Memory (cross-conversation knowledge)

### The problem

Conversations are siloed. What the agent learns in #engineering stays in #engineering's conversation history. If the team in #engineering tells the product expert "we shipped dark mode today," the team in #product asking "what launched recently?" gets nothing — their conversation has no context about it.

Conversation history is "what was said in this thread." Memory is "what the agent knows." Memory is shared across all conversations for an agent.

### Data model

```
memories
  id          bigint PK
  agent_id    bigint FK NOT NULL
  tenant_id   bigint FK NOT NULL
  key         text NOT NULL           — human-readable identifier
  content     text NOT NULL           — the knowledge
  metadata    jsonb DEFAULT '{}'      — optional tags, source, etc.
  inserted_at utc_datetime_usec
  updated_at  utc_datetime_usec

  unique index: [agent_id, key]
```

Scoped to agent — all conversations for that agent share the same memory pool.

### Tools

Two new built-in tools:

**`store_memory`** — the agent decides something is worth remembering.

```
Input:  {key: "dark-mode-launch", content: "Dark mode shipped 2026-03-22, available to all users"}
Effect: upsert into memories table
Output: "Stored memory: dark-mode-launch"
```

**`search_memory`** — the agent looks up what it knows before answering.

```
Input:  {query: "recent launches"}
Effect: search memories by keyword match on key + content
Output: "Found 2 memories:\n1. dark-mode-launch: Dark mode shipped 2026-03-22...\n2. api-v2-release: API v2 released..."
```

Search uses Postgres `ILIKE` on key + content to start. Full-text search via `tsvector` or vector search via pgvector are future upgrades.

### Why tools, not automatic

The agent decides what's worth remembering — not everything in every conversation should be stored. "Can you check the pricing page?" isn't memory-worthy. "We're deprecating the v1 API on April 1st" is. The LLM is good at this judgment.

The system prompt tells the agent how to use memory:

```
You have a persistent memory shared across all your conversations.
Use store_memory to remember important facts, decisions, and events.
Use search_memory to recall what you know before answering questions.
```

### Example flow

```
#engineering channel:
  User: "@product-expert we shipped dark mode today, it's available to all pro users"
  Agent: [calls store_memory(key: "dark-mode-launch", content: "Dark mode shipped 2026-03-22, available to all pro plan users")]
  Agent: "Got it — I've noted that dark mode launched today for pro users."

#product channel (different conversation, hours later):
  User: "@product-expert what features launched this week?"
  Agent: [calls search_memory(query: "launched this week")]
  Agent: "Based on what I know, dark mode shipped on March 22nd. It's available to all pro plan users."
```

### Memory in the UI

- Agent detail page shows a "Memory" section: list of stored memories (key, content, timestamp)
- Ability to view and delete individual memories
- Memory count displayed alongside conversation count

### Files for memory

| File | Purpose |
|------|---------|
| `lib/norns/memories.ex` | Memory context (CRUD, search) |
| `lib/norns/memories/memory.ex` | Schema |
| `lib/norns/tools/store_memory.ex` | store_memory tool |
| `lib/norns/tools/search_memory.ex` | search_memory tool |
| `priv/repo/migrations/..._create_memories.exs` | Migration |
| `test/norns/memories_test.exs` | Memory CRUD + search tests |

### Future: vector memory

Replace keyword search with semantic search:
- Compute embeddings on `store_memory` (via LLM embedding API)
- Store in pgvector column on memories table
- `search_memory` does cosine similarity search
- Much better recall for fuzzy queries like "what do we know about pricing"

Not in scope for initial build — keyword search is good enough to prove the pattern.

## AgentDef additions

```elixir
%AgentDef{
  mode: :task,                          # :task | :conversation
  context_strategy: :sliding_window,    # :sliding_window | :none
  context_window: 20,                   # max messages to keep
}
```

Read from `model_config`:

```json
{
  "mode": "conversation",
  "context_strategy": "sliding_window",
  "context_window": 20
}
```

## API changes

### REST

- `POST /api/v1/agents/:id/messages` — gains optional `conversation_key` field
- `GET /api/v1/agents/:id/conversations` — list conversations for an agent
- `GET /api/v1/conversations/:id` — view conversation (messages, summary, token estimate)
- `DELETE /api/v1/conversations/:id` — reset/delete a conversation

### UI

- Agent detail page shows mode (task/conversation)
- For conversation-mode agents: list of active conversations with message counts
- Click conversation → view its history and runs
- "Reset conversation" button per conversation

## Files to create

| File | Purpose |
|------|---------|
| `lib/norns/conversations.ex` | Conversation context (CRUD, find_or_create) |
| `lib/norns/conversations/conversation.ex` | Schema |
| `lib/norns/conversations/context.ex` | Context management strategies |
| `lib/norns/memories.ex` | Memory context (CRUD, search) |
| `lib/norns/memories/memory.ex` | Schema |
| `lib/norns/tools/store_memory.ex` | store_memory tool |
| `lib/norns/tools/search_memory.ex` | search_memory tool |
| `priv/repo/migrations/..._create_conversations.exs` | Migration (conversations table) |
| `priv/repo/migrations/..._create_memories.exs` | Migration (memories table) |
| `test/norns/conversations_test.exs` | Conversation CRUD tests |
| `test/norns/conversations/context_test.exs` | Context strategy tests |
| `test/norns/memories_test.exs` | Memory CRUD + search tests |
| `test/norns/agents/process_conversation_test.exs` | Conversation mode process tests |

## Files to modify

| File | Change |
|------|--------|
| `lib/norns/agents/agent_def.ex` | Add `mode`, `context_strategy`, `context_window` |
| `lib/norns/agents/process.ex` | Conversation loading, persistence, mode branching |
| `lib/norns/agents/registry.ex` | Conversation-aware process lookup and spawning |
| `lib/norns/runs/run.ex` | Add `conversation_id` field |
| `lib/norns/application.ex` | Register memory tools |
| `lib/norns_web/live/agent_live.ex` | Show conversations, memory, mode indicator |
| `lib/norns_web/controllers/agent_controller.ex` | Conversation key in send_message, conversation + memory endpoints |
| `lib/norns_web/router.ex` | New routes |

## Implementation order

1. Migration: conversations + memories tables, conversation_id on runs
2. Conversation schema + context module (CRUD, find_or_create by agent_id + key)
3. Memory schema + context module (CRUD, keyword search)
4. Context management (sliding_window)
5. Memory tools (store_memory, search_memory) + register on boot
6. AgentDef additions (mode, context_strategy, context_window)
7. Registry changes (conversation-aware lookup/spawn)
8. Process changes (conversation loading, persistence, mode branching)
9. Tests
10. API endpoints + UI

## What NOT to build

- Summarization context strategy (sliding window covers the launch case)
- Vector memory / embeddings (keyword search is good enough to start)
- Conversation forking or branching
- Conversation export/import
- Per-message token counting (estimate from message count is fine)
- Conversation TTL / auto-expiry (add later if needed)
