# Plan: Subagent Discovery/Launch Guardrails (Allowlist Model)

Last updated: 2026-03-30
Status: Proposed

## Context

During testing, `mimir-dev` was able to:
1. run `list_agents` and enumerate other agents in the same tenant
2. run `launch_agent` against another agent (e.g., `hello-bot`)

This is currently expected behavior under same-tenant orchestration, but it creates risk of accidental cross-agent coupling and noisy/unsafe behavior as environments grow.

In production, isolation will often be tenant-level (e.g., Mimir in its own tenant). Still, we should add explicit control surfaces.

---

## What we learned

- The current behavior is flexible and useful for orchestration use cases.
- The current behavior is also broad by default and should be controllable.
- We need a model that preserves flexibility while enabling safer production defaults.

---

## Design goals

1. Keep subagent orchestration possible (do not remove capability).
2. Make authorization explicit and auditable.
3. Support different defaults by environment (dev vs prod).
4. Avoid breaking current users by introducing hard restrictions without an opt-in path.

---

## Proposed authorization model

## 1) Policy mode per agent

Add subagent policy configuration in `model_config` (or equivalent agent config):

```json
{
  "subagents": {
    "mode": "open",              // open | allowlist | disabled
    "allowed_agents": ["hello-bot", "integration-test-agent"],
    "allow_list_agents": true
  }
}
```

- `open` (current behavior): may launch any same-tenant agent
- `allowlist`: may launch only named agents
- `disabled`: cannot launch subagents

`allow_list_agents` controls whether `list_agents` is exposed for this agent.

## 2) Runtime enforcement (server-side)

Enforce policy in built-in tool execution path (`launch_agent`, `list_agents`) — not prompt-level only.

Checks for `launch_agent`:
- same tenant required
- if `mode == disabled` -> deny
- if `mode == allowlist` and target not in `allowed_agents` -> deny
- if `mode == open` -> allow

Checks for `list_agents`:
- if `allow_list_agents == false` -> deny
- optional future filter: return only allowlisted agents when in `allowlist` mode

## 3) Auditable events

Add explicit events for policy decisions:
- `subagent_launch_allowed`
- `subagent_launch_denied`
- `subagent_list_allowed`
- `subagent_list_denied`

Include payload fields:
- `requesting_agent_id`
- `requesting_agent_name`
- `target_agent_name` (if applicable)
- `mode`
- `reason` (e.g., `not_allowlisted`, `disabled`, `cross_tenant`)

---

## Environment defaults

- **Dev default:** `mode=open`, `allow_list_agents=true` (preserve current flexibility)
- **Prod recommended default:** `mode=allowlist`, `allow_list_agents=false`

Later we can support global runtime defaults with per-agent override.

---

## Implementation phases

### Phase 1 — Non-breaking controls

- Add config parsing for `subagents.mode`, `allowed_agents`, `allow_list_agents`
- Implement enforcement checks in built-in tools
- Keep default behavior equivalent to current (`open`)
- Add allow/deny events
- Add tests for open/allowlist/disabled paths

### Phase 2 — Safer production posture

- Add runtime config/env to set default mode to `allowlist` in prod
- Add warning logs when `open` mode is used in prod
- Add docs and migration guidance for existing agents

### Phase 3 — UX/API polish (optional)

- Show subagent policy in agent detail UI
- Add helper endpoints/actions for updating allowlists
- Filter `list_agents` output to allowlisted set when desired

---

## Test plan

1. `open` mode can launch same-tenant agent
2. `allowlist` mode denies non-listed target
3. `allowlist` mode allows listed target
4. `disabled` mode denies launch
5. `allow_list_agents=false` denies listing
6. Deny events include reason code
7. Cross-tenant launch always denied

---

## Success criteria

- Existing dev behavior still works by default
- Production can enforce explicit allowlists without custom patches
- Every subagent permission decision is visible in the event log
