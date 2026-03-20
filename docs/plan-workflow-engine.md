# Plan: Workflow Engine

**Status: NOT STARTED**

## Context

The thin slice works: trigger → single LLM call → output. But an "agent" that makes one API call isn't an agent — it's a function. The next step is a workflow engine that can execute multi-step workflows, where each step is either deterministic (HTTP call, shell command, data transform) or LLM-based (summarize, classify, extract).

This engine is the foundation that the chat builder will eventually generate code for. We need to understand what generated workflows look like by hand-writing a few first.

## Product Direction

- **The product is the chat-based workflow builder**, not the engine
- **Integrations are third-party** — use Nango/Composio or plain HTTP, build nothing ourselves
- **Workflows are Elixir modules** — real code with loops/conditionals, not JSON config
- **LLM steps are just another action type** — the builder decides when to emit them
- **The engine ships first**, chat builder comes later once we know what good workflows look like

## What To Build

### 1. Workflow Behaviour

`lib/norns/workflow.ex`

A behaviour that workflow modules implement, plus macros for step primitives.

```elixir
defmodule Norns.Workflow do
  @callback execute(context :: map()) :: {:ok, any()} | {:error, any()}
end
```

When you `use Norns.Workflow`, you get helper functions that wrap each action in event logging:

- `llm(ctx, prompt)` — call the LLM, log the request/response as a RunEvent
- `http(ctx, method, url, opts)` — make an HTTP request, log it
- `shell(ctx, command)` — run a shell command, log it
- `transform(ctx, name, func)` — run an arbitrary function, log input/output

Every primitive logs a RunEvent with the step type, input, output, and timing. This is the audit trail — you can look at any run and see exactly what happened at each step.

### 2. Workflow-Aware Runner

Update `Norns.Agents.Runner` to:

- Look up the agent's workflow module
- Call `WorkflowModule.execute(context)` instead of making a single LLM call
- The context contains: agent, tenant, input, run, and a way to log events
- Fall back to the current single-LLM-call behavior if no workflow module is set

### 3. Agent Schema Change

Add `workflow_module` (string) to agents. This is the module name that implements the workflow (e.g. `"Norns.Workflows.ReleaseNotes"`). Nullable — agents without a workflow module use the legacy single-prompt path.

Migration: add column, no data backfill needed.

### 4. Two Concrete Workflows

**a) Release Notes Generator** — refactor from mix task

```elixir
defmodule Norns.Workflows.ReleaseNotes do
  use Norns.Workflow

  def execute(ctx) do
    since = ctx.input["since"] || "7 days ago"
    commits = shell(ctx, "git log --oneline --no-merges --since='#{since}'")

    case commits do
      "" -> {:ok, "No commits found."}
      _  -> llm(ctx, "Summarize these commits into user-facing release notes grouped by category. Output markdown.\n\n#{commits}")
    end
  end
end
```

The mix task becomes a thin wrapper that creates the agent (with `workflow_module: "Norns.Workflows.ReleaseNotes"`) and enqueues the job.

**b) URL Summarizer** — proves HTTP step works

```elixir
defmodule Norns.Workflows.UrlSummarizer do
  use Norns.Workflow

  def execute(ctx) do
    url = ctx.input["url"]
    body = http(ctx, :get, url).body

    llm(ctx, "Summarize the following web page content concisely:\n\n#{body}")
  end
end
```

Simple, but it exercises the HTTP primitive and shows a two-step workflow.

### 5. POST Endpoint to Trigger Runs

`POST /api/v1/runs`

```json
{
  "agent": "release-notes-generator",
  "input": {"since": "7 days ago"}
}
```

Returns:
```json
{
  "run_id": 42,
  "status": "pending"
}
```

Looks up the agent by name (scoped to tenant — tenant determined by API key in header for now), enqueues an Oban job. Minimal Phoenix controller, one route, JSON in/out.

This also means wiring up the Phoenix endpoint, router, and a basic API auth plug (just checking an API key header against the tenant's keys).

## Files to Create/Modify

| File | Action |
|------|--------|
| `lib/norns/workflow.ex` | NEW — behaviour + step primitives |
| `lib/norns/workflows/release_notes.ex` | NEW — release notes workflow |
| `lib/norns/workflows/url_summarizer.ex` | NEW — URL summarizer workflow |
| `lib/norns/agents/runner.ex` | MODIFY — dispatch to workflow module |
| `lib/norns/agents/agent.ex` | MODIFY — add workflow_module field |
| `priv/repo/migrations/NEW` | Migration: add workflow_module to agents |
| `lib/mix/tasks/gen_release_notes.ex` | MODIFY — use workflow-based agent |
| `lib/norns_web/endpoint.ex` | NEW — Phoenix endpoint |
| `lib/norns_web/router.ex` | NEW — API routes |
| `lib/norns_web/controllers/run_controller.ex` | NEW — POST /api/v1/runs |
| `lib/norns_web/plugs/api_auth.ex` | NEW — API key auth |
| `config/dev.exs` | MODIFY — add endpoint config |
| `test/norns/workflow_test.exs` | NEW — workflow primitive tests |
| `test/norns/workflows/release_notes_test.exs` | NEW |
| `test/norns_web/controllers/run_controller_test.exs` | NEW |

## What We're NOT Building

- Chat builder (needs the engine first)
- Integration connectors (use HTTP for everything)
- Reflection/adjustment loop (future — needs more workflow examples first)
- Workflow code generation (the chat builder's job, not the engine's)
- Streaming responses
- Async/parallel steps within a workflow

## Verification

1. `docker compose run --rm app mix test` — all tests pass
2. `docker compose run --rm app mix gen_release_notes --since "30 days ago"` — still works, now via workflow module
3. `curl -X POST localhost:4000/api/v1/runs -H "x-api-key: ..." -d '{"agent": "release-notes-generator", "input": {"since": "7 days ago"}}'` — returns run_id, run completes
4. Check DB: run has events for each workflow step (shell, llm) with inputs/outputs logged
