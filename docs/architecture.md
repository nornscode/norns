# Architecture

## Product Vision

Norns is a chat-based builder for AI-enabled workflows. The core loop:

1. User describes a workflow in natural language via chat
2. A builder LLM generates a workflow module — real Elixir code with loops, conditionals, integrations
3. The workflow engine executes it, logging every step
4. Some workflow steps are deterministic (HTTP calls, shell commands, data transforms); some call an LLM for reasoning (summarize, classify, extract, decide)

**The product is the builder.** The engine is infrastructure. Integrations are third-party (Nango/Composio or plain HTTP) — we build none ourselves.

## Current State

The engine foundation works: define an agent → trigger a run via Oban → call the Anthropic API → store the output with a full event trail.

```
Supervisor
├── Norns.Repo (Ecto/PostgreSQL)
└── Oban (background job processor)
    └── Workers.RunAgent → Agents.Runner → LLM.complete
```

**Execution flow:**
1. Something enqueues a `RunAgent` Oban job (currently: mix task)
2. Worker looks up agent + tenant, calls `Runner.execute/3`
3. Runner creates a Run, transitions through pending → running → completed/failed
4. Each step is logged as a RunEvent (run_started, llm_response, run_completed)

**Data model:**
- `tenants` — name, slug, api_keys (Anthropic key per tenant)
- `agents` — name, purpose, system_prompt, model, model_config, status, tenant_id
- `runs` — status, trigger_type, input, state, output, agent_id, tenant_id
- `run_events` — sequence, event_type, payload, source, metadata, run_id, tenant_id

## Next: Workflow Engine (see `plan-workflow-engine.md`)

Agents get a `workflow_module` field pointing to an Elixir module that implements a `Workflow` behaviour. Workflow modules use primitives (`llm`, `http`, `shell`) that auto-log as RunEvents.

```elixir
defmodule Norns.Workflows.ReleaseNotes do
  use Norns.Workflow

  def execute(ctx) do
    commits = shell(ctx, "git log --oneline --no-merges --since='#{ctx.input["since"]}'")
    llm(ctx, "Summarize these commits into release notes:\n\n#{commits}")
  end
end
```

This is the foundation the chat builder will eventually generate code for.

## Key Design Principles

### Workflows Are Code, Not Config

Workflows are Elixir modules — real code with the full expressiveness of a programming language. Not JSON step lists, not YAML, not a visual DAG. This is what the chat builder generates.

### Control Plane vs Reasoning Plane

- **Control plane (deterministic):** the workflow code itself — conditionals, loops, data flow, error handling
- **Reasoning plane (non-deterministic):** LLM steps within the workflow — summarize, classify, extract, decide

The workflow is always deterministic in structure. LLM steps are just another action type, like HTTP or shell.

### Integrations Are Third-Party

We don't build Slack/GitHub/Gmail connectors. Options:
- Managed integration platforms (Nango, Composio) for auth + normalized APIs
- Plain HTTP for anything with a REST API
- Webhooks for inbound triggers

### Multi-Tenancy Is Structural

Every table has `tenant_id`. Agent names unique per tenant. API keys per tenant. This is enforced at the data model level, not application middleware.

## Future Direction

### Chat Builder (the product)

An LLM-powered interface that translates natural language into workflow modules. It understands:
- When to emit a deterministic step vs an LLM step
- What integrations are available and how to use them
- How to wire up triggers (schedule, webhook, event-driven)

### LLM Reflection Points

Workflows can include reflection checkpoints where the LLM reviews the execution so far and can adjust the plan. Between reflection points, execution is pure code. At reflection points, it's agentic. The details of this are still being designed.

## Process Architecture (Target)

```
Supervisor
├── Norns.Repo (Ecto/PostgreSQL)
├── Oban (scheduled jobs and triggers)
└── Phoenix.Endpoint (web layer + API)
```

GenServers and DynamicSupervisors are deferred until workflows need long-running or interactive execution.
