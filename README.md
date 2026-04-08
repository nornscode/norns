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

Norns is an open-source durable runtime for AI agents.

It uses an orchestrator/worker architecture: you run workers in your own infrastructure (Python/Elixir), and Norns coordinates runs, retries, checkpoints, and event timelines.

## What Norns is

- A durable **orchestrator** for agent runs
- A runtime that survives crashes and resumes from persisted state
- A control plane with REST/WebSocket APIs and operator UI

## What Norns is not

- Not a model provider
- Not a hosted black box
- Not where your business tools or LLM keys have to live

## Why use it

When agents do real work, failures happen: process crashes, network timeouts, tool errors, duplicate retries.

Norns gives you one execution model for those failures:

- checkpointed progress
- deterministic retries
- idempotent side effects
- inspectable timelines

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

- Runtime and core APIs are working
- SDKs are active and evolving
- Contracts are stabilizing
- Still early-stage; expect changes

## License

MIT
