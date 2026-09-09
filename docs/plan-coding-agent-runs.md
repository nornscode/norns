# Plan: Coding-Agent Runs

**Status:** Proposed (2026-09-09). Phases F and 0 sit under "Alongside" in
`roadmap.md`; Phases 1 and 2 are not sequenced.
**Depends on:** gards Phase 1 (shipped), `nornsctl new` templates (shipped),
provisioner P1 gard deployments (shipped in volund). Phase 2 wants managed
gards (volund P2b) but does not block on them.

Herdr got a large audience fast by meeting developers where they already are:
running Claude Code, Codex, and Cursor in a terminal, every day. Norns solves
a problem those developers do have, but only on the day a container gets
evicted, and today they have no way to try it on work they already do. This
doc is the plan for closing that gap: running coding agents as Norns runs, so
the event log covers real coding sessions, and the things the event log makes
possible (resume, fork, time travel, prompt experiments) become demos anyone
can run against their own repo.

---

## Three ways to wrap a coding agent

The phrase "wrap the CLI" hides three very different designs. They differ in
who owns the loop, and that decides what Norns can and cannot do with the run.

| | A. CLI as a tool | B. CLI mirrored into a run | C. Norns owns the loop |
|---|---|---|---|
| Who runs the LLM loop | The CLI | The CLI | The Norns orchestrator |
| What Norns records | One `tool_result` per CLI invocation | One event per CLI turn and tool call, streamed from hooks | Every LLM call and tool call, as today |
| Resume after worker loss | Re-invokes the CLI, or skips it if it finished | Re-attaches to the CLI's own session file on the gard | Replays the log, re-dispatches the pending step |
| Fork from a step | No | No (the CLI's session format is not ours) | Yes |
| Idempotency | At the invocation boundary | None; observation only | Per tool call, as today |
| Cost | A template, one day | A worker plus one new ingress endpoint, about a week | A coding-agent worker plus filesystem snapshots, weeks |
| Quality of the agent | Whatever the CLI is | Whatever the CLI is | Whatever we build |

They are not alternatives. A is the cheapest demo. B is the adoption path,
because nobody will give up Claude Code to try Norns. C is where the
interesting features live, and it is the `norns-coding-agent` worker
`gards.md` has anticipated since v1.

## What each phase buys

### Phase 0: `coding-agent` template (design A)

A `nornsctl new --template coding-agent` scaffold whose worker registers one
side-effecting tool, `run_coding_agent(prompt, cwd)`, that shells out to
`claude -p` (or `codex exec`) inside a gard-bound worker. The Norns agent is a
planner that calls it once or several times.

What it demonstrates: kill the container mid-task and the planner picks up
where it left off. If the CLI invocation had finished, its result is in the
log and it does not run again. If it had not, it runs again from scratch,
which for a coding task is acceptable but not great.

What it does not give: anything inside the CLI's session. This is the
existing durability story applied to a bigger tool. Ship it because it is a
day of work and gives the README a demo on a real repo.

### Phase 1: mirrored runs (design B)

Claude Code and Codex both expose their loop from the outside: headless mode
with a streamed JSON transcript, and lifecycle hooks (`PreToolUse`,
`PostToolUse`, `Stop`, `Notification`). A thin worker, `norns-observe`,
starts the CLI, subscribes to that stream, and appends each turn as events
on a Norns run. The run has a new kind, `observed`: the orchestrator persists
and serves events but never dispatches, because there is nothing for it to
dispatch. This needs one new ingress, `POST /api/v1/runs/:id/events`, with
the same validator every other event goes through.

What it buys, in rough order of value:

- **A fleet view.** Every headless coding agent across every machine shows in
  one dashboard with its state, current tool call, and token spend. This is
  herdr's "never hunt for the stuck one," but for agents that are not in a
  terminal at all.
- **Blocked means `:waiting`.** A CLI `Notification` or permission prompt maps
  to the existing `ask_human` and `:waiting` state, so the existing
  `POST /runs/:id/reply` path, and anything built on it (Slack, Telegram,
  the dashboard), answers a stuck coding agent. This is not free: today a
  reply resumes the agent process, and an observed run has none. The reply
  has to be pushed to the observer worker holding the CLI's prompt, so
  Phase 1a is an events ingress *and* a reply leg to the worker.
  `ResumeAgents` must also skip observed runs on boot.
- **A queryable transcript.** Cost per task, tool-call histograms, which
  files an agent touched, all in Postgres, across runs and machines.
- **Resume, weakly.** On worker loss the observer restarts the CLI with its
  own resume flag against the session file on the gard. Norns records the
  gap. This is not replay; it is supervised restart with an audit trail.

What it does not give: fork, idempotency inside the session, or any control
over the loop. It is observation. The CLI's session format is theirs and
changes without notice, so the mirror is a maintenance surface. Keep the
mapping in one module per CLI and expect to touch it monthly.

### Phase 2: Norns-native coding agent (design C)

A `norns-coding-agent` worker that registers `read_file`, `write_file`,
`edit_file`, `bash`, `grep`, and `glob` as tools, runs on a gard, and lets
the orchestrator run the loop against any provider through the existing LLM
task. This is the design `gards.md` already describes; what is new here is
what to do with the log once we have it.

**The working tree has to be checkpointed with the log.** The event log
survives worker loss; the filesystem does not. Replaying `edit_file` at step
40 on a fresh gard is wrong if steps 1 through 39 never touched this disk.
The cheap and mostly sufficient answer is git: after every side-effecting
tool call the worker commits the working tree to a run-scoped branch and
records the commit SHA in the `tool_result` event. Resume on a fresh gard
means `git checkout <sha>` from the last completed step, then replay from
there. Untracked build artifacts and dependencies are rebuilt, which is a
cost, not a correctness problem. Managed gards (volund P2c) can add real
snapshots later for the cases where rebuilding is too slow.

With a per-step SHA in every tool result, the log is a full timeline of
(messages, filesystem) pairs, and the features the user asked about fall out:

- **Fork.** `POST /api/v1/runs/:id/fork` with `{step, message?, system_prompt?, model?}`
  creates a new run whose checkpoint is the parent's messages truncated to
  `step`, on a fresh gard checked out at that step's SHA. Overrides let the
  new run continue with a different prompt, model, or instruction. This
  endpoint is worth building before Phase 2 finishes, because for
  non-coding agents it needs no filesystem at all: the `checkpoint_saved`
  event already holds `messages` and `step`. Fork on the hello agent is the
  cheapest "time travel" demo we have. Three details that are not just
  truncation:
  - **Any step is forkable, whatever the checkpoint policy.** Checkpoints
    are written every step, on tool call, or manually. Fork takes the last
    checkpoint at or before `step` and replays events forward to it, which
    is what resume already does; it does not need a checkpoint at `step`.
  - **Overrides clone the def.** The agent process re-reads its def every
    step by design ("agents are configuration"), so a `system_prompt` or
    `model` override has nowhere to live on the run. Fork with overrides
    creates a variant agent (the def with the overrides applied) and forks
    the run onto it. One agent per variant also makes prompt experiments
    legible in the dashboard.
  - **A fork starts its own conversation.** A run inside a persistent
    conversation must not append its fork's turns to the parent's history.
    Forks are task-mode runs with a fresh conversation, as chain steps are.
- **Time travel in the dashboard.** The run page already lists events. Add a
  "fork from here" button on any step and a diff view against the step's
  SHA. Scrubbing a run is reading the log; branching it is fork.
- **Prompt experiments.** Fork the same step N times with N system prompts
  or models, run to completion, and score. For coding agents the score is
  concrete: tests pass, diff size, tokens, wall time. This is an eval harness
  on top of fork and a scoring tool the tenant registers; Norns provides the
  branching and the ledger, not the judgment.
- **Auto-optimization.** An agent (on Norns, so likely a cloud product like
  the builder) that runs prompt experiments in a loop and keeps the best
  prompt. Mechanically it is Phase 2 plus `launch_agent`. Do not plan
  further than that until fork and scoring exist and someone has used them
  by hand; the interesting questions (what to vary, how many samples, how
  to keep costs bounded) only get answers from use.

## Benefits, stated plainly

- **Distribution.** The daily coding-agent crowd can try Norns on their own
  repo in an afternoon, with the tool they already use, and see something
  they cannot get elsewhere: a durable, forkable record of what the agent
  did.
- **A demo that lands.** "Kill the container during `cargo test`, watch the
  run continue on another machine" is the README's kill-the-worker video
  applied to work people recognise.
- **The builder gets its worker.** `plan-agent-builder.md` fabricate mode
  needs a coding agent on a gard. Phase 2 is that worker.
- **Fork is a core primitive with uses beyond coding.** Retrying a support
  run from the step before it went wrong, or A/B testing a system prompt on
  real conversations, are the same endpoint.

## Drawbacks and risks

- **Phase 2 competes with tools people love.** A minimal coding worker is a
  few hundred lines; a good one has context compaction, permission
  policies, skills, and years of prompt tuning. We will not match Claude
  Code's quality, so Phase 2 must be sold on what the log enables, not on
  the agent. Phase 1 exists so adoption does not depend on Phase 2 winning.
- **Mirroring is a moving target.** Hook and stream formats are the CLIs'
  to change. Budget ongoing maintenance and isolate each CLI adapter.
- **Step latency.** Coding runs have hundreds of steps and each one round
  trips through the orchestrator and Postgres. Tens of milliseconds per
  step is fine; anything that adds a network hop per tool call on the worker
  side is not. Measure before Phase 2 ships.
- **Fork needs both halves.** Forking messages without the matching
  filesystem produces a model that believes files exist which do not. The
  fork endpoint must refuse a coding-agent fork whose step has no SHA.
- **Idempotency for `bash` is a fiction.** Skipping a completed `bash` step
  on replay is only correct because the filesystem was restored to after
  that step. The two mechanisms are coupled; document it and test it in the
  replay conformance suite.
- **Cost multiplies under experiments.** N forks cost N runs. Prompt
  experiments need a hard budget per experiment before anyone runs them
  unattended.
- **Secrets stay where they are.** Workers hold provider keys and repo
  credentials, as today. Mirrored runs carry tool inputs and outputs, which
  for a coding agent means source code in the event log. Tenants who care
  need redaction at the worker before append; call this out in the Phase 1
  docs rather than pretending it away.

## Sequence and sizing

| Phase | Deliverable | Where | Size |
|---|---|---|---|
| 0 | `coding-agent` template, README demo on a real repo | nornsctl | 1 day |
| 1a | `observed` run kind, `POST /runs/:id/events`, event validator coverage | norns | 3 days |
| 1b | `norns-observe` worker for Claude Code hooks, then Codex | new repo | 1 week |
| 1c | Fleet view and blocked-state mapping in the dashboard | norns | 3 days |
| F | `POST /runs/:id/fork` for non-coding runs, "fork from here" in RunLive | norns | 3 days |
| 2a | `norns-coding-agent` worker with git-per-step SHAs in tool results | new repo | 2 weeks |
| 2b | Filesystem-aware resume and fork on gards | norns + worker | 1 week |
| 2c | Scoring tool convention and a prompt-experiment CLI in nornsctl | nornsctl | 1 week |

Phase F is independent of everything else and is the first thing to build:
it is small, it is a core primitive, and it is the demo. Phase 0 is next
because it is a day. Phase 1 before Phase 2, because adoption should not
wait on us building a better coding agent than the ones people already run.

## What we are not doing

- A terminal multiplexer or TUI. Herdr owns that space and it is the wrong
  layer for Norns.
- Interactive sessions. Norns runs headless work; the observer wraps
  headless mode only.
- Replacing the CLI's own resume in Phase 1. It is theirs; we record around
  it.
