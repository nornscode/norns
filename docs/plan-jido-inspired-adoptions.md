# Plan: Jido-Inspired Adoptions for Norns (Focused)

Status: Active planning (scope-reset aligned)
Last updated: 2026-03-24

Reconciled with: `docs/plan-scope-reset.md`

## Purpose

Capture high-value ideas from Jido that strengthen Norns durability and runtime quality **without** expanding Norns into a broad framework platform.

Norns remains focused on:
1. Durable agent execution
2. Conversation continuity + memory
3. Reliable worker/runtime protocol

---

## What we are adopting (now)

Note: these adoptions are secondary to `docs/next-sprint.md` and should not preempt current idempotency/replay/operator priorities.

## 1) Typed Runtime Events and Directives

### Why
Norns currently emits runtime events, but event shape can drift as features expand. Jido’s typed directive model is a strong pattern for long-term consistency.

### What to implement
- Define explicit structs/types for core Norns runtime events/directive intents (v1):
  - `run_started`
  - `llm_request`
  - `llm_response`
  - `tool_call`
  - `tool_result`
  - `checkpoint_saved`
  - `run_failed`
  - `run_completed`
- Add versioned payload contract (`schema_version`) to each persisted event
- Validate event payload shape before persistence

### Deliverables
- `lib/norns/runtime/event/*.ex` (typed event structs)
- `lib/norns/runtime/event_validator.ex`
- `docs/event-taxonomy.md`

### Done when
- All core runtime events are emitted through typed constructors
- Invalid event payloads fail fast in tests

---

## 2) Error Taxonomy + Runtime Error Policy

### Why
Raw errors make retries and operator responses inconsistent. Jido’s error handling patterns suggest clear classification boundaries.

### What to implement
- Introduce error classes and stable codes:
  - `:transient` (retryable)
  - `:external_dependency`
  - `:validation`
  - `:policy`
  - `:internal`
- Add retry policy mapping by class/code
- Persist classified errors in run events and run status metadata

### Deliverables
- `lib/norns/runtime/errors.ex`
- `lib/norns/runtime/error_policy.ex`
- `docs/error-taxonomy.md`

### Done when
- Every failed run has class + code + retry decision recorded
- Retry behavior is deterministic in tests

---

## 3) Checkpoint/Restore Contract Invariants

### Why
Durability quality depends on crystal-clear restore rules. Jido’s explicit checkpoint/restore contract is worth mirroring.

### What to implement
- Define invariant spec for checkpoint + replay:
  - persisted events are source of truth
  - no duplicate side effects on replay
  - checkpoint includes minimal state needed to resume quickly
- Add conformance tests:
  - crash after tool call before completion
  - restart and verify no duplicate tool execution
  - replay reconstructs equivalent run state

### Deliverables
- `docs/checkpoint-restore-contract.md`
- test suite: `test/norns/runtime/replay_conformance_test.exs`

### Done when
- Failure-injection tests pass for crash/restart/replay paths
- Side-effect idempotency holds under retry scenarios

---

## What we are explicitly deferring

To keep Norns targeted, defer these Jido-like areas for now:

- Full plugin framework and plugin lifecycle DSL
- Broad strategy matrix (FSM/direct/custom strategy framework)
- Generic framework-level agent composition abstractions
- Full multi-agent hierarchy orchestration semantics

We may revisit after Norns runtime v1 is stable.

---

## 4-Week Execution Sequence

### Week 1
- Event taxonomy doc + typed event structs
- Runtime event validator integration

### Week 2
- Error taxonomy + policy module
- Classified error persistence

### Week 3
- Checkpoint/restore contract doc
- Add replay/idempotency conformance tests

### Week 4
- Harden edge cases found by conformance suite
- Freeze v1 contracts (events + errors + replay invariants)

---

## Success Criteria

This plan is successful when:
- Runtime events are typed, versioned, and validated
- Failures are classified with deterministic retry behavior
- Crash/restart/replay behavior is test-proven and side-effect-safe
- Norns remains product-focused, not framework-bloated
