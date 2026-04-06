# Lessons from Absurd in Production → Norns Next Steps

Last updated: 2026-04-06
Status: Active guidance

## Why this doc

Absurd’s production write-up highlights the practical realities of durable execution at runtime scale.
This document translates those lessons into concrete priorities for Norns.

---

## Key lessons

## 1) Reliability work is mostly edge-case hardening

What held Absurd back in production was not the basic model, but edge conditions:
- lease/claim handling
- deadlocks and lock ordering
- race conditions around events and retries
- watchdog behavior for broken workers

### Norns action
- Keep expanding failure-injection tests around worker disconnect/reconnect, task claims, and resume windows.
- Treat lease/claim semantics as first-class runtime contracts.

---

## 2) Two-phase step APIs unlock harder workflows

Absurd added `beginStep()/completeStep()` because simple one-shot `step()` was not always enough for hook-heavy and conditional commit flows.

### Norns action
- Evaluate a two-phase checkpoint/event API for complex side-effect boundaries:
  - reserve step intent
  - commit step result
- Keep current simple path for common cases.

---

## 3) Result retrieval is critical, not optional

Production use needed robust task-result inspection and awaiting, especially for parent/child coordination and debugging.

### Norns action
- Harden run result APIs and parent/child run linking semantics.
- Ensure operator and SDK APIs make result retrieval straightforward and deterministic.

---

## 4) CLI + ops dashboard are major multipliers

`absurdctl` and Habitat materially improved production operations and debugging speed.

### Norns action
- Prioritize `nornsctl` v0:
  - runs list/show/events
  - retry/resume
  - workers list/status
  - queue stats
- Add an ops-focused dashboard view (health, failures, action queues), separate from general app browsing.

---

## 5) Thin SDKs improve long-term velocity

Absurd benefited from centralizing durable behavior and keeping SDKs relatively thin.

### Norns action
- Keep worker protocol stable and versioned.
- Avoid pushing orchestration complexity into SDK logic.
- Enforce compatibility matrix + freeze windows.

---

## 6) Practical replay contracts beat abstraction theater

Boundary-based replay/checkpoint strategies can be easier to use than strict deterministic function replay models.

### Norns action
- Keep replay contract explicit:
  - what is reused
  - what is recomputed
  - what can never re-execute (side effects)
- Keep idempotency key semantics central.

---

## 7) Data lifecycle planning must happen early

Absurd highlights retention/partitioning pain once data grows.

### Norns action
- Define run/event retention policy now.
- Add cleanup/archival strategy and operational tooling.
- Plan partition strategy before growth forces emergency migration.

---

## Recommended next-step sequence for Norns

1. **Ops tooling first**
   - `nornsctl` v0 + ops dashboard health view
2. **Claim/lease/race hardening**
   - expand conformance and failure-window tests
3. **Result and child-run semantics**
   - strengthen APIs for await/inspect and orchestration
4. **Retention + cleanup baseline**
   - document and implement first cleanup path
5. **Optional two-phase step API**
   - prototype only if needed by concrete workflows

---

## Success criteria

This guidance is successful when:
- incident triage time drops
- replay/idempotency failures are rare and test-covered
- SDK contracts stay stable across runtime updates
- run/event storage growth has a clear retention path
