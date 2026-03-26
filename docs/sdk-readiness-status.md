# SDK Readiness Status

Last updated: 2026-03-25

## Gate 1 — Worker Protocol v1 Stability
State: Pass

- Registration validation tests cover required worker payload fields, invalid tool definitions, and capability parsing.
- Dispatch/result tests cover `llm_task` and `tool_task` payload shapes, normalized LLM result handling, invalid result payload rejection, and reconnect queue flush for queued work.
- Tenant-scoped dispatch proven (tenant A tasks never reach tenant B workers).

## Gate 2 — Agent Definition Contract Stability
State: Pass

- `AgentDef.new/1` contract tests cover required fields, defaults, explicit tool lists, invalid enum handling, and unsupported version errors.
- `AgentDef.from_agent/2` tests continue covering database-backed defaults and model config parsing.

## Gate 3 — Execution Semantics Reliability
State: Pass

- Error classification conformance: all 5 error classes tested (transient, external_dependency, validation, policy, internal) with deterministic mapping to retry/terminal decisions.
- Retry policy conformance: exponential backoff for transient, linear backoff for rate limits, terminal for validation/policy/internal. Determinism proven (same input = same output).
- Replay conformance: pending tool calls detected and resume action set correctly. Tool results persisted before crash are not re-executed. Checkpoint replay, waiting state reconstruction, and duplicate side-effect skipping all verified.
- Side-effect idempotency: deterministic keys, duplicate detection via persisted events.

## Gate 4 — Tenant/Auth Boundary Stability
State: Pass

- Tenant isolation: worker A cannot execute tasks for tenant B (proven with concurrent workers).
- Auth rejection: invalid/missing tokens rejected deterministically on both WebSocket and HTTP.
- Secret path: orchestrator state does not require provider API key when worker mode is enabled. LLM tasks dispatched to worker carry the tenant's key (verified via Fake LLM call recording).

## Gate 5 — Operational Observability for SDK Users
State: Pass

- Simple run event timeline verified: run_started → llm_request → llm_response → run_completed with schema_version and monotonic sequences.
- Tool-use run timeline verified: includes tool_call, tool_result, checkpoint events in correct order.
- Failed run timeline verified: run_failed event includes error_class, error_code, retry_decision. Failure inspector API response shape confirmed.

## Gate 6 — Compatibility Freeze Window
State: TODO

- All gates 1-5 now pass.
- No freeze window has started yet.
- Ready to begin 2-week freeze on protocol payload shapes, AgentDef schema, and failure inspector response shape.
