# Norns Next Sprint Plan

Last updated: 2026-03-24
Sprint goal: Harden runtime correctness before expanding surface area.

## Priority 1 — Typed Event Taxonomy v1

### Objective
Make all core runtime events explicit, validated, and versioned.

### Scope
- Add typed event modules for core events:
  - `run_started`
  - `llm_request`
  - `llm_response`
  - `tool_call`
  - `tool_result`
  - `checkpoint_saved`
  - `run_failed`
  - `run_completed`
- Add `schema_version` field in event payload
- Add central event validator and constructor path
- Route runtime event writes through typed API only

### Acceptance Criteria
- No direct ad hoc event payload writes in runtime loop code
- Invalid event payloads fail in tests
- Existing event consumers still function with schema_version field

### Suggested files
- `lib/norns/runtime/events/*.ex`
- `lib/norns/runtime/event_validator.ex`
- `docs/event-taxonomy.md`

---

## Priority 2 — Error Taxonomy + Retry Policy

### Objective
Classify errors consistently and make retry behavior deterministic.

### Scope
- Add error classes + codes:
  - `:transient`
  - `:external_dependency`
  - `:validation`
  - `:policy`
  - `:internal`
- Add policy module mapping class/code -> retry strategy
- Persist error class/code in run failure events and status metadata

### Acceptance Criteria
- Every run failure event contains class + code + retry decision
- Retry paths are deterministic and test-covered
- No raw exception-only failure paths in core runner loop

### Suggested files
- `lib/norns/runtime/errors.ex`
- `lib/norns/runtime/error_policy.ex`
- `docs/error-taxonomy.md`

---

## Priority 3 — Replay Conformance Suite

### Objective
Prove crash/restart/replay safety and side-effect idempotency.

### Scope
- Add failure-injection tests for:
  - crash after tool call before completion
  - crash before checkpoint write
  - restart and resume from latest checkpoint/event stream
- Validate replay behavior:
  - no duplicate side effects
  - restored state equivalence
  - event sequence consistency

### Acceptance Criteria
- Conformance suite passes in Docker CI path
- At least one side-effect duplication test fails before fix and passes after fix
- Replay invariants documented in contract doc

### Suggested files
- `test/norns/runtime/replay_conformance_test.exs`
- `docs/checkpoint-restore-contract.md`

---

## Out of Scope This Sprint
- New dashboard features
- Worker-hosted execution mode
- MCP integration
- Broader plugin framework abstractions

---

## Execution Order
1. Typed event taxonomy
2. Error taxonomy + retry policy
3. Replay conformance tests

Do not invert this order; replay tests should target the finalized event/error contracts.
