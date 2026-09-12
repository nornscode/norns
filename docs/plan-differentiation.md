# Plan: What Sleipnir Has That No Other Harness Can

**Status:** Proposed (2026-09-11). Sequenced inside roadmap step 7 as the
work after H4, before E1–E4.
**Depends on:** gards Phase 1 (shipped), triggers (shipped), hooks
(shipped), H1–H3 (shipped), `POST /runs/:id/reply` and
`POST /runs/:id/fork` (shipped).
**Relates to:** `plan-harness-e2e.md` (this is the "what it gives that no
other harness has" list, promoted from a paragraph to a plan),
`plan-chains.md` (D2 is the single-agent case of a trigger-started run),
`gards.md` (D3 is a second use of worker affinity).

H4 is a week of dogfooding. A day of it produced fourteen commits, and
every single bug was in the client: cross-instance coherence, onboarding,
lifecycle, density. Not one was in the agent. That is a good sign about the
loop and a bad sign about where our attention goes by default — polishing
a harness against harnesses that have a year of polish on us.

This plan is the correction. It says what to build instead, and why those
things and not others.

---

## The test

Everything unique to Norns falls out of one fact:

> The loop runs on a server, and the transcript is a database row rather
> than your scrollback.

So the feature test is: **does this need the agent to exist when the
developer does not?** Laptop closed, nobody at a keyboard, someone else
looking. If yes, no other harness can follow us there without rebuilding
their foundation. If no, we are racing Claude Code on their ground.

That test sorts into four axes:

- **Time** — it runs when you are away (D2).
- **Place** — the session is not tied to this machine (D1, D3).
- **People** — the session is not tied to you (D1, D5).
- **Structure** — the history is a graph, not a scroll (D4).

## What we are deliberately not building

The inner loop: a better edit tool, smarter context assembly, faster
diffs, prettier streaming. Claude Code and amp are ahead and will stay
ahead, because that is the whole of their product and a quarter of ours.
Sleipnir's inner loop has one job — **be good enough that it is not the
story**. Every hour past that threshold is an hour not spent on something
they structurally cannot copy.

This is a real cost and should be stated plainly: sleipnir will be a worse
editor than Claude Code for the foreseeable future. The bet is that a
worse editor that works while you sleep, on a machine you are not at, in a
thread someone else can answer, wins the users who need that and loses the
ones who do not. If that bet is wrong we will know from D1 and D2 alone.

---

## D1 — Answer from anywhere

**The claim:** the agent asks; you answer from wherever you are; the run
resumes on the machine that asked.

`ask_human` is already a durable parked state, and `POST /runs/:id/reply`
is already the way back in. The only thing missing is a way *out* — the
run has no way to tell anyone it is waiting — and a reply surface that is
not the TUI that started it.

Everything else parks a blinking cursor in one terminal and waits for the
person who opened it. This is the difference made concrete, and it is the
cheapest thing on this list.

Shape: an outbound notifier on the `waiting_for_user` event (Slack DM
first — the connector template is already wanted for other reasons —
then web push, then email), each carrying the run URL and a reply
affordance. The dashboard's run page becomes a reply surface for anyone
who can see it.

**Acceptance:** a run parks on a permission prompt on machine A with no
client attached; the answer is given from a phone; the run completes on
machine A. No terminal was open on either end at the moment of asking.

**Cost:** ~3 days for Slack + run-page reply. Push and email after.

## D2 — The agent that works while you are asleep

**The claim:** a coding run starts on the right checkout without a human
present — from a schedule, or from something that happened.

"When CI fails on main, start a run on this repo with the failure log."
"Every morning, run the flaky test fifty times and open an issue if it
goes red." No terminal-bound harness can do this at all.

**This is blocked, and the blocker is small.** Triggers and hooks cannot
aim a run at a checkout:

- `Norns.Triggers.Trigger` has `name`, `cron`, `message`,
  `conversation_key`, `enabled`, `last_fired_at` — and no `gard_id`.
- `Norns.Triggers.fire/1` builds opts from `conversation_key` alone and
  calls `Registry.send_message/4` (`lib/norns/triggers.ex:92`).
- `Norns.Hooks.Hook` is the same: no `gard_id`.

So a cron-started run dispatches to any worker. For a chat agent that is
correct. For a coding agent it is wrong in the worst way — under
gard-strict dispatch it reaches no worker at all and sits pending, or it
reaches a worker in the wrong checkout and edits the wrong repository.

Shape: `gard_id` on `triggers` and `hooks`, validated on write exactly as
`AgentController.put_gard_opt/3` already validates it on `send_message`
(a gard from another tenant must 404, not queue forever), threaded through
`fire/1` and the hook ingest path. Then `/trigger` in sleipnir to aim one
at the space you are in, and the trigger list on the space.

**Acceptance:** a trigger bound to a gard fires with no client running; the
run lands on that gard's worker and only that worker; with the worker
down, the run stays pending and says so rather than dispatching elsewhere.
A webhook from a CI failure does the same.

**Cost:** ~2 days core, ~2 days sleipnir.

## D3 — Move a session between machines

**The claim:** start it on the laptop, continue it at the desk, same
session, full transcript.

The transcript was never on either machine, so this is a rebinding of the
next run's `gard_id` and nothing more. `/move <space>` in sleipnir, a
picker of spaces whose worker is `ready`.

The honest caveat: the *conversation* moves, the *working tree* does not.
Moving a session whose work is uncommitted on the laptop gives you an
agent at your desk with a clean checkout and a transcript describing
changes that are not there. So D3 needs the client to say what it is about
to do, and probably to refuse a move while the origin gard's checkout is
dirty until we have something better to offer.

**Acceptance:** a session started in gard A, with A's worker stopped, is
moved to gard B and its next run is served by B — with the client warning
when A's tree is dirty.

**Cost:** ~2 days, most of it the warning.

## D4 — Fork as a tree, not a redo

**The claim:** branches are objects, not a destroyed alternative.

Other harnesses "regenerate", which throws away the path you had. `POST
/runs/:id/fork` makes a real second run sharing a prefix, and both are in
the log permanently. What is missing is a UI that treats that as the point:
fork at step N, siblings as tabs, and a diff of where the two branches
diverged.

This is the one item here that is about the log's shape rather than about
absence, and it is the most speculative. It is in the plan because prompt
and approach experiments are the actual daily use — "try both, keep one" —
and because it costs little on top of what F shipped.

**Acceptance:** from one session, fork twice at different steps, see three
siblings, and read a diff of their final outputs without leaving the
client.

**Cost:** ~3 days, all client.

## D5 — Two cheap ones

**Spend that survives the window.** Runs already carry `input_tokens` and
`output_tokens`. Every other harness shows a counter that dies when you
close the terminal; we can show real cost per session, per space, per
week, across every machine. ~1 day, mostly a LiveView.

**Retry from the failure, not from the start.** The error taxonomy and
failure inspector exist and `POST /runs/:id/retry` exists. Surfacing
"failed on a transient 529 at step 14 — retry from there" in the client is
the last mile of work already done. ~1 day.

---

## Sequencing

**D1 and D2 together, first.** They are one feature from two sides: the
agent must be able to reach you when you are not there, and to start when
you are not there. Together they are the whole "durable" claim made
usable, and they are what the README demo is actually demonstrating —
beats 3 and 5 of the demo script. About a week and a half.

Then **D5** (two days, immediate daily value), then **D3**, then **D4**.

Before any of it: the demo script run manually end to end. Every break in
it is a dogfooding finding, and it cannot be faked with a fixture the way
a test can. The detached worker and cross-instance approval are both
unverified by hand today.

## What would falsify this plan

If D1 and D2 ship and we still reach for Claude Code for real work, the
differentiation thesis is wrong and the answer is not more of D3–D5 — it
is that the inner loop was the story after all, and sleipnir should become
a worker behind someone else's client rather than a client of its own.
That is a legitimate outcome and worth naming now, while it is cheap to
accept.
