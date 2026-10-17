# Plan: a content-blind core

**Status:** written 2026-10-16, not scheduled. Development is paused
(`decision-log.md` § Slowing down); this records the thinking so it is not
redone.

The cipher, block shape, key handling, SDK middleware and dashboard decrypt
are already designed in `plan-harness-e2e.md` § Encryption design, with
E1–E4 as the work items. This doc is what changed in the thinking since,
where plaintext still enters core, and who the result is for.

## The question

Core sits between the LLM worker and the tool worker. Every message
crosses it and lands in its database. Two different objections hide in
that sentence. One is cost: the traffic and the storage. That one was
accidental and is fixed (`decision-log.md` § Linear storage, delta
dispatch): core now forwards each message about once and stores it once.
The other is trust: whoever runs core can read everything. That one is
only a problem when the tenant is not the one running core, which is to
say it is a hosted-product problem, and this plan is about it.

## Who it is for

A self-hoster owns the database; encrypting content against themselves
buys nothing. The buyer is someone who wants managed durability — runs
that park for days, questions that wait for a human, cron and webhooks
that start work when no worker is up, a log of what happened — and will
not send a vendor their transcripts. Temporal Cloud sells exactly this
through its payload codec. "A durable agent platform that cannot read your
agents" is a sharper position than "a durable agent platform", and it is
one a framework cannot take, because a framework has no vendor to distrust.

It also fights the hosted builder story: a dashboard that cannot read
anything is a hard sell unless the decrypting client ships on day one.
Both cannot be the lead. If this is built, it is the lead.

## What core needs to see

Audited 2026-10-16 against `Norns.Agents.Process`. The orchestrator reads:

- roles, `kind`s, tool names, tool-call ids, `is_error`, steps, token
  usage, finish reasons, error classes, model names;
- the control arguments of the built-ins: `launch_agent.agent_name` and
  `gard_id`, `wait.seconds`. `ask_human.question`, `launch_agent.message`
  and `launch_agent.context` are forwarded, never read;
- for context policy, roles and token counts only; for idempotency, run,
  step, call id, tool name and gard, never arguments; for compaction,
  nothing — it is a worker task and the summary is stored as it came back.

Everything else — user text, assistant text, tool arguments, tool results,
the summary, the def's system prompt, the run output — is stored and
forwarded without inspection. `test/norns/runtime/opaque_content_test.exs`
fills every content position with random bytes and runs, resumes, replays
and forks on them; it is the test that keeps this true.

Opaque blocks fit the linear-storage design well: a block is the same
bytes on the wire, in the log, in a delta and in a fork, so nothing is
re-encrypted on a resend and the worker's history cache holds ciphertext
it already decrypted once.

## Where plaintext still enters

In rough order of cost.

1. **The agent def.** `system_prompt` is content and is stored as whatever
   the client sent. Under encryption it is a block, written and edited
   only where the key is: the SDK's `register`, nornsctl, a decrypting
   dashboard. The builder's "edit the prompt in the browser" needs the
   browser to hold the key.
2. **Sending a message.** `POST /agents/:id/messages`, the agent channel,
   and `reply_to_human` take content from a client. The SDKs and nornsctl
   encrypt before sending (E1); a browser chat client needs the key.
3. **Webhook ingress.** A third party (GitHub, Stripe, Telegram) posts
   plaintext to core, and core has no key by design. The answer is a
   per-tenant public key: core seals the body on arrival and stores
   nothing readable; the worker opens it with the private key. Core did
   hold the bytes in memory for one request, and the docs must say so —
   this is the one path that is "encrypted at rest with your key" even in
   the end-to-end mode. Two days, plus a key format for asymmetric keys.
4. **Run webhooks and the agent channel outbound.** They carry blocks; the
   receiver decrypts. No core work beyond passing blocks through, which
   they already do.
5. **Reading.** The run page, the agent page, the conversations API and
   the trace summary are blind without a key. Two shapes:
   - **Browser-side decrypt** (E3 as designed): the key is pasted once and
     lives in the browser; a hook decrypts after patch. Right for a
     single operator and the self-hosted dashboard.
   - **A codec service**: a small HTTP service in the tenant's network
     that holds the key; the browser asks it to decrypt blocks, and core
     never sees the request. This is Temporal's model, and the right one
     for a hosted product with several people reading the same runs, since
     the key never has to be handed around. About a week, and it is a
     separate deployable the tenant runs.
6. **`runs.output`** is a string column; a block is JSON-encoded into it
   today (`Content.to_column/1`). It becomes JSONB (E2).

## Modes

The table in `plan-harness-e2e.md` § Modes still holds. One sharpening:
"end-to-end encrypted" requires every worker to be tenant-run *and* no
hosted feature that reads content — so no hosted builder, no hosted
summariser, no hosted connector — for that tenant. The mode is a property
of the tenant's whole deployment, not of a run, and the dashboard should
state which one the tenant is in.

Metadata still leaks, and the docs say so: tool names, ciphertext sizes,
step timing, agent names, error classes, who launched whom.

## Sizing

E1–E4 as estimated (about two weeks), plus webhook sealing (two days) and
the codec service (a week) if there is a hosted buyer. The core side is
the smallest part; most of the work is in the SDKs and in whatever reads.

## What would start it

A hosted customer who says "we cannot send you transcripts", or a decision
to make that sentence the pitch. Not before. Until then the principle is
kept by the conformance suite, which costs nothing.
