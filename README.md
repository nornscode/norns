# Norns

Durable agent runtime on BEAM. MIT licensed.

Norns is an orchestrator for LLM-powered agents. You define agents and tools in your language (Python, Elixir), and Norns handles the hard parts: crash recovery, checkpointing, retries, conversation state, and observability. Your code runs on workers, Norns coordinates.

Inspired by [Temporal](https://github.com/temporalio/temporal), built for AI agents on BEAM.

**Status:** Early. The runtime works, the Python SDK is in progress, the API is stabilizing. Not production-ready yet.

## Quickstart

```bash
git clone https://github.com/amackera/norns.git
cd norns
docker compose up -d
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.create
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.migrate
docker compose up
```

Open `http://localhost:4000` to set up a tenant. Then connect a worker — see [norns-hello-agent](https://github.com/amackera/norns-hello-agent) for a minimal example.

## How it works

The orchestrator is a pure state machine. It never calls an LLM or executes a tool — it dispatches tasks to workers and persists every step as an event. Workers do all the actual work: making LLM API calls, running your tool functions, talking to your databases. You need at least one connected worker to do anything.

```
Orchestrator                         Worker (your code)
  │                                      │
  │  llm_task ─────────────────────────► │  calls Claude/GPT/etc
  │  ◄── response ─────────────────────  │
  │                                      │
  │  tool_task ────────────────────────► │  runs your function
  │  ◄── result ───────────────────────  │
  │                                      │
  │  (checkpoint, repeat)                │
```

Workers connect via WebSocket, register their tools and LLM capability, and receive task pushes. Norns never touches your API keys or data.

### Example: Hello Agent

[norns-hello-agent](https://github.com/amackera/norns-hello-agent) is a minimal Python worker that demonstrates tool calls. It defines a `say_hello` tool and connects to Norns — a good starting point for understanding the worker model.

## SDKs

SDKs have two components: a **worker** (defines agents and tools, handles execution) and a **client** (sends messages, queries runs).

- Python SDK: https://github.com/amackera/norns-sdk-python
- Elixir SDK (early): https://github.com/amackera/norns-sdk-elixir
- Hello example app: https://github.com/amackera/norns-hello-agent
- First vertical app (Mimir): https://github.com/amackera/mimir

### Python

```python
from norns import Norns, Agent, tool

@tool
def search_docs(query: str) -> str:
    """Search product documentation."""
    return db.vector_search(query)

agent = Agent(
    name="support-bot",
    model="claude-sonnet-4-20250514",
    system_prompt="You are a customer support agent.",
    tools=[search_docs],
    mode="conversation",
)

# Worker — blocks forever, handles LLM calls and tool execution
norns = Norns("http://localhost:4000", api_key="nrn_...")
norns.run(agent, llm_api_key=os.environ["ANTHROPIC_API_KEY"])
```

```python
# Client — send messages, query results
from norns import NornsClient

client = NornsClient("http://localhost:4000", api_key="nrn_...")
result = client.send_message("support-bot", "Where's my order?", wait=True)
print(result.output)
```

See [norns-sdk-python](https://github.com/amackera/norns-sdk-python).

### Elixir

```elixir
defmodule MyTools.SearchDocs do
  use NornsSdk.Tool,
    name: "search_docs",
    description: "Search product documentation"

  def input_schema, do: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
  def execute(%{"query" => query}), do: {:ok, MyApp.Docs.search(query)}
end

agent = NornsSdk.Agent.new(
  name: "support-bot",
  system_prompt: "You are a customer support agent.",
  tools: [MyTools.SearchDocs],
  mode: :conversation
)

# Add worker to your supervision tree
children = [
  {NornsSdk.Worker, url: "http://localhost:4000", api_key: "nrn_...", agent: agent}
]
```

```elixir
# Client
client = NornsSdk.Client.new("http://localhost:4000", api_key: "nrn_...")
{:ok, result} = NornsSdk.Client.send_message(client, "support-bot", "Hello!", wait: true)
```

See [norns-sdk-elixir](https://github.com/amackera/norns-sdk-elixir).

## What you get

**Crash recovery.** Every LLM call and tool result is checkpointed. Kill the process, restart, and the agent resumes without re-executing anything.

**Conversations.** Agents can maintain context across messages, with automatic context window management. One agent can handle multiple concurrent conversations (e.g., different Slack channels).

**Observability.** Every run has a full event timeline. Failed runs include error classification, retry decisions, and the last checkpoint. There's a LiveView dashboard for browsing it all.

**Idempotent side effects.** Tools marked as side-effecting get deterministic idempotency keys. On replay, they're skipped instead of re-executed.

## REST API

```
POST   /api/v1/agents                         Create agent
GET    /api/v1/agents                         List agents
GET    /api/v1/agents/:id                     Show agent
POST   /api/v1/agents/:id/messages           Send message
GET    /api/v1/agents/:id/runs               List runs
GET    /api/v1/agents/:id/conversations      List conversations
GET    /api/v1/runs/:id                      Show run
GET    /api/v1/runs/:id/events               Event log
```

Auth via `Authorization: Bearer <token>`. Real-time events via WebSocket at `/socket`.

## Architecture

```
Norns.Supervisor
├── Repo (PostgreSQL)
├── PubSub
├── DynamicSupervisor
│   └── Agent processes (state machines)
├── WorkerRegistry (tracks connected workers)
├── TaskQueue (holds tasks for disconnected workers)
└── Phoenix Endpoint (REST, WebSocket, LiveView)
```

The runtime is Elixir on BEAM/OTP, Phoenix for the web layer, PostgreSQL for persistence. See [docs/architecture.md](docs/architecture.md) for the full picture.

## License

MIT
