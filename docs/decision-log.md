# Decision Log

Last updated: 2026-03-17

## Decided

### 1) Replay determinism
- Replays use **stored outputs/artifacts**.
- Do not re-run model calls during replay.

### 2) Human override model
- Override behavior is **agent-configurable**.
- Supports:
  - single-step override
  - approval-chain override

### 3) Override drift controls (adopted)
- Require override reason on every override.
- Capture actor identity + timestamp.
- Weekly override-rate report by agent and policy.
- Threshold alerts when override rate exceeds configured limit.

### 4) Policy ownership and validation
- Every policy must have an explicit owner.
- Policy changes require testing against historical runs in a staging harness.
- Shadow/staged rollout is optional in early phase.

### 5) Version governance
- Prompt changes are the most granular change unit.
- Prompt/policy updates can roll into an agent version.
- Runs should pin effective versions at run start.

### 6) Canonical run state shape (recommended)
Adopt **Typed core + extension bag**:
- Typed core runtime fields (status, step, budgets, pending signals, etc.)
- Bounded extension context for agent-specific data

This balances flexibility with operational safety.

### 7) Runtime safety controls
- Circuit breakers are required.
- Per-agent budgets are required.
- Max loop iterations deferred for now.

### 8) Audit UX baseline
- Workflow execution views must support filtering by:
  - policy-adherent runs
  - attempted policy violations

### 9) Multi-tenant boundaries
- Row-level tenant boundaries.
- Secrets stored per tenant.
- Noisy-neighbor controls deferred.

### 10) Early GTM validation workflows
- Release notes generator from GitHub PRs/changes.
- Slack Q&A agent over docs, codebase, and prior answers.

---

## TBD / Open

### A) Failure semantics
- Define retriable vs terminal failure taxonomy.
- Define idempotency guarantees for side effects under retries.

### B) Canonical run-state schema details
- Finalize exact typed core field set.
- Define max extension context size and rollover behavior.

### C) Version packaging policy
- Define when prompt/policy updates require new agent version vs patch-level metadata update.
