# Serverless workers

## Status: shipped 2026-10-15 (core). SDK-side wake handlers are the next step.

A Norns worker holds a WebSocket open and gets tasks pushed down it. That
means a worker is a running process, and a process that runs all day to
serve a few tool calls an hour is a cost with nothing behind it. A
serverless worker is the same worker, asleep until it is needed. Norns knows
how to wake it, and it connects as usual once awake.

## What changes, and what doesn't

Nothing about the task protocol changes. The worker still joins
`worker:lobby`, still gets `tool_task` and `llm_task`, still answers
`tool_result`, still sends `drain` when it is leaving. Gards, idempotency
keys, the lost-task re-dispatch, the queue flush on join: all of it applies
unchanged, because the woken worker *is* a worker.

Two things are new:

1. **A standing declaration.** A sleeping worker cannot be asked what it
   offers, so its tools and capabilities are declared up front and kept in
   Postgres (`serverless_workers`). The registry advertises those tools to
   agents while the worker is asleep. A tool an agent can see is a tool it
   can call; the call is what wakes the worker.
2. **A wake.** When a task has no connected worker to go to, it is queued as
   it always was, and then Norns POSTs a signed wake to the declaring
   worker's `wake_url`. The platform behind that URL starts the function or
   container; the worker inside it connects; the join flushes the queued
   task to it.

The alternative was an HTTP transport: POST the task itself, read the result
from the response. It was rejected because it would have been a second
protocol — a result callback for anything slower than the platform's
request cap (API Gateway cuts at 29 s; an LLM call can run minutes), its own
retry and timeout semantics, and no way to carry `drain`, port
registration, or streaming. Waking the worker and letting it speak the
protocol it already speaks was less work and left nothing half-supported.

## Registration

```
POST /api/v1/serverless_workers
{
  "worker_id": "search-fn",
  "wake_url": "https://search-fn.example.com/norns/wake",
  "capabilities": ["llm", "tools"],
  "tools": [
    {"name": "web_search", "description": "...", "input_schema": {...}}
  ]
}
```

The response carries a server-generated `secret`, shown once. Give it to
the function as configuration; Norns signs every wake with it. `worker_id`
is the id the worker must join the channel with — that is how the registry
knows the connection it just accepted is the worker it woke.

`GET`, `PATCH` (`enabled: false` withdraws the tools without deleting the
record), `DELETE`, and `POST /api/v1/serverless_workers/:id/wake` to send a
wake by hand and check a deployment end to end. `awake` on each record says
whether an incarnation is connected right now, and `last_woken_at` when this
node last sent it a wake; `GET /api/v1/workers` marks such a connection
`serverless: true`. The dashboard's Workers page and `nornsctl workers list`
show the same thing: a connected incarnation sits in the connected list with
a `serverless` badge, and a declaration with no connection is listed as
asleep, with its declared tools and last wake.

Serverless workers have no gard. A function that may start anywhere has no
filesystem to be affine to, so their tools serve no-gard runs only — the
same rule as connectors.

## The wake

```
POST <wake_url>
Content-Type: application/json
X-Norns-Worker-Id: search-fn
X-Norns-Signature: t=1760572800,v1=<hex hmac-sha256>

{"type":"wake","worker_id":"search-fn"}
```

The signature is the Stripe scheme: HMAC-SHA256 under the secret over
`"<t>.<raw body>"`, with `t` in Unix seconds. Reject anything older than five
minutes or with a bad MAC. (`Norns.Hooks.Signature` verifies this exact
shape for inbound webhooks, so an SDK implements it once.)

The wake carries no task. The worker's job on receiving one is to connect to
`/worker` with the declared `worker_id` and tools, serve what it is given,
and when it has been idle for a while, `drain`, disconnect and return.

**Hold the wake request open while you serve.** On the platforms this is
for, an instance lives as long as it has an inbound request: Fly autostop
counts inbound connections only, Cloud Run gives CPU to a request, Lambda
runs for the length of the invocation. The worker's outbound WebSocket does
not count on any of them. So the handler for the wake should connect, serve
until idle, disconnect, and only then answer `200`. Norns holds its side of
the request open for up to an hour and reads nothing into the response
beyond logging a non-2xx. A platform that lets a handler answer at once and
keep running may do that instead.

Norns sends one wake per worker per 30 seconds. If the cooldown passes with
the worker still absent and work still queued for it, it sends another; the
queue's own five-minute stale sweep is what ends this if the worker never
comes. Connection-level failures (refused, reset, DNS) are retried with
backoff inside a single wake, since a cold start can look like one. A slow
response is not a failure.

## The other half

A wake brings a worker up to serve a tool call. It says nothing when a run
parks on `ask_human`, completes, or fails, because none of those is a tool
call — so a channel that relays questions and outputs would still have to
poll, and a process that polls never sleeps. Run webhooks
(`run-webhooks.md`) are the same signed POST pointed at those three
moments. A deployment with both is asleep end to end.

## What a worker SDK needs

An HTTP handler for the wake, which verifies the signature and then runs the
existing worker loop with an idle timeout. Everything the loop does today —
join, serve, drain — is unchanged. Python: an ASGI/WSGI handler or a Lambda
entry point around `Worker.run(idle_timeout=...)`. Elixir: a Plug. Neither
exists yet; this document is the contract they implement.

## Limits

- Node-local like the rest of the registry: the declarations are loaded
  into `WorkerRegistry` state at boot and on change, and the wake cooldown
  is per node. Single-node is the supported deployment
  (`decision-log.md` § Multi-node), so this is consistent, not an extra
  caveat.
- An agent offered a serverless tool pays a cold start on the first call
  after the worker has slept. The 5-minute task timeout absorbs it; nothing
  else is tuned for it yet.
- Two serverless workers that declare the same tool are both woken. The
  first to join takes the task.
