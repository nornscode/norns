# Orchestration Path: Elixir-First

## Decision

Build on Elixir + Postgres + Oban. Adopt Temporal-style semantics where useful, don't depend on Temporal infrastructure.

## Current Implementation

```elixir
# Trigger a run
Automaton.Workers.RunAgent.new(%{agent_id: id, tenant_id: tid, input: text})
|> Oban.insert!()

# Execution (inside Oban worker)
Automaton.Agents.Runner.execute(agent, input, tenant)

# Query
Automaton.Runs.get_run(id)
Automaton.Runs.list_events(run_id)
```

## Next: Workflow Modules

Runner will dispatch to workflow modules — real Elixir code that uses logged primitives (`llm`, `http`, `shell`). See `plan-workflow-engine.md`.

## Control Plane vs Reasoning Plane

- **Control plane:** the workflow code — loops, conditionals, step sequencing (deterministic)
- **Reasoning plane:** LLM calls within the workflow (non-deterministic, outputs persisted as events)

## Why Elixir-First

- Faster iteration, full control over runtime and data model
- Lower operational complexity in early product phase
- OTP primitives (GenServers, supervision) available when needed

## When to Revisit

Reevaluate infrastructure if:
1. Long-running workflow complexity slows delivery
2. Retry/timer/recovery bugs become an operational burden
3. Multi-team scale requires stronger built-in guarantees
