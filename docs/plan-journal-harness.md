# Plan: The agent is not the process (rejected)

**Status:** Rejected for coding agents, 2026-10-25. Kept because it is the
strongest version of the argument for making Norns a coding harness, and the
reasons it lost are the reasons Norns is what it is. See `decision-log.md`
§ Coding agents are not Norns runs.
**Came out of:** a design brief (2026-10-25) that put Herdr, Unhinged (the
Absurd-on-SQLite port) and Norns side by side and asked what a harness looks
like if the agent is a durable journal rather than a process.

## The thesis, as briefed

Vim's idea was that the buffer is not the file and the window is not the
buffer. The equivalent for agents: the agent is not the process, and the
terminal is not the agent. The agent is a journal of steps, events and
waits; processes are disposable workers that attach to a journal and
advance it; terminals are views that attach to a journal and render it.
From that: detach is free at every layer, blocked-on-input is a durable
wait answered from anywhere, the run tree is vim's undo tree, registers
are named checkpoints, macros are recorded runs, "what did it do while I
slept" is a query, and the orchestrator is a task like any other. Default
to a local SQLite file; sync to Norns optional and invisible.

## Where the argument held

- Journal/view (buffer/window), mode with a mode-dependent keymap, and the
  run tree as undo tree are structural and cheap. `Norns.Runs.Fork` and
  `Norns.Agents.Replay` already are the run tree.
- A run has one writer at a time, so laptop/server sync is log shipping
  with a fence token, not a CRDT: divergent tails become forks, never
  merges; two answers to one wait are first-write-wins.
- The view layer needs two channels, a durable one (replay then tail of
  the journal) and an ephemeral one (tokens and partial stdout from the
  live worker), because streaming cannot go through the journal.
- Herdr's actual contribution is inferring working/blocked/done from pane
  text; a journal makes that ground truth. The competition with Herdr was
  on mode truth, never on detach, which tmux solved in 1987.
- The smallest primitive set was six nouns: Journal, Run, Workspace,
  Worker, Wait, View, with Mode derived. Registers reduce to a message
  send of a journal slice; macros to a chain of user turns or an eval
  fixture; "plugins on the file" to a daemon tailing the log.

## Where it broke

- **The thesis was missing a noun.** A coding agent's state is the journal
  plus the working tree, and the tree does not survive the machine. Every
  "falls out" claim (detach, phone approval, a worker elsewhere picking the
  journal up) is conditional on that worker having the checkout at the
  right commit. The fix is a workspace ref on every side-effecting result,
  which `plan-coding-agent-runs.md` already proposed, and which is a git
  commit per tool call on repos with large untracked sets: the real latency
  risk, not the journal fsync.
- **Owning the loop means a worse editor.** Fork at a step, step replay and
  per-tool idempotency only exist if Norns runs the loop. Claude Code's
  inner loop has years of polish; `plan-differentiation.md` already said
  sleipnir would be the worse editor for the foreseeable future. The kill
  criterion written for the prototype was "no kept branch deeper than one
  after a week", and the honest prior was that it would trip.
- **Half the brief was already shipped.** Fork, durable waits, replay and
  the event log exist; D1, D3 and D4 in `plan-differentiation.md` were the
  rest, parked since 2026-10-14. The new content was local-first, the view
  API, the grammar and sync, and none of it was worth building ahead of a
  user who wanted fork.
- **The ninety-percent case is one agent in one terminal**, and the user
  interacts with that agent the whole time. What they wanted was to close
  the lid and have it continue. That needs a durable *machine*, not a
  durable *agent*.

## What replaced it

Keep Claude Code as the editor and put it on a machine with no lid: an
always-on Linux box with tmux, one window per project, reached over mosh
(repo `nornscode/egdir`). Durability for coding sessions is snapshot
durability: the disk, git, `claude --resume`. Norns's role is running
Fulla, the always-on manager above the agents, who reaches the box through
her existing `fulla-host` worker and hears from it through Claude Code's
hooks. The parts of this document that survive are the ones about Fulla:
waits that last for days, triggers that start work at night, a question
parked until a phone answers it. That is the durability Norns was built
for, and it was never the coder's.

## If it comes back

The trigger is a month of using the box and wanting, more than once, to
fork at step twelve or have a replay skip a finished bash command. Then:
the gard image, attach, hooks, permission wait and Fulla's tools all stay
identical whether the worker in the window is Claude Code or sleipnir;
only the worker swaps. Start from the primitive set above, make the ordered
log primary and Absurd's named checkpoints an index on it, and build the
weekend prototype the brief asked for: Unhinged's agent example plus an
ordered events table, a git ref per step, fork into a worktree, copy-the-
file handoff, and a view in a tmux pane. Abandon it again if the harness
costs more than ten percent of wall time or handoff fails on untracked
workspace state rather than the journal.
