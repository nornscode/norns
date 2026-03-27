# Plan: Multi-Agent Orchestration

## The Pattern: Agents as Tools

A supervisor agent has tools that call other agents. Each sub-agent is an independent Norns run with its own durability. The orchestration is just the supervisor's system prompt + tool definitions — no graph language, no visual builder, no special infrastructure.

```python
@tool
def call_billing_agent(question: str) -> str:
    """Delegate billing questions to the billing specialist."""
    result = client.send_message("billing-agent", question, wait=True)
    return result.output

@tool
def call_technical_agent(question: str) -> str:
    """Delegate technical issues to the technical specialist."""
    result = client.send_message("technical-agent", question, wait=True)
    return result.output

supervisor = Agent(
    name="triage",
    system_prompt="Route customer issues to the right specialist.",
    tools=[call_billing_agent, call_technical_agent],
)
```

This works today with no changes to Norns. The LLM decides which agent to call. Each sub-agent run is independently durable.

## Coordination Patterns

All of these are expressible with the "agents as tools" pattern:

**Pipeline** — A → B → C. Supervisor calls agents sequentially, passing output forward.

**Fan-out/fan-in** — Supervisor calls multiple agents, collects all results. (Currently sequential via tool calls. Parallel dispatch is a future optimization.)

**Router** — Supervisor decides which agent to call based on input. The LLM does the routing.

**Supervisor** — Meta-agent that monitors sub-agent results and decides when to retry, escalate, or abort.

**Loop** — Supervisor calls an agent, evaluates the result, and may call it again with feedback.

## What to Build

### 1. Run lineage (`parent_run_id`)

Add `parent_run_id` to the `runs` table. When a tool calls another agent via `NornsClient.send_message`, the SDK passes the current run ID. Norns links the child run to the parent.

```
Run #42 (triage supervisor)
├── Run #43 (billing-agent) — completed
├── Run #44 (technical-agent) — completed
└── Run #45 (review-agent) — completed
```

This is one migration and a small API change:

```
POST /api/v1/agents/:id/messages
{
  "content": "...",
  "parent_run_id": 42
}
```

### 2. Run tree view in dashboard

The run detail page shows child runs as a tree. Click into any sub-agent run to see its events. "Why did this customer get a wrong answer?" becomes traceable through the full agent graph.

### 3. SDK helper: `call_agent`

A convenience wrapper in the Python SDK that creates a tool from another agent:

```python
from norns import call_agent

supervisor = Agent(
    name="triage",
    system_prompt="Route issues to the right specialist.",
    tools=[
        call_agent("billing-agent", "Handle billing and refund questions"),
        call_agent("technical-agent", "Handle technical issues and bugs"),
    ],
)
```

`call_agent(name, description)` returns a `ToolDef` whose handler calls `NornsClient.send_message(name, ..., wait=True)`. It automatically passes `parent_run_id` if available.

### 4. Document the patterns

Add a "Multi-Agent Patterns" section to the SDK docs with concrete examples: customer support triage, research pipeline, code review fan-out.

## What NOT to Build

- **Graph definition language** — the code IS the workflow. The supervisor's system prompt + tools define the graph. No DSL needed.
- **Agent-to-agent chat protocols** — agents communicate through tool calls and return values, not a separate messaging system.
- **Visual workflow builder** — the value is in the observability (seeing what happened), not in visual construction.
- **Parallel dispatch primitive** — the LLM can request parallel tool calls. Norns already dispatches them concurrently. No new primitive needed.

## Future Optimizations (not now)

**Budget propagation** — set a token budget or time limit on the whole workflow, not just individual agents. The supervisor tracks cumulative usage from sub-agent results.

**Cached sub-agent results** — if the same sub-agent query was answered recently, return the cached result. Useful for fan-out patterns where multiple supervisors might ask the same specialist.

**Auto-scaling** — BEAM can run thousands of agent processes. When the task queue grows, spawn more worker capacity. This is where the worker model pays off at scale.

## Comparison with Alternatives

| Tool | Model | Durability | Multi-agent | Self-hostable |
|------|-------|-----------|-------------|---------------|
| **Norns** | Agents as tools, supervisor pattern | Full (event sourced, crash recovery) | Via tool composition | Yes (MIT) |
| **LangGraph** | Graph nodes, edges | Checkpointing | Built-in graph model | Partial (lib is MIT, platform proprietary) |
| **CrewAI** | Role-based collaboration | None | Built-in roles | Yes |
| **AutoGen** | Group chat | None | Built-in conversation | Yes |
| **Temporal** | Workflows + activities | Full | Child workflows | Yes (MIT) |

Norns' position: durability of Temporal + agent-native primitives + simpler composition model (tools, not graphs).

## Implementation Order

1. Add `parent_run_id` to runs (migration + schema)
2. Accept `parent_run_id` in send_message API
3. Run tree view in dashboard
4. `call_agent` SDK helper
5. Pattern documentation with examples
