# Norns

Durable agent runtime on BEAM. Open source (MIT).

Norns runs LLM-powered agents that survive crashes, restarts, and infrastructure failures. Every LLM call and tool execution is checkpointed. Kill the process mid-task, restart it, and the agent picks up where it left off without re-executing a single step.

Think Temporal, but purpose-built for AI agents and running on the Erlang VM.

## Why BEAM

Every other durable agent runtime (Temporal, Restate, Inngest, Cloudflare, Vercel) is built on Go, Rust, JS, or JVM. BEAM gives us:

- **OTP supervisors** — native durable process managers. "Let it crash" is the original durable execution philosophy.
- **Lightweight processes** — thousands of concurrent agents per node, each with isolated state.
- **GenServers** — a natural primitive for stateful, long-lived agent processes.
- **Built-in distribution** — agent migration across nodes and free clustering (future).
- **Hot code reloading** — update agent logic without stopping running agents.

## Quickstart

```bash
# Clone and start
git clone https://github.com/amackera/norns.git
cd norns
docker compose up -d

# Create database and run migrations
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.create
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.migrate

# Start the web UI
docker compose run --rm -e POSTGRES_HOST=db -p 4000:4000 app mix phx.server
```

Open `http://localhost:4000` — you'll be guided through creating your first tenant and API key.

### Demos

```bash
# Durability demo: crash an agent mid-task, watch it recover (no API key needed)
docker compose run --rm -e POSTGRES_HOST=db app mix demo.durability

# Live agent: real LLM + real tool calls (requires ANTHROPIC_API_KEY in .env)
docker compose run --rm -e POSTGRES_HOST=db app mix demo.agent "What are the main features of Elixir 1.18?"
```

The durability demo creates an agent, sends it a multi-step research query, kills the process mid-task, then resumes from the event log and completes:

```
>> Agent is working (LLM → tool call → LLM → tool call)...
   Events logged before crash: 10

>> Simulating crash — killing the agent process...
   Run status in database: running
   Agent process alive? false

>> Resuming agent from event log...
>> Agent completed after recovery!

   Summary: 4 LLM calls, 3 tool calls, 19 total events
   The agent survived a crash and completed without losing any work.
```

## How It Works

The orchestrator is a pure state machine. It never executes LLM calls or tools directly — it dispatches tasks to workers and persists the results as an event log.

```
Orchestrator (state machine)              Worker (executes things)
  │                                           │
  │  dispatch llm_task ─────────────────────► │  calls Anthropic API
  │  ◄── llm_response ──────────────────────  │
  │  log event, dispatch tool_task ─────────► │  executes tool
  │  ◄── tool_result ───────────────────────  │
  │  log event, checkpoint, repeat            │
```

State is persisted to Postgres as an append-only event log. On crash, the process replays events from the last checkpoint rather than re-executing LLM calls. A built-in `DefaultWorker` handles everything locally for self-hosted mode — no configuration needed.

### Agent Modes

Agents run in one of two modes:

- **Task mode** (default) — each message starts a fresh run. No memory between runs. Good for one-shot queries.
- **Conversation mode** — messages append to a persistent conversation. The agent maintains context across interactions, like a chat. Good for bots and ongoing interactions.

```elixir
%Norns.Agents.AgentDef{
  model: "claude-sonnet-4-20250514",
  system_prompt: "You are a research assistant.",
  mode: :conversation,               # :task | :conversation
  context_strategy: :sliding_window,  # keeps last N messages
  context_window: 20,
  tools: [Norns.Tools.Http.__tool__(), Norns.Tools.WebSearch.__tool__()],
  checkpoint_policy: :on_tool_call,
  max_steps: 50,
  on_failure: :retry_last_step
}
```

Conversation mode supports multiple concurrent conversations per agent — each identified by a key (e.g., a Slack channel ID). A product expert bot tagged in #engineering, #support, and a DM simultaneously maintains separate context for each.

### Defining Tools

Tools implement a simple behaviour:

```elixir
defmodule MyTools.LookupCustomer do
  use Norns.Tools.Behaviour

  def name, do: "lookup_customer"
  def description, do: "Look up a customer by email"
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "email" => %{"type" => "string", "description" => "Customer email"}
      },
      "required" => ["email"]
    }
  end

  def execute(%{"email" => email}) do
    case MyApp.Customers.find_by_email(email) do
      nil -> {:error, "Customer not found"}
      customer -> {:ok, "Found: #{customer.name} (#{customer.plan})"}
    end
  end
end
```

### Built-in Tools

- **`web_search`** — search via DuckDuckGo (real results, no API key needed)
- **`http_request`** — GET/POST requests via Req (HTML stripped to text)
- **`shell`** — execute allowlisted shell commands
- **`ask_user`** — pause the agent and wait for human input (interrupt/resume)
- **`store_memory`** — save a fact to persistent memory (shared across all conversations)
- **`search_memory`** — search agent memory by keyword

### Agent Memory

Agents have persistent memory shared across all conversations. When the agent learns something in one conversation, it can recall it in another.

```
#engineering: "We shipped dark mode today for pro users"
→ Agent calls store_memory(key: "dark-mode-launch", content: "...")

#product (different conversation, hours later): "What launched recently?"
→ Agent calls search_memory(query: "launched")
→ Answers using knowledge from #engineering
```

## Web Dashboard

LiveView dashboard at `http://localhost:4000`:

- **Agents list** — status badges, start/stop, create new agents
- **Agent detail** — system prompt, controls, message input, live event stream, run history
- **Run detail** — full event timeline with color-coded events and payloads
- **Tools** — built-in and worker-provided tools

First visit redirects to `/setup` to create a tenant and generate an API key.

## REST API

Authenticate with `Authorization: Bearer <token>` matching a tenant's API key.

```
POST   /api/v1/agents                         Create agent
GET    /api/v1/agents                         List agents
GET    /api/v1/agents/:id                     Show agent
POST   /api/v1/agents/:id/start              Start agent process
DELETE /api/v1/agents/:id/stop               Stop agent process
GET    /api/v1/agents/:id/status             Get process state
POST   /api/v1/agents/:id/messages           Send message (with optional conversation_key)
GET    /api/v1/agents/:id/runs               List runs
GET    /api/v1/agents/:id/conversations      List conversations
GET    /api/v1/agents/:id/conversations/:key Show conversation
DELETE /api/v1/agents/:id/conversations/:key Delete conversation
GET    /api/v1/runs/:id                      Show run
GET    /api/v1/runs/:id/events               Get event log
```

### Example: Conversational Agent via API

```bash
# Create a conversation-mode agent
curl -X POST http://localhost:4000/api/v1/agents \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "support-bot", "system_prompt": "You are a helpful support agent.", "status": "idle", "model_config": {"mode": "conversation"}}'

# Send a message (auto-starts the agent)
curl -X POST http://localhost:4000/api/v1/agents/1/messages \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"content": "I can not log in", "conversation_key": "slack:U01ABC"}'

# View the conversation
curl http://localhost:4000/api/v1/agents/1/conversations/slack:U01ABC \
  -H "Authorization: Bearer $API_KEY"
```

## WebSocket Streaming

Connect to `/socket` to receive real-time agent events:

```
Topic: "agent:<agent_id>"
Events: llm_response, tool_call, tool_result, waiting, completed, error
```

Send messages via the channel with `{"event": "send_message", "payload": {"content": "..."}}`.

## Worker Protocol

The orchestrator never executes anything — all work (LLM calls and tool execution) is dispatched to workers. Workers connect via persistent WebSocket, register their capabilities and tools, and receive task pushes.

```
Norns Orchestrator                    Worker
  │  (pure state machine)                │  (executes things)
  │                                      │  connects to /worker
  │  dispatches llm_task ──────────────► │  calls LLM API
  │  ◄── llm_response ─────────────────  │
  │  dispatches tool_task ─────────────► │  executes tool
  │  ◄── tool_result ──────────────────  │  returns result
  │  logs events, checkpoints            │
```

A built-in `DefaultWorker` ships with Norns and handles LLM calls + built-in tools locally (same BEAM VM, no network hop). For production, you run your own workers with your own tools and API keys — Norns never sees them.

If a worker disconnects, pending tasks are queued and flushed when it reconnects.

## Running Tests

```bash
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Architecture

```
Norns.Supervisor
├── Norns.Repo (PostgreSQL)
├── Oban (background jobs)
├── Phoenix.PubSub
├── Registry (agent process lookup by {tenant, agent, conversation_key})
├── DynamicSupervisor
│   ├── [Agents.Process] — state machine per agent conversation
│   └── DefaultWorker — handles LLM calls + built-in tools locally
├── WorkerRegistry — tracks connected workers and capabilities
├── TaskQueue — holds tasks for disconnected workers
└── NornsWeb.Endpoint
    ├── REST API (/api/v1)
    ├── Agent WebSocket (/socket)
    ├── Worker WebSocket (/worker)
    └── LiveView Dashboard (/)
```

See [docs/architecture.md](docs/architecture.md) for the full design and [docs/decision-log.md](docs/decision-log.md) for why things are the way they are.

## Tech Stack

- **Elixir** on BEAM/OTP
- **Phoenix** (REST + Channels + LiveView)
- **PostgreSQL** via Ecto
- **Oban** for background jobs
- **Anthropic** Messages API (swappable via behaviour)

## License

MIT
