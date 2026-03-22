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

# Run the durability demo (no API key needed)
docker compose run --rm -e POSTGRES_HOST=db app mix demo.durability
```

The demo creates an agent, sends it a multi-step research query, kills the process mid-task, then resumes from the event log and completes:

```
>> Starting agent and sending query...
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

Each agent is a GenServer that runs a loop:

```
receive message → call LLM → if tool call, execute tool → checkpoint → repeat
```

State is persisted to Postgres as an append-only event log. On crash, the process replays events from the last checkpoint rather than re-executing LLM calls.

### Agent Definition

Agents are configured with an `AgentDef`:

```elixir
%Norns.Agents.AgentDef{
  model: "claude-sonnet-4-20250514",
  system_prompt: "You are a research assistant.",
  tools: [Norns.Tools.Http.__tool__(), Norns.Tools.WebSearch.__tool__()],
  checkpoint_policy: :on_tool_call,  # :every_step | :on_tool_call | :manual
  max_steps: 50,
  on_failure: :retry_last_step       # :stop | :retry_last_step
}
```

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

- **`http_request`** — GET/POST requests via Req
- **`web_search`** — web search (stub, returns placeholder results)
- **`shell`** — execute allowlisted shell commands

## REST API

Authenticate with `Authorization: Bearer <token>` matching a tenant's API key.

```
POST   /api/v1/agents              Create agent
GET    /api/v1/agents              List agents
GET    /api/v1/agents/:id          Show agent
POST   /api/v1/agents/:id/start   Start agent process
DELETE /api/v1/agents/:id/stop    Stop agent process
GET    /api/v1/agents/:id/status  Get process state
POST   /api/v1/agents/:id/messages Send message to agent
GET    /api/v1/agents/:id/runs    List runs
GET    /api/v1/runs/:id           Show run
GET    /api/v1/runs/:id/events    Get event log
```

### Example: Run an Agent via API

```bash
# Create an agent
curl -X POST http://localhost:4000/api/v1/agents \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "researcher", "system_prompt": "You are a research assistant.", "status": "idle"}'

# Start it
curl -X POST http://localhost:4000/api/v1/agents/1/start \
  -H "Authorization: Bearer $API_KEY"

# Send a message
curl -X POST http://localhost:4000/api/v1/agents/1/messages \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"content": "Research the latest developments in Elixir"}'

# Check status
curl http://localhost:4000/api/v1/agents/1/status \
  -H "Authorization: Bearer $API_KEY"

# View the event log
curl http://localhost:4000/api/v1/runs/1/events \
  -H "Authorization: Bearer $API_KEY"
```

## WebSocket Streaming

Connect to `/socket` to receive real-time agent events:

```
Topic: "agent:<agent_id>"
Events: llm_response, tool_call, tool_result, completed, error
```

Send messages via the channel with `{"event": "send_message", "payload": {"content": "..."}}`.

## Worker Protocol

Workers connect to the runtime via persistent WebSocket, register tools, and receive task pushes. Norns never calls out to your code — workers make outbound connections only.

```
Norns Runtime                         Your Infrastructure
  │                                       │
  Agent GenServer                         Worker
  │  hits tool call                       │  connects to /worker
  │    ↓                                  │  registers tools
  │  pushes tool_task ──── WebSocket ───► │  executes locally
  │  ◄── tool_result ────────────────────  │  returns result
  │  checkpoints + continues              │
```

Workers join `"worker:lobby"` with their tool definitions. When an agent needs a remote tool, the runtime pushes a `tool_task` to the worker and waits for the `tool_result`.

If a worker disconnects, pending tasks are queued and flushed when it reconnects.

In self-hosted mode, the worker runs in the same BEAM VM — tool calls are local function calls with no network hop.

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
├── Registry (agent process lookup)
├── DynamicSupervisor
│   └── [Agents.Process] — one GenServer per running agent
├── WorkerRegistry — tracks connected workers and their tools
├── TaskQueue — holds tasks for disconnected workers
└── NornsWeb.Endpoint
    ├── REST API (/api/v1)
    ├── Agent WebSocket (/socket)
    └── Worker WebSocket (/worker)
```

See [docs/architecture.md](docs/architecture.md) for the full design and [docs/decision-log.md](docs/decision-log.md) for why things are the way they are.

## Tech Stack

- **Elixir** on BEAM/OTP
- **Phoenix** (REST + Channels)
- **PostgreSQL** via Ecto
- **Oban** for background jobs
- **Anthropic** Messages API (swappable via behaviour)

## License

MIT
