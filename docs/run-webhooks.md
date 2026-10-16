# Run webhooks

## Status: shipped 2026-10-16 (core). The first receiver is Fulla's Telegram channel.

Three moments in a run's life have no outbound signal: it parks on an
`ask_human` question, it completes, it fails. Anything that needs to act on
them from outside — a chat channel that posts the question and relays the
answer, a dashboard, a pager — has had to poll `GET /runs`, and a process
that polls is a process that never sleeps. A run webhook turns that poll
into a push: Norns POSTs a signed event to a URL at each of those moments,
and the receiver can be a function that sleeps in between.

This is the serverless-worker wake pointed the other way. The wake says
"come and serve"; a run webhook says "here is what just happened". Same
signing scheme, same HTTP shape, a different trigger point.

## Registration

```
POST /api/v1/run_webhooks
{
  "url": "https://channel.example.com/norns/events",
  "events": ["run.waiting", "run.completed", "run.failed"]
}
```

`events` defaults to all three. The response carries a server-generated
`secret`, shown once; every delivery is signed with it. `GET`, `PATCH`
(`enabled: false` silences it without deleting it), `DELETE`, and
`POST /api/v1/run_webhooks/:id/test`, which delivers a `run.test` event
synchronously and reports what the receiver answered — for checking a
deployment end to end.

Webhooks are tenant-scoped and fire for every run in the tenant. A receiver
that cares about one agent filters on `agent_id`.

## The delivery

```
POST <url>
Content-Type: application/json
X-Norns-Event: run.waiting
X-Norns-Signature: t=1760572800,v1=<hex hmac-sha256>

{"type": "run.waiting", "run_id": 42, "agent_id": 7, "conversation_id": 9,
 "trigger_type": "schedule", "status": "waiting",
 "question": "Did you feed the starter?", "tool_call_id": "toolu_01..."}
```

`run.completed` carries `output` in place of the question; `run.failed`
carries `error`. A run stopped through `POST /runs/:id/cancel` (or the
dashboard) is a `run.failed` with `error: "Cancelled by user"`; the run's
`failure_metadata.error_code` is `cancelled`. The envelope fields are the ones `GET /runs/:id` returns,
so a receiver that wants more can fetch the run. The signature is the
Stripe scheme over `"<t>.<raw body>"` under the secret — the same one
`Norns.Workers.HttpSignature` produces for wakes and `Norns.Hooks.Signature`
verifies for inbound hooks, so a receiver implements it once. Reject a bad
MAC or a `t` more than five minutes off.

Deliveries run in their own tasks and never block the run. Norns reads
nothing from the response beyond its status: a non-2xx is logged, a
transport failure or a 502/503/504 is retried a few times with backoff
(a receiver that sleeps between events can look refused while it starts),
and a slow response is waited on for up to a minute. There is no delivery
log and no replay; a receiver that misses an event reconciles from
`GET /runs?status=waiting` when it next wakes, which is what the first
receiver does on every cold start.

## Where the events come from

The agent process has one `broadcast/3` through which every state change
reaches the dashboard and the agent channel. Run webhooks are fed from that
same call, so there is no second account of what a run is doing: if the
channel saw it, the webhook was sent. Only `waiting_for_user`, `completed`
and `error` become deliveries; tool calls, LLM responses and the rest stay
on PubSub.

## Content

The question, the output and the error message are content, and they go to
the tenant's own URL in the tenant's own tenancy — the same content the API
already returns for the run. Core forwards it and does not read it. A
tenant that does not want content leaving over this path subscribes to the
envelope and fetches the run instead; nothing in the design depends on the
content being present. When content encryption lands, these fields carry
the opaque block like every other content position.

## Limits

- No delivery log, no replay, no ordering guarantee between events of
  different runs. One run's events are sent in the order they happened,
  but each is its own task, so a slow `run.waiting` can land after a fast
  `run.completed` for the same run only if the receiver is very slow.
  Receivers key on `run_id` and `status`, not arrival order.
- One query per state change to find the subscribed webhooks. State
  changes are rare next to tool calls; a cache would need invalidating
  from the API and buys nothing yet.
- Fires for every run in the tenant. Per-agent subscriptions are a
  `where` clause away if a tenant with many agents wants them.
