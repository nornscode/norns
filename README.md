<p align="center">
  <img src="images/norns-github-logo.png" alt="Norns" width="400" />
</p>

<h1 align="center">Norns</h1>

<p align="center">
  <a href="https://github.com/amackera/norns/actions/workflows/ci.yml"><img src="https://github.com/amackera/norns/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://elixir-lang.org/"><img src="https://img.shields.io/badge/elixir-1.18-purple.svg" alt="Elixir" /></a>
</p>

<p align="center">Durable agent runtime on BEAM.</p>

https://github.com/user-attachments/assets/b300b164-dc0c-44ea-a794-1de00b4f01a7

<p align="center"><sub>An agent calls <code>wait</code> (10s) then <code>say_hello</code>. The worker is killed twice mid-run. Each time, a new worker connects and the run resumes from where it left off. No state lost, no duplicate execution.</sub></p>

Norns is an open-source durable runtime for AI agents. It survives crashes and resumes from persisted state. You run workers in your own infrastructure (Python/Elixir), and Norns coordinates runs, retries, checkpoints, and event timelines. Norns never touches your API keys or data.

## Why use it

Your agent is 8 tool calls deep when the worker crashes. Without Norns, you start over from the beginning. With Norns, the next worker picks up at call 9.

Your payment tool times out and the agent retries. Without Norns, you risk charging the customer twice. With Norns, the retry is idempotent — the charge happens once.

Your agent is halfway through a 20-step research task when a deploy ships. Without Norns, in-flight runs die. With Norns, runs survive deploys and resume on the new version.

Under the hood: checkpointed progress, deterministic retries, idempotent side effects, inspectable event logs.

## How it works

Norns orchestrator is a state machine. It does not execute your business tools directly.

Workers execute tasks and return results.

```text
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

If no worker is connected, tasks queue and resume when workers reconnect.

## Core runtime concepts

- **Agent**: definition of model, system prompt, tools, and mode
- **Run**: one execution instance for a message/trigger
- **Event log**: append-only run timeline (requests, results, failures, retries)
- **Checkpoint**: durable state snapshot used for resume/replay
- **Worker**: process that executes LLM/tool tasks

## SDKs, CLI, and examples

- Python SDK: https://github.com/amackera/norns-sdk-python
- Elixir SDK: https://github.com/amackera/norns-sdk-elixir
- CLI (`nornsctl`): https://github.com/amackera/nornsctl
- Hello example: https://github.com/amackera/norns-hello-agent
- Full example app (Mimir): https://github.com/amackera/norns-mimir-agent

### Python (worker)

```python
from norns import Norns, Agent, tool
import os

@tool
def search_docs(query: str) -> str:
    return "..."

agent = Agent(
    name="support-bot",
    model="claude-sonnet-4-20250514",
    system_prompt="You are a support assistant.",
    tools=[search_docs],
    mode="conversation",
)

norns = Norns("http://localhost:4000", api_key="nrn_...")
norns.run(agent, llm_api_key=os.environ["ANTHROPIC_API_KEY"])
```

### Python (client)

```python
from norns import NornsClient

client = NornsClient("http://localhost:4000", api_key="nrn_...")
result = client.send_message("support-bot", "Where is my order?", wait=True)
print(result.output)
```

## Current status

v0.1 — runtime and core APIs are working. SDKs are published and active. Breaking changes will be documented in releases.

## What's next

- HTTP push transport for serverless tool execution
- Norns Cloud preview (hosted orchestrator)
- MCP tool integration
- Multi-node clustering via Horde

## License

MIT
