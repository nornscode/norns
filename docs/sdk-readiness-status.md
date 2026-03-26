# SDK Readiness Status

Last updated: 2026-03-25

## Gate 1 — Worker Protocol v1 Stability
State: Pass

- Registration validation tests cover required worker payload fields, invalid tool definitions, and capability parsing.
- Dispatch/result tests cover `llm_task` and `tool_task` payload shapes, normalized LLM result handling, invalid result payload rejection, and reconnect queue flush for queued work.

## Gate 2 — Agent Definition Contract Stability
State: Pass

- `AgentDef.new/1` contract tests cover required fields, defaults, explicit tool lists, invalid enum handling, and unsupported version errors.
- `AgentDef.from_agent/2` tests continue covering database-backed defaults and model config parsing.

## Gate 3 — Execution Semantics Reliability
State: Partial

- Replay conformance tests assert deterministic resume actions for checkpoint replay, waiting runs, and duplicate side-effect replay windows.
- Existing crash-window replay tests remain skipped, and failure classification/retry-policy conformance is not yet locked as a readiness gate.

## Gate 4 — Tenant/Auth Boundary Stability
State: Partial

- Tests prove tenant-scoped worker dispatch and run API tenant isolation.
- Worker socket and HTTP API rejection paths are covered for missing and invalid auth.
- Secret path validation for worker-mode provider key ownership is still missing.

## Gate 5 — Operational Observability for SDK Users
State: Partial

- Run API tests validate failure inspector top-level keys and nested checkpoint/event summary shape.
- Event timeline consistency for SDK-originated runs is not yet covered.

## Gate 6 — Compatibility Freeze Window
State: TODO

- No freeze window has started yet.
- Protocol payload shapes, `AgentDef` schema, and failure inspector responses still need a time-boxed compatibility freeze and change-policy enforcement.
