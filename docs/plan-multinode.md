# Plan: Multi-node

**Status:** Proposed (2026-10-16)
**Depends on:** nothing shipped is missing; every phase lands on single-node first
**Relates to:** `decision-log.md` § "Open" > "Multi-node", `lessons-absurd-production.md`, `nornscode/norns#17`
**Supersedes:** the libcluster + Horde note in `roadmap.md` and `lib/norns/application.ex`

Norns runs as one node. Durability does not depend on that: a run is rebuilt
from its Postgres event log, so a restart loses nothing. What a single node
costs is availability. On 2026-10-16 Fly rebooted hosts fleet-wide; the
`norns-runtime` machine was unreachable for eighteen minutes while Postgres
stayed up, every worker's WebSocket failed its handshake, and nothing could
dispatch until a redeploy placed a new machine. A second node on another
host would have taken the reconnects in seconds.

This plan makes two or more nodes correct. It does not make Postgres
highly available; that is bought separately and is a constraint every
option shares.

---

## What is node-local today

Everything below lives in one BEAM's process state. Two connected nodes
run two independent copies of each; this is the failure `#17` observed,
where `GET /api/v1/workers` answered from whichever node took the request.

- **Agent processes.** One per `{tenant_id, agent_id, conversation_key}`,
  found through a local `Registry` and started under a local
  `DynamicSupervisor` (`Norns.Agents.Registry`, `Norns.Agents.Process`).
  Node B knows nothing about node A's process, so a message or a boot-time
  resume landing on B starts a second one for the same conversation. That
  is the dangerous case: two processes replaying one run means duplicate
  LLM calls and duplicate side effects.
- **Orphan resume.** `Norns.Workers.ResumeAgents.resume_orphans` runs at
  boot and resumes every `running` or `waiting` run with no process *on
  this node*. A second node would resume all of the first node's runs.
- **Worker registry.** `Norns.Workers.WorkerRegistry` maps workers to
  channel pids and pushes tasks with `send/2`. Socket pids are node-local by
  nature; the catalog (`Norns.Tools.Catalog`), the workers endpoint, gards
  and the agent process all read this registry.
- **Task queue.** `Norns.Workers.TaskQueue` holds tool tasks that found no
  worker. In memory, but losing it is recoverable: a pending tool call is
  re-dispatched when its run resumes.

Already safe across nodes: run state and the event log (Postgres);
`Phoenix.PubSub` (cluster-wide once nodes are connected; the `agent:<id>`
topics carry through); Oban and `TriggerScheduler` (Postgres-backed, with an
atomic `last_fired_at` claim). Outside this repo: the serverless wake in
`norns-cloud` decides "no worker holds these tools" from the local registry.

---

## Approach: Postgres for truth, distribution for the fast path, no Horde

The earlier note said libcluster plus Horde for the registries. Horde's
registry is a CRDT: during a partition both sides can hold a process for
the same key, and the duplicate is reconciled *after* it has already made an
LLM call. That is the one outcome this plan exists to prevent, so Horde is
the wrong primitive for exclusivity.

The lesson from Absurd and DBOS applies here: mutual exclusion belongs in
Postgres, which the cluster already agrees on. A process owns a
conversation by holding a lease row, renews it on a timer, and stops itself
if it cannot. A partitioned node loses its leases and fences itself; the
survivor resumes. No consensus protocol, no CRDT, and the same code path
on one node, where it also hardens resume against a zombie process.

Erlang distribution is still worth having, for cheap cross-node sends and
for PubSub, but nothing correctness-critical rides on it. Every node keeps
its local `Registry` and `DynamicSupervisor`; Postgres says which node owns
what, and distribution carries the message there.

---

## Phase 1: Conversation leases

The correctness primitive. Ships value on single-node and unblocks
everything else.

**Schema.** `agent_leases(tenant_id, agent_id, conversation_key, node,
lease_until, inserted_at)` with a unique index on the first three. Keyed by
the process key, not the run, because the process is per conversation and
a conversation outlives its runs. (`conversation_key` can be `"default"`
with no `conversations` row, which is why this is its own table.)

**Acquire.** `Norns.Agents.Registry.start_conversation/4` and
`resume_agent/4` first run one statement:

```sql
INSERT INTO agent_leases (...) VALUES (..., $node, now() + $ttl)
ON CONFLICT (tenant_id, agent_id, conversation_key) DO UPDATE
  SET node = EXCLUDED.node, lease_until = EXCLUDED.lease_until
  WHERE agent_leases.lease_until < now() OR agent_leases.node = EXCLUDED.node
RETURNING node;
```

A row comes back: this node owns it, start the process. No row: someone
else holds a live lease; return `{:error, {:owned_by, node}}` and the caller
forwards (below). The local `Registry` still dedupes within a node, so
`{:already_started, pid}` keeps its current meaning.

**Renew.** `Norns.Agents.Process` renews every `ttl / 3` (ttl 30 s to
start). A renewal that fails, returns no row, or times out means the lease
is gone: the process logs it and exits with `:lease_lost`, without writing
another event. Whatever it was doing is re-dispatched by resume on the
owner, which is the same recovery path a crash takes today. Release on
normal terminate.

**Forwarding.** `Registry.send_message/4`, `reply`, `cancel` and anything
else that reaches a process by key look up the local `Registry` first,
then the lease row, and call the owning node over `:erpc` (phase 4 wires
the nodes; until then a foreign node name is a hard error with a clear
log line, and never occurs on one node).

**Orphan resume** becomes "runs in `running` or `waiting` whose
conversation has no lease or an expired one", and runs on a short Oban
cron (every minute) on every node, not only at boot. Each node races for
the lease; exactly one wins per conversation. Boot-time resume stays as
the first tick.

**Tests.** The one that matters: two processes race for one key and
exactly one starts; a process whose lease is stolen exits with
`:lease_lost` and appends nothing; resume picks up a run whose lease
expired. Phase 4 adds the two-node version.

---

## Phase 2: Task queue to a table

`queued_tasks(id, tenant_id, tool_name, gard_id, payload, queued_at)`.
`enqueue/2` inserts; `flush/3` is `DELETE ... WHERE tenant_id = $1 AND
tool_name = $2 AND gard_id IS NOT DISTINCT FROM $3 RETURNING *` under
`FOR UPDATE SKIP LOCKED`, so two nodes flushing the same tool for the same
tenant split the rows instead of both taking them. The five-minute stale
sweep becomes a `queued_at` cutoff in the same delete, run from the Oban
cron in phase 1.

Small, isolated, and it fixes a real single-node gap: a queued task today
dies with the node and waits for the run's resume to notice.

---

## Phase 3: Worker connections table and cross-node dispatch

**Schema.** `worker_connections(tenant_id, worker_id, node, tools,
capabilities, gard_id, draining, serverless, connected_at, heartbeat_at)`,
unique on `(tenant_id, worker_id)`. Tools stored as the JSON the worker
sent, so `available_tools/2` can build `%Tool{}` structs from the table.

**Writes.** `NornsWeb.WorkerChannel.join/3` upserts the row with this
node's name after `register_worker` succeeds; `terminate/2` deletes it when
the stored node is this node (a late terminate after a reconnect elsewhere
must not evict the new row, the same rule `unregister_worker` has for pids).
The transport's heartbeat touches `heartbeat_at`; the Oban cron deletes
rows older than three heartbeats, which covers a node that died without
running `terminate`.

**Reads.** `available_tools/2`, `connected_workers/1`, `llm_available?/1`
and the gard-filtered variants become queries. The catalog is read on every
LLM turn, so cache per node and invalidate on a `workers:<tenant>` PubSub
broadcast from join and terminate; a stale cache only mis-advertises a tool
for one turn, and dispatch, not the catalog, is the authority.

**Dispatch.** `dispatch_task/4` and `dispatch_llm_task/3` pick a worker
from the table. Owned by this node: push to the channel pid exactly as
today. Owned by another: `:erpc.call(node, WorkerRegistry, :push_local,
[tenant_id, worker_id, task])`, which does the local pid lookup and `send`
there. The result comes back the way it does now, since the channel's
`tool_result` is handled on the node that owns the socket and the
`from_pid` it must reach is a remote pid distribution delivers to. If the
owning node is down, the `:erpc` call fails fast and dispatch falls
through to the next candidate or the queue.

In-flight tasks to a worker whose node dies fail as "worker disconnected"
when its lease-holder resumes, which is the existing path. `@max_tool_attempts`
keeps its meaning: attempts are counted on the run, not the node.

**Gards.** Dispatch is strict on gard both ways today and stays so.
`kick_gard_workers/2` broadcasts on PubSub and each node kicks its own
sockets.

---

## Phase 4: Cluster and scale

- Add the `dns_cluster` dependency and `{DNSCluster, query:
  System.get_env("DNS_CLUSTER_QUERY") || :ignore}` to the supervision tree.
  `rel/env.sh.eex` already exports `DNS_CLUSTER_QUERY`, a `RELEASE_NODE`
  named by `FLY_PRIVATE_IP`, and the IPv6 distribution flags; what is
  missing is the dependency, the child, and `RELEASE_COOKIE` as a Fly
  secret.
- Turn `warn_if_unclustered_multi_node` into its opposite: warn when the
  lease table shows another node's live leases and `Node.list/0` is empty,
  since that means distribution is down while Postgres is up and forwarding
  will fail.
- Two-node test with OTP's `:peer` module: start a second node against
  the test database, run an agent on node A, kill A mid-step, assert B
  resumes within the lease window and the event log holds exactly one
  `llm_request` per step.
- `fly scale count 2` with the second machine in a region near the
  database (`ord` or `ewr`; the database is in `yyz`), not across the
  continent, because every event-log write from the far node pays that
  round trip several times per step. Fly's proxy routes a worker's
  WebSocket to the nearest healthy machine, so Toronto workers land on
  `yyz` and fail over to the other region when that host is down.
- Remove the single-node comments in `fly.toml` and `application.ex`.

---

## Phase 5: Serverless wake (norns-cloud)

The wake decision reads `worker_connections` instead of the local
registry, so a worker connected to node A is not woken again from node B.
Two nodes that both see "no worker" and both wake is harmless: the
serverless worker's wake handshake joins an incarnation already running.
Phase 4 can ship before this with one node; it must land before the hosted
instance scales.

---

## Order and what each phase buys alone

| Phase | Buys on one node | Needed for two |
|---|---|---|
| 1 Leases | resume survives zombie processes; forwarding path exists | yes |
| 2 Queue table | queued tasks survive a restart | yes |
| 3 Connections table | `GET /workers` answers from Postgres; catalog without a GenServer call | yes |
| 4 Cluster | nothing until count > 1 | yes |
| 5 Wake | nothing | before scaling the hosted instance |

Phases 1 through 3 each merge and deploy on their own with the machine
count still at 1. Nothing here changes the worker protocol, the SDKs, or
the REST API.

---

## Not in this plan

- **Postgres availability.** `norns-db` is a single-region managed
  instance. A second Norns node in another region does nothing when the
  database is unreachable. Scaling it is a separate decision.
- **Horde / libcluster.** Replaced by leases plus `dns_cluster`; see above.
- **Sticky routing.** No attempt to send a worker to the node that owns
  its runs. Dispatch crosses nodes when it has to; the cost is one
  intra-cluster hop.
- **Netsplit between nodes with Postgres reachable from both.** Leases
  stay correct (one owner); forwarding fails until the split heals, and
  the guard in phase 4 says so. Fly's private network makes this rare;
  not worth more than a log line yet.
