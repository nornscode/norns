# Plan: What Sleipnir Has That No Other Harness Can

**Status:** Proposed (2026-09-11). Revised the same day after reading
norns-cloud: the first version assumed the worker lives on the developer's
laptop, which quietly made its best idea false. See § The substrate.
D0's git credential decided 2026-09-12 (fine-grained PAT now, GitHub App
when this is a product) — see § The git credential, which is also where
the one real security tension in D0 is written down.
Sequenced inside roadmap step 7 as the work after H4, before E1–E4.
**Depends on:** gards Phase 1 (shipped), triggers (shipped), hooks
(shipped), H1–H3 (shipped), `POST /runs/:id/reply` and
`POST /runs/:id/fork` (shipped), norns-cloud's Fly driver (spike landed
2026-09-11, `cfbebb1`).
**Relates to:** `plan-harness-e2e.md` (this is its "what it gives that no
other harness has" list, promoted from a paragraph to a plan), `gards.md`
(D0 is Phase 2 provisioning, narrowed to one workload), `plan-chains.md`
(D2 is the single-agent case of a trigger-started run), `roadmap.md` P2a/P2b.

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

## The substrate

The first draft of this plan put "the agent that works while you are
asleep" second and treated its only blocker as a missing `gard_id` column.
That was wrong, and wrong in a way worth recording, because the schema gap
was the visible half of the problem.

The other half: **a laptop is not awake at 3am.** A cron-started run needs
a worker that exists when the developer does not, and gard-strict dispatch
means a run bound to a sleeping laptop's gard does not fall back to
somewhere else — it sits pending, correctly and uselessly. Every claim in
this plan is conditional on where the gard runs:

| | laptop gard | cloud gard |
|---|---|---|
| survives the client closing | yes (since `ae71a81`) | yes |
| survives the laptop closing | **no** | yes |
| answers a 3am webhook | **no** | yes |
| needs a session moved between machines | yes (D3) | mostly moot |

So the substrate comes first. D0 is not a differentiating feature; it is
what makes D1 and D2 true statements rather than hedged ones, and it is
what lets the demo say "close your laptop" instead of "close the client
but leave the daemon running."

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
ones who do not. If that bet is wrong we will know from D0–D2 alone.

---

## D0 — A gard that is awake when you are not

**The claim:** a space does not have to be a checkout on your laptop.

This is much closer than the roadmap implies. norns-cloud already has the
whole handshake:

- A stateless driver contract (`up/down/restart/status`) and a **working
  Fly Machines driver** — one Fly app per tenant on its own private
  network, one machine per deployment, updated in place on redeploy. It
  has tests and two follow-up fixes, so it has been run, not just written.
- `Deployment` already `belongs_to :gard`.
- `Deployments.worker_env/3` already injects `NORNS_GARD` and
  `NORNS_GARD_CLAIM_TOKEN` beside `NORNS_URL` and a per-deployment API
  key. That is the entire claim protocol: a worker booted with those
  variables claims the gard on connect.
- `DeploymentsLive` at `/deployments`, and start/stop/restart/refresh.

Four gaps, three of them small:

1. **Nothing creates the gard.** `worker_env` reads `deployment.gard_id`
   when it is set; no path sets it. One function.
2. **Secrets.** `start_deployment`'s `opts[:env]` is a parameter with a
   comment saying the secrets context does not exist. The worker needs an
   LLM key. Passed at start for D0; the real context is P2a.
3. **No reconciler**, so a machine that dies stays dead. P2a. Skipped
   here, and the client should say "this gard has no worker" rather than
   pretend.
4. **The checkout.** A cloud gard has no code in it.

### The checkout, and why P2b is not on this path

`gards.md` defers cloud workspaces to **P2b — managed gards (workspace,
export, tunnel)**, and volund's local answer does not generalise: `volund
deploy --workspace ~/projects/my-app` copies a directory into a container
on the same machine. There is no such directory when the machine is in
Frankfurt, and the driver contract deliberately has no `copy_out` and no
`build`.

**For coding gards specifically, git already solved this.** The worker
clones the repository on start from a remote and a credential. No
workspace transfer, no snapshot, no tunnel — the one workload whose
working tree has a canonical remote is precisely the workload we are
building for.

That is worth recording as a decision in its own right: *the hardest item
in P2b is not on the critical path for coding gards.* P2b's workspace
primitives stay necessary for workloads whose state has no remote; they
are not necessary here.

### The git credential (decided 2026-09-12)

**A fine-grained PAT for D0; a GitHub App when this becomes a product.**

A PAT is right for D0 because D0 is single-tenant and ours: no install
flow, no callback URL, no app registration, and revocation is one click.
A GitHub App is where it has to end up — per-tenant installs, per-repo
grants, short-lived tokens, and an audit trail that says which
installation did what — but building it now would be building the product
before testing the thesis.

The PAT must be **fine-grained and scoped to the specific repositories of
that gard**, not a classic token, and not org-wide. Contents: read-write
only if the agent is meant to push; read-only otherwise.

**The part that is not obvious.** Sleipnir's agent has a `bash` tool, so
whatever the worker's environment holds, the model can read and put into
the event log — where it is durable and, until E1–E4, plaintext in
Postgres. `sleipnir/tools/shell.py` already strips a `HIDDEN_ENV` set
(`NORNS_API_KEY`, `NORNS_GARD_CLAIM_TOKEN`, the LLM keys) from the shell
it hands the model, so the mechanism exists — but a git credential cannot
simply join that set, because then `git push` from the agent's own shell
stops working. That is the tension:

- Token visible to the agent's shell → `git push` works, and the model can
  `echo` the token into a run event.
- Token stripped → the log stays clean, and the agent cannot push.

Three ways out, in increasing cost:

1. **Scope the blast radius and accept it.** A PAT that can only touch the
   repos this gard is for grants the agent nothing it was not already
   meant to have. The residual risk is the token landing in a durable log,
   which argues for rotating per gard and treating gard teardown as
   revocation. This is D0's answer.
2. **Credential helper over a socket** to a sidecar that holds the token:
   the agent can use git and can never read the secret. The right answer,
   and the one a GitHub App wants anyway since its tokens expire hourly.
3. **Clone at boot, strip, no push.** The agent works locally and pushing
   happens out of band. Safest, and too weak to be worth the gard.

So: (1) now, with the token scoped per gard and revoked on teardown, and
(2) as part of the GitHub App work rather than before it. Either way the
credential belongs in the secrets context, never on the `Deployment`
record, and never in a run event.

### Scope: two different things are called the MVP

- **P2a as a business** — self-serve, secrets context, billing,
  reconciler. Weeks, and nobody external is waiting on it.
- **A cloud gard for us, on our repos** — single tenant, secrets passed at
  start, no billing, no self-serve, a sleipnir worker image we publish.

D0 is the second. It tests the thesis — does an always-on gard make
triggers and notifications good? — without building a product, and
everything it does build is on P2a's path anyway.

**Acceptance:** `/space cloud <git-url>` in sleipnir creates a gard and a
deployment, the machine boots, clones, and claims the gard; a session in
that space does real work with the laptop closed; the space appears in
every sleipnir instance like any other. Destroying the gard revokes its
PAT, and no run event anywhere contains the token.

**Cost:** ~4 days.

## D1 — Answer from anywhere

**The claim:** the agent asks; you answer from wherever you are; the run
resumes on the machine that asked.

`ask_human` is already a durable parked state, and `POST /runs/:id/reply`
is already the way back in. The only thing missing is a way *out* — the
run has no way to tell anyone it is waiting — and a reply surface that is
not the TUI that started it.

Everything else parks a blinking cursor in one terminal and waits for the
person who opened it. This is the difference made concrete, and it is the
cheapest thing on this list. It is worth noting that D1 is the only item
here that is genuinely good *without* D0 — a laptop-gard run that parks
while you are in a meeting is still a run you want to answer from your
phone.

Shape: an outbound notifier on the `waiting_for_user` event (Slack DM
first — the connector image is already wanted for other reasons — then web
push, then email), each carrying the run URL and a reply affordance. The
dashboard's run page becomes a reply surface for anyone who can see it.

**Acceptance:** a run parks on a permission prompt with no client
attached; the answer is given from a phone; the run completes. No terminal
was open on either end at the moment of asking.

**Cost:** ~3 days for Slack + run-page reply. Push and email after.

## D2 — The agent that works while you are asleep

**The claim:** a coding run starts on the right checkout without a human
present — from a schedule, or from something that happened.

"When CI fails on main, start a run on this repo with the failure log."
"Every morning, run the flaky test fifty times and open an issue if it
goes red." No terminal-bound harness can do this at all.

Two blockers. D0 is the substrate one. The other is a schema gap:

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

**Acceptance:** a trigger bound to a cloud gard fires with no client
running anywhere and the laptop shut; the run lands on that gard's worker
and only that worker. With the worker down, the run stays pending and says
so rather than dispatching elsewhere. A webhook from a CI failure does the
same.

**Cost:** ~2 days core, ~2 days sleipnir, on top of D0.

## D3 — Move a session between machines

**Downgraded by D0.** If the canonical checkout is a cloud gard, there is
much less to move: the session is already not on a machine you own. What
survives is the narrower case of moving a session *off* a laptop gard onto
a cloud one — "I started this on the train, finish it where it can run
overnight" — which is a good feature and a much smaller one.

The caveat that made the general version expensive still applies to the
narrow one: the *conversation* moves, the *working tree* does not.
Uncommitted work on the laptop does not follow, and the client has to say
so rather than hand you an agent with a clean checkout and a transcript
describing changes that are not there.

**Acceptance:** a session in a laptop gard is moved to a cloud gard; its
next run is served there; the client refuses, loudly, while the origin
checkout is dirty.

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
week, across every machine. ~1 day, mostly a LiveView. Worth more once D0
exists, because a gard that is always awake is a gard that can always
spend.

**Retry from the failure, not from the start.** The error taxonomy and
failure inspector exist and `POST /runs/:id/retry` exists. Surfacing
"failed on a transient 529 at step 14 — retry from there" in the client is
the last mile of work already done. ~1 day.

---

## Sequencing

**D0 first**, because D2 is not true without it and the demo's headline
beat is not true without it. About four days, and every hour of it is on
P2a's path regardless.

**Then D1 and D2 together.** They are one feature from two sides: the
agent must be able to reach you when you are not there, and to start when
you are not there. Together they are the whole durable claim made usable,
and they are the demo's beats 3 and 5. About a week.

Then **D5** (two days, immediate daily value), then **D3** in its narrowed
form, then **D4**.

Before any of it: the demo script run manually end to end. Every break in
it is a dogfooding finding, and it cannot be faked with a fixture the way
a test can. The detached worker and cross-instance approval are both
unverified by hand today.

## What would falsify this plan

If D0–D2 ship and we still reach for Claude Code for real work, the
differentiation thesis is wrong, and the answer is not more of D3–D5 — it
is that the inner loop was the story after all, and sleipnir should become
a worker behind someone else's client rather than a client of its own.
That is a legitimate outcome and worth naming now, while it is cheap to
accept.

The sharper, earlier test is D0 itself. If a cloud gard turns out to be
something we provision once and never use — because the latency is
annoying, or because the checkout is always slightly wrong, or because we
simply prefer the machine under our hands — then "works while you are
asleep" is a demo feature and not a product, and D2 should be cut rather
than built on a substrate nobody wants.
