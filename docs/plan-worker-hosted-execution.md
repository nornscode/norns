# Plan (Deferred): Worker-Hosted Agent Execution

Status: Deferred / revisit later (scope-reset aligned)
Last updated: 2026-03-23

Reconciled with: `docs/plan-scope-reset.md`

## Why this exists

Norns currently runs agent loops in the runtime (BEAM), while workers execute tools.
A future alternative is Temporal-style execution where workers run the agent loop and Norns acts as the durable orchestration/state engine.

We want to define the contract now so we can safely evolve toward that model later.

---

## Core Principle

If agent logic runs on workers, Norns remains durable only if we enforce:

1. **Strict protocol** (runtime ↔ worker message contract)
2. **Replay contract** (crash/retry semantics and idempotency rules)

No contract = duplicate side effects, inconsistent recoveries, and non-deterministic behavior.

---

## 1) Strict Protocol (what must be specified)

Define explicit message types and lifecycle:

- `task_assigned(task_id, run_id, step, checkpoint_ref)`
- `task_started(task_id, worker_id)`
- `task_heartbeat(task_id, progress)`
- `task_result(task_id, output, side_effects, next_step)`
- `task_failed(task_id, error_type, error_data)`
- `task_ack(task_id)`

Required guarantees:

- Message delivery is idempotent
- Task completion is idempotent (cannot complete twice)
- Lease and timeout semantics are explicit
- Retry policy is explicit by error category
- One active worker lease per task at a time

---

## 2) Replay Contract (what must be deterministic)

On crash/restart/retry:

- Runtime event history is source of truth
- Worker restores from checkpoint + event stream
- Worker must not re-run side effects already committed in history
- Side-effectful operations use idempotency keys
- Replayed steps consume recorded outputs where available

For LLM/tool calls:

- If a call result is persisted, replay must reuse it
- If not persisted, call may execute once and then persist with idempotency key

---

## Target Architecture (future mode)

### Hosted mode (current)
- Norns runtime executes agent loop
- Workers execute tools

### Worker-hosted mode (future)
- Worker executes agent loop
- Norns orchestrates durability: history, leases, retries, checkpoints, state transitions

Proposed toggle:

- `execution_mode: :hosted | :worker_hosted`

---

## Recommended Path

1. **Spec first**: write protocol + replay RFC
2. **Enforce contract in hosted mode** first
3. **Add worker-hosted mode** behind feature flag
4. **Prove with failure-injection tests** (crash, duplicate delivery, network partition)

---

## Deferred Deliverables (when resumed)

- `docs/rfc-worker-protocol.md`
- `docs/rfc-replay-contract.md`
- Conformance test suite for protocol/replay
- Feature-flagged worker-hosted execution pilot

---

## Success Criteria (future)

Worker-hosted execution is considered viable only when:

- No duplicate side effects under retry/crash tests
- Runs recover deterministically from persisted history
- Task lifecycle remains correct under disconnect/reconnect
- Observability remains clear at run/event level
