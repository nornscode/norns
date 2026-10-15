# Plan: Code Mode

**Status:** Proposed (2026-10-15). Parked by default under
`decision-log.md` § Slowing down; the worker-only step is the exception
because it is a day's work and is itself the test for whether the
pause-to-core step is wanted.
**Depends on:** the harness (shipped), opaque content (shipped), the SDK's
idempotency cache (shipped).
**Relates to:** `plan-harness-e2e.md` (sleipnir is the first and only
caller), `roadmap.md` § Not now "Two-phase step API" (pause-to-core is that API,
with the concrete workflow it was waiting for), E2 encrypted content
(pause-to-core wants it for snapshot integrity).

Code mode is one tool, `run_code`, whose argument is a short program the
model wrote. The program calls the agent's other tools as functions and
returns one result. Six tool calls that would have been six model turns
become one turn. Cloudflare's Project Think and Pydantic AI both ship it;
this plan is what it looks like when the loop lives in Norns.

The sandbox is [Monty](https://github.com/pydantic/monty), Pydantic's
Python-subset interpreter in Rust. It has no filesystem, network, or
environment inside; the host exposes functions and the sandbox sees only
their return values. It has memory, allocation, duration, and recursion
limits, starts in microseconds from a pool, and has Python, JavaScript,
Rust, and community Go bindings, so sleipnir and volund can both host it.
It runs Pydantic AI's code mode today.

The reason it is Monty and not a container or Pyodide is one feature:
execution pauses at every host function call, and the paused interpreter
serializes to a few kilobytes that load into a fresh session in another
process or on another machine. That is a worker-side tool call that can be
handed to the orchestrator, which is the shape Norns already has for
everything else.

---

## Why bother, and how we will know

sleipnir has seven tools. The token-reduction headline (Cloudflare's 1.17M
to 1,000 is an MCP server with thousands of endpoints) does not apply. What
applies is turn reduction. "grep for the symbol, then read the five files
that matched" is six model turns today and one with code mode, and the
explorer agents do almost nothing else. Each saved turn is a full context
resend, so on a long session the token saving follows from the turn saving.

The worker-only step exists to measure that, not to assume it. The numbers to take from
Mimir and sleipnir runs, before and after, with the same tasks:

- model turns per run
- input tokens per run
- wall time per run
- how often `run_code` fails on a syntax or subset error and the model
  retries (Monty is a subset; the model will hit it)

If turns drop by a third or more on explorer runs and the retry rate is
tolerable, pause-to-core is worth designing. If not, `run_code` stays as a
worker tool nobody
reaches for, and that is an answer that cost a day.

---

## Step one, worker-only: `run_code` in the Python SDK

No core change. The tool lives in the SDK, not in any one agent, because
code mode wraps tools where they already run: sleipnir's `read_file` reads
the developer's tree and Mimir's `search_memories` reads Mimir's database,
and no worker elsewhere can call either. The shape is Pydantic AI's
`CodeMode`: a wrapper that takes a list of `ToolDef`s and returns one more.

```python
from norns import tool, code_mode

run_code = code_mode([read_file, grep, glob, git], max_calls=20, max_memory=4 << 20)
Agent(name=..., tools=[read_file, grep, glob, git, run_code], ...)
```

Monty is an optional extra (`norns[code]`) so workers that never use it
install nothing new. Each agent opts in with one line and chooses which of
its tools go inside. Inner calls resolve locally inside the worker, exactly
as Pydantic AI does it.

Mimir goes first, then sleipnir. Mimir has about twenty tools across
GitHub, web, memory, issues, sources, projects, release notes, and runtime
status, well over half of them reads, and its questions are "search, then
read what matched". It also runs in production, so the before-and-after
numbers mean something. sleipnir's explorers, with seven tools and a
laptop-local worker, are the second data point.

- **Read-only tools only.** This is the whole idempotency story for the
  worker-only step.
  Core mints keys for side-effecting calls before dispatch and the worker's
  `_handle_tool_task` dedupes on them. An inner call inside a program has
  no key, so a side-effecting inner call would be a call core cannot
  protect. Rather than invent worker-minted keys, `code_mode()` refuses a
  `ToolDef` with `side_effect=True`. In Mimir that excludes the memory and
  source writes; in sleipnir it excludes `write_file`, `edit_file`, and
  `bash`, and the explorer agents already have exactly the remaining set.
- **What the model sees.** The result content is the program's return
  value, followed by the inner call log (name, arguments, truncated result,
  error) in the order they ran. The model needs the log to know what it
  already read, and it is content, so it goes in the content position.
- **What the envelope sees.** `kind: "code_run"` and `data` with call
  count, the inner tool names, and the Monty version. Names and counts are
  envelope under `Norns.Runtime.Content`; arguments and results are not and
  stay out of `data`. The dashboard can show "run_code: 6 calls, 4 read_file
  2 grep" without reading anything.
- **Budgets, and they are small.** The program is a router, not a store:
  it decides what to read next and hands the result back. Everything that
  makes it more than that also makes its state big, slow, or unrecoverable,
  so the budgets are set to forbid it rather than to be generous.
  - `max_suspensions` (Monty, per checkout): 20 inner calls. Pydantic AI
    allows 100; sleipnir's explorer turns are under ten calls, and a
    program that wants more is doing a job that should be several turns.
  - `max_memory` (Monty): 4 MiB. This is what keeps file contents out of
    the interpreter. A program that reads six large files into variables
    and concatenates them hits `MemoryError`; one that reads, extracts a
    few lines, and drops the rest does not. Once the program pauses to core this is also the bound
    on snapshot size, since the snapshot is the heap.
  - Per-call result cap: each external function truncates what it returns
    into the sandbox at 16 KiB, well under sleipnir's 60 KB `read_file`
    cap for native calls. The program sees a marker and the offset to
    continue from, as `read_file` already does. The model, not the
    program, decides whether to keep reading.
  - `max_duration` (Monty): 5 seconds of interpreter time, not counting
    time spent in host calls.
  - Result cap to the model: the returned content plus the inner call log
    is truncated at the same size as a native tool result. A program that
    returns too much has not summarised, which is its one job.
  Exceeding any budget is an error result that lists the inner calls
  already made with their truncated results, so the model continues from
  them rather than starting over. The numbers are starting points; the
  worker-only measurements say where they move.
- **The prompt.** One paragraph: when to write a program (several reads
  whose later steps depend on earlier results), when not to (a single call,
  anything that writes), and that it is a Python subset with no imports
  beyond the standard library Monty provides. Pydantic AI's code-mode prompt
  is the starting point.
- **Parallelism.** Monty supports `asyncio.gather` over external functions.
  The worker-only step runs them concurrently in the worker, which is free.
  Pause-to-core has to think about it (below).

Deliverable: `code_mode()` in the SDK, the prompt paragraph, and the four
numbers above from a week of Mimir and sleipnir use.

---

## Step two, pause to core: inner calls become orchestrator calls

This is the part nobody else has, and the part that only makes sense once
the worker-only step shows the turn reduction is real.

The worker runs the program until it hits a host call. Instead of resolving
it, the worker returns to core: "the program is paused at a call to
`write_file` with these arguments; here is the paused interpreter". Core
dispatches that inner call like any other tool call, with a core-minted
key, logged, and recoverable. When the result lands, core hands the
snapshot and the result to any worker with the capability, which loads the
snapshot, resumes, and runs to the next call or to completion.

What this buys:

- **Idempotency is back where it belongs.** Inner side-effecting calls get
  core keys, so `write_file` and `bash` inside a program are as safe as they
  are outside it. The read-only restriction lifts.
- **The log is complete.** Every inner call is a `tool_call` and
  `tool_result` pair, inspectable in nornsctl and the dashboard, with the
  same shape as today.
- **The program survives the worker.** A worker that dies mid-program is
  re-dispatched from the last snapshot, not from the start. Cloudflare's
  fibers checkpoint only where the author calls `stash`; Pydantic AI under
  Temporal replays the snippet against recorded results and turns off
  speculation to do it.
- **`ask_human` works inside a program.** It is a host function. The
  program pauses, core parks the run in `:waiting` through the existing
  built-in interception, and the answer resumes the program a minute or a
  day later. sleipnir's permission flow (a tool answers "permission
  required" with a token, the agent asks, then retries with `approval`)
  works inside a program unchanged once `ask_human` is a binding.

### The protocol

Two new pieces, both small.

1. **A paused result.** A worker may answer a `run_code` task with
   `status: "paused"` instead of `ok` or `error`:
   `{status: "paused", call: {name, arguments}, snapshot: <opaque>, monty_version}`.
   Core appends a `code_paused` event: `tool_call_id` of the `run_code`
   call, `step`, `name` of the inner tool, `monty_version`, and the snapshot
   in a content position (it is bytes a worker produced and core never
   reads). Then core treats the inner call as a tool call at the same step
   with id `<run_code id>.<n>`: tool policy, built-in interception, key
   minting, dispatch, all as today. The run stays in `:awaiting_tools`; the
   model sees nothing.
2. **A resume task.** When the inner result lands, core dispatches
   `resume_code` with the snapshot, the inner call's `tool_call_id`, and its
   result, to any worker advertising `run_code`. The worker loads the
   snapshot, calls `resume({'return_value': ...})` or
   `resume({'exception': ...})`, and answers with `ok`, `error`, or another
   `paused`. The inner result is also appended as a normal `tool_result` so
   the log reads straight.

This is the two-phase step API the roadmap said to prototype only when a
concrete workflow needed it. Here it is confined to one tool, which is the
right size for a prototype.

### Crash recovery

Replay sees: `tool_call run_code`, `code_paused`, `tool_call <id>.1`,
`tool_result <id>.1`, possibly more pairs, and no final `tool_result` for
`run_code`. Recovery re-dispatches `resume_code` with the latest
`code_paused` snapshot and the latest inner result that followed it. If the
latest inner call has no result yet, recovery re-dispatches that inner
call, which is the existing pending-tool path. Nothing new in `Replay`
beyond recognising the pair.

### What the snapshot is, and is not

- **Opaque content.** Core stores it, forwards it, never decodes it. The
  worker-only memory budget bounds it at the source: a 4 MiB heap cannot produce a
  snapshot much over 4 MiB, and typical is single-digit KB. Core still
  enforces its own cap, 1 MiB, as a backstop against a worker with the
  budget misconfigured; a program whose state exceeds it fails its
  `run_code` call with an error the model sees. A snapshot per inner call
  is a row in the event log per inner call, which is the other reason to
  keep the heap small and the call count low.
- **Trusted producer only.** Monty does not authenticate snapshots and
  warns against loading any it did not produce. Until E2 ships a worker
  encrypts and signs the snapshot with the gard key and it rides as an
  `$enc` block; before that, an HMAC with the gard's claim secret is
  enough for a prototype. Either way the check is the resuming worker's,
  not core's.
- **Versioned.** `monty_version` rides in the event. A resuming worker on
  a different format version fails the resume with
  `error_class: "snapshot_version"`; core fails the `run_code` call with
  that error, and the model reruns the program. Inner side effects already
  done are in the log under their keys, but a rerun is a new `run_code`
  call with a new id, so its inner calls get new keys and run again. That
  is at-least-once, the same guarantee as everywhere else.
- **Mounts and host objects do not travel.** Pause-to-core uses neither: every tool is
  a plain external function returning plain values.

### Parallel inner calls

`asyncio.gather` over several host calls produces a `FutureSnapshot` with
several pending calls. Pause-to-core handles it the same way a multi-tool model turn
is handled: dispatch all pending inner calls at once, collect all results,
resume once with `{call_id: result, ...}`. Restored future snapshots
cannot use `resume_auto`, so the worker resolves them explicitly; that is
the same code path as sequential, with a map instead of a value. Ship
sequential first, batch second.

### Where the lines are

- The orchestrator still executes nothing. It stores bytes it does not
  read, dispatches calls it already knew how to dispatch, and hands bytes
  back. `Norns.Runtime.Content` and the opaque-content conformance suite
  are extended to the new content position and that is the only core
  touch of content.
- sleipnir's `bash` inside a program is still sleipnir's `bash`: allow
  rules, permission tokens, and `ask_human` apply per inner call.
- Not a sandbox for computation. No packages, no inheritance, partial
  stdlib. The program orchestrates tools; anything heavier is a `bash`
  call to a real interpreter, as today.

---

## Not building

- **Worker-minted idempotency keys.** The worker-only step avoids the
  question by being read-only; pause-to-core answers it by returning keys
  to core. Nothing in between.
- **A general nested-event kind.** `code_paused` is specific to code mode.
  A second tool that needs to pause mid-execution is the signal to
  generalise, the same rule as the policy hook.
- **Speculation and eager execution.** Pydantic AI runs branches the model
  may not use and warns that cancellation does not undo a sent request.
  Under a durable log that is a liability, and they turn it off under
  Temporal for the same reason.
- **A JavaScript sandbox.** Monty's JavaScript bindings exist; a worker in
  another language can host the same interpreter. A V8-based sandbox would
  be a second subset to teach the model and a second snapshot format.

---

## Open questions

- Does the model write programs that fit the subset often enough? Monty's
  own claim is that LLM-written code adapts to the error message. The
  worker-only step measures it.
- Step numbering for inner calls: same step with sub-ids (above), or a new
  step per inner call? Same step keeps `max_steps` meaning model turns,
  which is what sleipnir's users set it for.
- Should the dashboard render a `run_code` call as one row with children,
  or flat? Flat is free; children need the sub-id convention in the UI.
- Go: `gomonty` is a community binding. volund does not need code mode
  today; if it ever does, the protocol above has nothing Python-specific.
