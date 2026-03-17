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

Agents are **AI-enabled workflows**, not prompt wrappers.

Creating an agent requires:

- **Name** — identifier for the agent
- **Purpose** — what the workflow does
- **Workflow backbone** — deterministic step graph/state machine
- **Prompt bundle** — versioned prompts used in agentic steps
- **Policy config** — gates, thresholds, escalation behavior

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

## Runtime Gate Semantics

Separate deterministic policy failures from probabilistic quality signals:

1. **Policy compliance gate (deterministic)**
   - Missing required fields, forbidden content, invalid transition, or policy violation
   - Default behavior: **hard block** until fixed or explicitly overridden

2. **Confidence/risk gate (probabilistic)**
   - Low confidence, ambiguous classification, weak evidence
   - Behavior is risk-tiered: suggest review, require review, or escalate depending on workflow risk profile

This split keeps enforcement predictable while allowing flexible risk tolerance by workflow type.

## Loop Boundaries: Pause vs Async Enrichment

When an agent needs additional context mid-run, the workflow must choose one of two explicit paths:

- **Durable pause (`awaiting_input`)**
  - Used for blocking dependencies
  - Safest and easiest to reason about
  - Increases end-to-end latency

- **Async enrichment sub-task**
  - Used for non-blocking context improvements
  - Faster end-to-end completion
  - Requires clear merge/deadline semantics

The boundary must be explicit in each workflow backbone to avoid ambiguous state transitions.

## Version Pinning and Reproducibility

Every workflow run should pin and persist immutable version references:

- `agent_version` — deterministic workflow backbone/state machine version
- `policy_version` — gate rules, thresholds, escalation config
- `prompt_bundle_version` — all prompts/templates used in agentic steps
- `model_config_version` — model/provider/runtime parameters
- `tooling_config_version` — connector and tool behavior snapshot

This enables reliable replay and post-incident analysis, and cleanly answers whether behavior changed due to workflow logic, policy, or prompt updates.

## Audit Record Requirements

For each run, store more than final output:

- Inputs and normalized context
- Intermediate decisions and classifier results
- Gate results (`block|escalate|allow`) with reason codes
- Escalations/approvals/overrides with actor + timestamp
- Final output and delivery targets
- Full replay pointer/history

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
