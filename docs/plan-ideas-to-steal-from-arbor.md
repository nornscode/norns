# Plan: High-ROI Ideas to Adopt from Arbor (Without Platform Bloat)

Status: Active planning (scope-reset aligned)
Last updated: 2026-03-24

## Why this doc exists

Arbor demonstrates many strong architectural patterns, but it is intentionally broad.
Norns should stay targeted: durable agent runtime, conversation continuity, and worker reliability.

This plan captures **what to adopt now** vs **what to defer/avoid**.

---

Reconciled with: `docs/plan-scope-reset.md`

## Product Principle

Adopt patterns that improve reliability, auditability, and operator clarity.
Avoid scope that turns Norns into a full agent operating system.

Norns focus remains:
1. Durable execution
2. Conversation + shared memory
3. Worker protocol reliability

---

## Best Ideas Worth Stealing

## 1) Explicit Agent Lifecycle Contract

### What to copy
- Clear, idempotent lifecycle operations: `create`, `start`, `stop`, `resume`, `destroy`
- Deterministic startup/recovery semantics

### Why it matters
- Prevents zombie process states
- Makes API and operations predictable

### Implementation (high-level)
1. Add lifecycle service module (`Norns.Agents.Lifecycle`)
2. Route controller actions through lifecycle APIs
3. Enforce idempotency for `start/stop/resume`
4. Emit lifecycle events for each transition

---

## 2) Structured Event and Error Taxonomy

### What to copy
- Standard event types with stable payload shape
- Error classes instead of raw exception dumps

### Why it matters
- Better debugging, analytics, and UI consistency
- Cleaner retry/escalation decisions

### Implementation (high-level)
1. Create event taxonomy doc + enum constants
2. Add `error_class` + `error_code` mapping in runtime
3. Ensure all failures emit structured events
4. Update tests to assert class/code consistency

---

## 3) Recovery and Health Signals

### What to copy
- Orphan run recovery + explicit health checks for runtime components

### Why it matters
- Reduces silent failures during crash/restart scenarios

### Implementation (high-level)
1. Expand `ResumeAgents` to emit recovery outcome events
2. Add periodic supervisor/registry health check worker
3. Surface health status via a minimal API endpoint

---

## 4) Tool Interface Discipline

### What to copy
- Uniform tool contract and central executor routing
- Tool discovery/registry as first-class runtime primitive

### Why it matters
- Keeps tool integration predictable
- Avoids ad hoc tool behavior drift

### Implementation (high-level)
1. Freeze `Norns.Tools.Behaviour` contract v1
2. Add tool metadata validation on registration
3. Add conformance tests for built-in tools

---

## 5) Signal Durability Pattern (Lightweight)

### What to copy
- Critical runtime events should be queryable after the fact, not only live-streamed

### Why it matters
- Enables postmortem, audit, and replay debugging

### Implementation (high-level)
1. Define critical signal set (start/stop/error/retry/tool)
2. Ensure each has durable write path to run events
3. Keep live PubSub forwarding as secondary channel

---

## 6) Test Discipline for Reliability Paths

### What to copy
- Strong automated coverage for crash/recovery/security boundaries

### Why it matters
- Durable systems fail in edge cases, not happy paths

### Implementation (high-level)
1. Add failure-injection tests (crash mid-tool, crash before checkpoint)
2. Add replay/idempotency tests for side effects
3. Keep a dedicated fast reliability suite target

---

## Defer / Avoid (for now)

These are valuable but outside Norns’ focused scope today:

- Capability/trust governance kernel
- Consensus council/governance system
- Massive built-in action catalog
- Broad multi-app platform surface
- Multi-protocol sprawl (full MCP/ACP gateway stack)

---

## Interop Positioning with Arbor

Norns should be **complementary**, not coupled.

Near-term strategy:
- No deep runtime dependency on Arbor
- Keep clean API/protocol boundaries so interop is possible later
- Revisit direct integration only after Norns core is proven

---

## 6-Week Implementation Sequence (High-Level)

Note: execute this sequence only after current `next-sprint.md` priorities are complete.

### Week 1
- Add lifecycle service + idempotent transitions
- Document event taxonomy v1

### Week 2
- Add structured error classes/codes
- Emit normalized failure events everywhere

### Week 3
- Harden orphan recovery + health signals
- Add health endpoint

### Week 4
- Freeze tool contract v1
- Add tool registration validation + conformance tests

### Week 5
- Implement durable signal subset (critical events)
- Improve timeline/query APIs for operators

### Week 6
- Add failure-injection and replay/idempotency tests
- Ship reliability-focused test target

---

## Definition of Done

This adoption plan is successful when:
- Lifecycle operations are deterministic and idempotent
- Runtime failures are classified and queryable
- Recovery paths are observable and tested
- Tool contract is stable and validated
- Norns remains focused (no broad platform sprawl)
