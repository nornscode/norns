# SDK Readiness Test Plan

Last updated: 2026-03-25
Status: Gate for starting SDK initiative

## Purpose

Define objective pass/fail criteria to determine whether Norns is ready to begin a serious SDK initiative (TypeScript/Python), rather than a one-off spike.

This plan verifies that runtime contracts are stable enough for external developer-facing interfaces.

---

## Readiness Principle

Do not start full SDK rollout until protocol and execution semantics are stable.

SDKs should wrap stable contracts — not chase moving internals.

---

## Gate 1 — Worker Protocol v1 Stability

### What must be stable
- Worker registration payload
- Capability declaration (`llm`, `tools`)
- Task message shapes (`llm_task`, `tool_task`)
- Result/error message shapes
- Disconnect/reconnect behavior

### Tests
1. **Registration contract test**
   - Worker registers with valid payload -> accepted
   - Invalid payload -> deterministic validation error
2. **Task dispatch contract test**
   - Orchestrator dispatches valid `llm_task` and `tool_task`
   - Worker can parse payloads without fallback logic
3. **Result contract test**
   - Worker returns success/error results with required fields
   - Orchestrator persists normalized events correctly
4. **Reconnect test**
   - Disconnect worker with queued tasks
   - Reconnect worker and verify queue flush + task completion

### Pass criteria
- No protocol shape changes across 2 consecutive sprint cycles
- All above tests green in CI

---

## Gate 2 — Agent Definition Contract Stability

### What must be stable
- Required/optional fields in agent definition
- Default behaviors (`mode`, context strategy, checkpoint policy, failure policy)
- Backward compatibility for missing optional fields

### Tests
1. **AgentDef validation matrix**
   - Valid defs pass
   - Invalid defs fail with stable error codes
2. **Defaulting behavior test**
   - Missing optional fields resolve to documented defaults
3. **Version compatibility test**
   - Older definition payloads still load or fail with explicit migration error

### Pass criteria
- AgentDef schema documented and unchanged for one full sprint
- Validation tests green

---

## Gate 3 — Execution Semantics Reliability

### What must be stable
- Idempotent side effects
- Deterministic replay behavior
- Error taxonomy and retry policy behavior

### Tests
1. **Side-effect idempotency tests**
   - crash/retry does not duplicate side effects
2. **Replay conformance tests**
   - crash windows around side-effect persistence
   - deterministic resume action selection
3. **Failure classification tests**
   - terminal and retryable failures classified consistently

### Pass criteria
- Replay/idempotency suite green with no flaky failures over 3 consecutive CI runs

---

## Gate 4 — Tenant/Auth Boundary Stability

### What must be stable
- Worker auth model
- Tenant routing guarantees
- Secret ownership model (orchestrator vs worker)

### Tests
1. **Tenant isolation tests**
   - worker A cannot execute tasks for tenant B
2. **Auth validation tests**
   - invalid token/key rejected deterministically
3. **Secret path tests**
   - verify execution path does not unexpectedly require orchestrator-held provider key when worker mode is enabled

### Pass criteria
- Cross-tenant leakage tests green
- Auth rejection behavior stable and documented

---

## Gate 5 — Operational Observability for SDK Users

### What must be stable
- Debuggable run visibility for SDK-triggered tasks
- Failure inspector output shape

### Tests
1. **Run inspector contract test**
   - API includes: `error_class`, `error_code`, `retry_decision`, `last_checkpoint`, `last_event`
2. **Event timeline consistency test**
   - SDK-originated runs show expected event sequence

### Pass criteria
- Operator can diagnose failed SDK-originated run in <60 seconds

---

## Gate 6 — Compatibility Freeze Window

### Requirement
Before full SDK build, enforce a short freeze window for protocol contracts.

### Policy
- 2-week freeze on:
  - worker protocol payload shapes
  - AgentDef schema
  - failure inspector response shape

### Pass criteria
- No breaking changes during freeze window
- Any change requires version bump + migration note

---

## SDK Kickoff Decision

## Greenlight SDK initiative if ALL are true:
- Gate 1–5 pass
- Freeze window completed without breakage
- One thin-slice SDK spike validated (register agent + receive tasks + return results)

## Otherwise:
- Continue runtime hardening and re-run this checklist next sprint

---

## Suggested Implementation Sequence for Validation

1. Build protocol conformance tests (Gate 1)
2. Build AgentDef schema/default tests (Gate 2)
3. Harden replay/idempotency CI reliability (Gate 3)
4. Lock auth/tenant boundary tests (Gate 4)
5. Finalize failure inspector/event consistency tests (Gate 5)
6. Start freeze window (Gate 6)
7. Run thin-slice SDK spike

---

## Notes

A thin SDK spike can begin before full greenlight, but should be treated as a protocol harness.
Do not market/commit to broad SDK support until readiness gates pass.
