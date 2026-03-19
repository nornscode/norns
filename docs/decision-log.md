# Decision Log

Last updated: 2026-03-18

## Product Decisions

### The product is the chat builder, not the engine
- The workflow engine is infrastructure; the differentiator is an LLM that generates workflows from conversation
- The builder needs the engine to exist first — hand-write workflows to understand what generated code should look like
- Ship the engine, validate with hand-written workflows, then build the builder

### Workflows are Elixir modules, not configuration
- Real code with loops, conditionals, pattern matching — not JSON steps or YAML
- The chat builder generates these modules
- LLM steps are just another action type within the code (like `http` or `shell`)

### Don't build integrations
- Use managed integration platforms (Nango, Composio) or plain HTTP
- Build zero connectors until the workflow builder is proven valuable
- The `http` step type covers most REST APIs

### LLM has two roles in the system
1. **Builder LLM** — translates natural language into workflow modules (the product)
2. **In-workflow LLM steps** — reasoning actions within a workflow (summarize, classify, decide)

---

## Implemented

### Multi-tenancy from day one
- Every table has `tenant_id` (NOT NULL, FK to tenants).
- Agent names unique per tenant.
- API keys stored per tenant.

### Schema simplification — defer version pinning
- Removed all version columns from runs, removed `run_decisions` table.
- Add back when policy gates or versioning logic exist.

### Synchronous agent execution via Oban
- `Runner.execute/3` is a plain function, Oban worker wraps it.
- No GenServers until multi-step or long-running workflows justify them.

### Anthropic API via Req
- `LLM.complete/5` wraps the Messages API. No streaming, no tool use.
- API key passed explicitly from tenant.

### Event-sourced run audit trail
- Every step logged as a `RunEvent` with sequence, event_type, payload.
- Unique constraint on (run_id, sequence).

### Docker Compose for all dev tooling
- No local Elixir install. `Dockerfile.dev` + app service in docker-compose.

---

## Open

### A) Failure semantics
- Retriable vs terminal failure taxonomy.
- Idempotency for side effects under retries.

### B) LLM reflection within workflows
- Periodic checkpoints where the LLM reviews execution and can adjust the plan.
- Design is fuzzy — needs concrete workflow examples first.

### C) LLM provider abstraction
- Currently Anthropic-only. When/how to support multiple providers.

### D) Chat builder architecture
- How the builder LLM understands available integrations and step types.
- How generated workflow modules are validated, tested, and deployed.
- How auth flows for integrations are handled in the builder conversation.
