# Architecture

## Overview

Automaton is built as a durable agent runtime with a chat-first control surface. It is designed for reliability under load, fault-tolerant execution, and clear operational visibility across many concurrent agents.

### Design inspiration: Temporal-style runtime semantics

Automaton’s execution model is heavily inspired by Temporal’s primitives:

- **Agent run context ≈ Workflow** — durable execution context with persisted history
- **Signals** — asynchronous external input delivered to an active agent run
- **Queries** — read-only inspection of current agent state without mutating execution
- **Activities** — side-effecting integration work (API calls, notifications, external actions)
- **History + replay** — deterministic event trail for debugging, audit, and recovery

This is a semantic influence for runtime design, not a dependency claim.

## Agent Lifecycle

Agents have three states:

- **Inactive** — turned off, will not respond to triggers
- **Idle** — listening for triggers, no process running (just a database row)
- **Running** — actively doing work in a GenServer process

Idle agents consume no compute resources. When a trigger fires, the agent is hydrated from the database into a GenServer, does its work, and terminates back to idle.

## Agent Model

Creating an agent requires:

- **Name** — identifier for the agent
- **Purpose** — what the agent does
- **Prompt** — the base system prompt that drives the agent's behavior

Agents also accumulate **memory** — an append-only log of past interactions and runs that gives them context across invocations.

## Triggers

Agents can be started by:

- **Absolute date/time** — "run at 9am on March 20"
- **Elapsed time** — "run every 30 minutes" or "run 2 hours after last run"
- **External trigger** — API call or webhook
- **Another agent** — agent-to-agent invocation (with depth limits to prevent loops)

Scheduled triggers are managed by Oban. External triggers hit Phoenix endpoints that route to the target agent. Agent-to-agent triggers are direct GenServer messages with a chain depth counter.

## External Integrations

Agents can receive input from the outside world:

- **Slack** — DMs or thread mentions
- **GitHub** — comment mentions
- **Email** — inbound email processing
- **Phone** — inbound calls (Twilio)
- **Webhooks** — generic HTTP triggers

All integrations follow a common pattern: receive external event → route to agent → deliver as input. A shared `Inbound` behaviour defines the interface; each integration is a concrete implementation.

## Background Work

Oban handles:

- Scheduled agent triggers (cron-like and interval-based)
- Long-running deterministic work (API calls, data processing)
- Retry logic and failure handling

## Process Architecture

```
Supervisor
├── AgentSupervisor (DynamicSupervisor)
│   ├── Agent GenServer (running agent 1)
│   ├── Agent GenServer (running agent 2)
│   └── ...
├── Oban (scheduled jobs and triggers)
└── Phoenix.Endpoint (web layer)
```

Running agents are started under a DynamicSupervisor. They are transient — started on demand, terminated when work is complete. The supervisor restarts them if they crash mid-work.
