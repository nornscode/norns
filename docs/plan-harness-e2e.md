# Plan: The Harness, and Opaque Content

**Status:** Proposed (2026-09-09); sequenced as roadmap step 7 with P0 under
"Alongside" (roadmap v6.3, same day). **P0 shipped 2026-09-09** — see
§ What P0 landed. **H1 shipped 2026-09-09** as `sleipnir` — see § What H1
landed.
**Depends on:** gards Phase 1 (shipped), `drain` / SDK 0.4.0 (shipped),
`GET /api/v1/workers` (shipped). The encrypted mode wants P2a's secrets
context for cloud-run workers but does not block on it.
**Relates to:** `plan-coding-agent-runs.md` (this supersedes its Phase 2
sizing and defers its Phase 1), `plan-chains.md` (templating moves, see
§ Chains), `plan-agent-builder.md` (fabricate mode gets its worker).

Two proposals, one doc, because the second only makes sense once the first
exists and the first is only defensible if the second is possible.

1. **The harness.** A Norns-native coding agent in the shape of pi or amp: a
   small tool worker on the developer's machine, a client they type into,
   and the loop running in the orchestrator where the log already lives.
2. **Opaque content.** A design principle, applied now, that the
   orchestrator routes on an envelope and never on content, so the log can
   be end-to-end encrypted with a key Norns never holds. The harness puts
   source code in the event log; this is what makes that acceptable.

---

## Why build the harness

`plan-coding-agent-runs.md` sized a native coding agent at weeks and
hedged on it because we will not out-build Claude Code on agent quality.
Both points are true and neither is the reason to build it. Pi did not win
its audience on quality; it won on being small, hackable, and honest about
what it is. The loop in pi is a few hundred lines. The loop in Norns is
`Norns.Agents.Process`, and it already does what pi's session file does
plus what it cannot: resume on another machine, checkpoints every step,
durable sub-agents, human input as a first-class state, fork (Phase F).

The harness is that loop with coding tools attached. What it gives that no
other harness has is a consequence of where the loop runs, not extra work:

- Sessions survive the laptop sleeping, the terminal closing, the container
  being evicted. The run is in the log; the gard reconnects and it
  continues.
- Fork any step. Prompt experiments are N forks and a scoring tool.
- Sub-agents that survive a crash (the v0.4 recovery fix, now on a task
  people recognise).
- Start a coding run from a cron, a webhook, or a Slack thread, and answer
  its permission prompt from any of them.
- With P2a: the thinking runs in the cloud on the tenant's key, the hands
  run on the developer's machine. "Cloud coordinated" is the accurate
  phrase; see § Modes for why "accelerated" oversells the encrypted case.

What it costs: two core features (compaction, and the opaque-content
audit), a worker, and a client. About two and a half weeks to a version we
would use on norns itself. The bet is that we prefer it for our own work
within a month. If we do not, we find out in two weeks instead of by
shipping it.

## The problem the harness creates

A coding run's tool inputs and outputs are source code. Today they land in
`run_events.payload` in plaintext, and under the managed product that means
our Postgres, our backups, and our operators. Amp stores threads on
Sourcegraph's servers; Cursor has a privacy mode. The coding crowd has
accepted that the LLM provider sees their code and has not accepted much
else. "We cannot read your log" is a claim none of the incumbents make and
one Norns can make cheaply, because the orchestrator was built to never
look inside the work. That is the second half of this doc.

---

## Design principle: content is opaque

> The orchestrator routes on the **envelope** and never reads, transforms,
> or generates **content**. Content is whatever a worker or a human wrote
> and an LLM will read: message text, tool arguments, tool results,
> system prompts, human questions and answers, run output, error text from
> tools. The envelope is what the state machine needs to run: roles, block
> kinds, tool names, tool-call ids, steps, sequence numbers, token usage,
> stop reasons, error classes, agent names, gard ids, timestamps.

Stated as a test: **replace every content field in a run's events with
ciphertext under a key core does not have, and the replay conformance
suite still passes.** Resume, fork, idempotency, checkpoints, sub-agent
reattachment, and the state transitions must all work on the envelope
alone. This is the property that makes end-to-end encryption a
worker-side feature rather than a core rewrite, and it holds only if
every future core feature is written to it. Compaction and chains
templating are both tempting to write as "core reads the text"; the
principle says they may not be.

Rules that follow:

1. **Core never branches on content.** No `String.trim`, no `byte_size`,
   no slicing, no `Jason.decode` of a content field in `lib/norns`.
2. **Core never generates content.** No synthesised user messages, no
   "[Inherited context]" preambles, no "Timer completed." strings. Where a
   message has to exist for the model, a worker writes it, or the envelope
   carries a *kind* that the LLM worker renders.
3. **Built-in tools split their arguments.** `wait.seconds`,
   `launch_agent.agent_name`, `launch_agent.gard_id` are envelope, because
   the orchestrator acts on them. `ask_human.question`,
   `launch_agent.message`, `launch_agent.context` are content, because it
   only forwards them.
4. **Content fields accept a string or an opaque block.** The event
   validator checks the envelope and treats content as a value it may store
   and forward, nothing else.
5. **Anything that needs plaintext is a worker.** Compaction, templating,
   scoring, the builder reading runs, a Slack connector relaying a question:
   each holds the key if there is one, and is therefore a place the tenant
   chooses to trust.

Adopted 2026-09-09: `decision-log.md` § Content is opaque, next to "Pure
orchestrator, no execution," of which it is the data-plane half.

### Where core reads content today

The audit of `Norns.Agents.Process` and the validator. None of these is
large; together they are the three-day "make the principle true" step.

| Site | What it does | Fix |
|---|---|---|
| `compact_message/1` | Truncates tool results over a byte cap by slicing the string | Move the cap to the tool worker, which truncates before returning. Core keeps a hard payload-size guard on the whole event, which is envelope. |
| `complete_successfully/2` | Trims the final text and falls back to the last non-empty assistant message; writes `run.output` | The LLM worker reports `final_output` in the response envelope (it already decides `finish_reason`). Core stores it as content. |
| `build_data_message/1` | Synthesises a "[Inherited context from parent agent]" user message from `launch_agent.context` | Carry `context` as an opaque block with kind `inherited_context`; the LLM worker renders the preamble. |
| `build_system_prompt/1` | Reads `agent_def.system_prompt` from the def and copies it into `llm_request` and the task | Def field becomes content: stored as string or opaque block, forwarded unchanged. Optionally the worker injects a local prompt when the def carries a placeholder. |
| `ask_human` intercept | Copies `question` into `waiting_for_user`, which the validator requires as a string | `question` accepts string or opaque block; the dashboard and connectors decrypt. |
| `wait` timer result | Writes the literal "Timer completed." as a tool result | Result becomes `{kind: "timer_completed"}` in the envelope; the LLM worker renders it. |
| `run_failed.error` | Tool and LLM error strings pass through as plaintext | `error_class` and `error_code` stay envelope; `error` text becomes content. |
| Validator | `tool_call.arguments` must be a map; `llm_response.content` must be a string | Accept the opaque block shape in every content position. Add a `content_fields/1` list per event type so the rule is data, not convention. |

Things that already comply and should be protected by a test so they stay
that way: idempotency keys are built from run id, step, tool-call id, tool
name, and gard, never from arguments; `side_effecting?/2` reads arguments
only for the built-in `http_request` method; checkpoints store the message
list without inspecting it; fork (Phase F) truncates by step.

### What P0 landed (2026-09-09)

`Norns.Runtime.Content`, `EventValidator.content_fields/1`, the eight fixes,
and `test/norns/runtime/opaque_content_test.exs` — a run whose every content
position is random ciphertext validates, replays, resumes, and completes.
Where the landing differs from the table:

- **Elision moved to the LLM worker, not the tool worker.** The old cap was
  a context-cost policy applied to tool results older than the last two
  turns, not a size limit on what a tool may return. The LLM worker holds
  the plaintext and the same policy (200 chars, then "...(truncated)"), so
  behaviour is unchanged for upgraded workers. Compaction (H2) replaces it.
- **Every result core resolves itself is a kind.** The audit named the
  timer; the same rule covered denied tools, sub-agent outcomes and
  refusals, and `list_agents`. Tenant content on such a result (a child's
  output, a worker's error) stays in `content`; the structure is in
  envelope `data`; `content` is `""` otherwise. `Format.render_message/1`
  is the reference rendering; the Python and Elixir SDKs mirror it.
- **The date joined the summary.** `build_system_prompt/1` also appended
  "Current date: …". Both now ride in the task envelope (`summary`,
  `date`) and the worker composes the prompt.
- **Still plain, still core-written:** `run_failed.error` and
  `retry.error` text, and the registry's `worker disconnected`. They are
  diagnostics with no tenant content; the validator types them as content
  so a worker may send a block, but core keeps writing strings.
- **`runs.output` stays a string column** until E2. A block lands there
  JSON-encoded (`Content.to_column/1`); clients decode.
- **Ingress is still string-only.** The REST message and reply endpoints,
  hook ingest, and the dashboard's send box accept text. Accepting a
  block over the API is E2 work; `Process.send_message/3` and
  `reply_to_human/2` already take either.
- **Older workers degrade, not break.** A pre-0.5 Python worker sends no
  `final_output` (an empty final turn yields empty output), renders no
  kinds (the model sees `""` for a timer or a denial), and gets no date or
  summary line. The one hard break is `launch_agent` with `context.data`,
  which now arrives as a kinded map the old converter cannot send.

---

## Encryption design

Once the principle holds, encryption is a middleware in the SDK and a
decrypt step in the clients. Core changes are limited to the validator
accepting the block shape.

**Unit.** Each content field is encrypted on its own, not the message list
as a whole, so truncation, fork, and checkpoints work on ciphertext.

**Block shape.**

```json
{"$enc": "v1", "kid": "k_7f3a", "n": "<24-byte nonce, base64>", "ct": "<base64>"}
```

A content field holds either a plain string, a plain map (tool arguments
today), or this block. `$enc` is the discriminator; no plain value uses
that key. The validator accepts the block wherever it accepts content.

**Cipher.** XChaCha20-Poly1305 with a random nonce per block, AAD set to
`"norns:" <> version <> ":" <> kid`. AAD deliberately excludes run id and
step: fork copies a parent's blocks into a child run, and a persistent
conversation replays blocks across runs, so binding to a run would break
both. The cost is that an attacker with write access to Postgres could move
a block between runs, which changes what a model reads but reveals
nothing. Acceptable; noted.

**Key.** A 32-byte symmetric key with a short id. Generated by
`nornsctl keys new`, stored in `~/.norns/keys/<kid>` (0600) and referenced
by `NORNS_CONTENT_KEY` in the same env file that already carries the LLM
key, so volund distributes it to workers the way it distributes every other
secret: read from the env file, baked into the container, never written to
Norns. Scope is per agent (or per repo, which for the harness is the same
thing). One key id per run, recorded in the envelope on `run_started`, so
rotation is "new runs use the new key" and old runs stay readable with the
old one. No re-encryption.

**SDK.** A `ContentCipher` the worker is constructed with. Outbound: encrypt
content fields of tool results, LLM responses, and (for the LLM worker) the
`final_output`. Inbound: decrypt messages, system prompt, and tool
arguments before the handler sees them. Built-in tool arguments are
encrypted field by field per rule 3, so the orchestrator can still read
`seconds` and `agent_name`. Handlers never see the cipher. The Elixir SDK
gets the same middleware after Python.

**nornsctl.** Reads the key from the same env or key dir, decrypts on
`runs events`, `runs show`, `conversations show`, and in the chat client.
Encrypts the user message on `agents send` and replies.

**Dashboard.** LiveView renders server-side and the server has no key, so
content on `RunLive`, `AgentLive`, and the conversation views renders
through a browser-side hook: the user pastes the key once, it lives in
`localStorage`, and a JS hook decrypts blocks after patch. Everything on
the envelope (state, step, tool names, spend, timing, fleet view) renders
as today with no key. Without a key the content cells show "encrypted,
kid k_7f3a" and a paste field. This is the largest single piece of the
encryption work.

**Compaction under encryption.** Compaction is an LLM task: core dispatches
"summarise messages 1..N" to the LLM worker, which returns an opaque
summary; core appends `context_compacted` with the step range and the
summary block and writes a new checkpoint. Core never reads either side.
This is also the compaction design without encryption, which is the point
of writing the principle down first.

### Modes, labelled honestly

The key goes wherever a worker runs, because workers produce and consume
plaintext. So the property a tenant gets depends on where they put their
workers, and the product must say which one they have.

| | All workers tenant-run | Some workers in the cloud (P2a) |
|---|---|---|
| LLM key location | Tenant's machine | Cloud secrets context |
| Content key location | Tenant's machine | Cloud secrets context |
| What Norns Postgres holds | Ciphertext and envelope | Ciphertext and envelope |
| What a Norns operator can read | Nothing but the envelope | Plaintext, in memory, on the tenant's machine, during a run |
| Name | **End-to-end encrypted** | **Encrypted at rest with your key** |

The first mode is the harness's default: LLM and tools on the developer's
laptop gard, the cloud holding the log and running the loop. The second is
what "cloud accelerated" means, and it is a real product (the thinking
moves to the cloud, the laptop only needs the tools), but a tenant chooses
it knowingly and the dashboard shows which mode a run is in. We do not
call the second one end-to-end.

### Threat model

Protects against: Norns operators, a Postgres or backup compromise, and any
cloud-side feature reading content without the tenant's key. Does not
protect against: the LLM provider (which sees everything by construction),
a compromised worker or developer machine, or metadata. Metadata leaks are
real and should be stated in the docs: tool names (an `edit_file` is
visibly an edit), ciphertext sizes (roughly, how big a file is), step
timing, agent names, and error classes. File paths are inside arguments
and are therefore content.

Losing the key loses the content. Fleet view, spend, and state survive.
There is no escrow in v1; a team shares the key out of band.

---

## The harness itself

**Worker** (`sleipnir`, new repo, Python SDK): `read_file`,
`write_file`, `edit_file`, `bash`, `grep`, `glob`, registered with
side-effect flags set for the mutating three. Runs on a gard on the
developer's machine, `cwd` the repo. Output truncation, bash timeouts,
and a fuzzy `edit_file` that fails loudly on ambiguous matches. A few
hundred lines; the quality is in the edit tool and the prompts.

**Permissions** live in the worker: an allow list in the harness config,
`ask_human` for anything outside it. That routes to the chat client, the
dashboard, and Slack for free. "Always allow this" is a worker-side
answer that appends to the allow list. The generic orchestrator policy
hook stays in "Not now."

**Compaction** in core as described above, triggered by a `context_policy`
on the def (token threshold from the LLM response usage, which is
envelope). It benefits every long-running agent, not only this one.

**Client**: `nornsctl chat` over the agent channel. A session list down
the side (every conversation across every gard, grouped by repository,
with live status from the envelope: idle, thinking, running `bash`,
waiting for you), tabs to switch between them, and in the pane: streamed
assistant text, tool calls with a one-line summary, permission prompts
inline, `/fork <step>` and `/resume`. Bubble Tea, about a week for
something we would use. Sessions are runs, never shells; nothing here
multiplexes a PTY, which is the multiplexer `plan-coding-agent-runs.md`
rules out. See § What herdr got right.

**Prompts**: a system prompt that reads `AGENTS.md` (via the worker, at
run start, as a tool result, so it is content) and a short instructions
set. Skills are files the worker can read; nothing new in core.

**Resume and fork** on the developer's own gard need no filesystem
snapshot: the working tree is where it was. Git-per-step SHAs from the
coding-agent plan stay the design for fresh-gard resume and become
relevant with managed gards (P2b), not before.

**LLM worker**: the same process, capabilities `[:llm, :tools]`, as the
templates do today. Per-request LLM keys (the parity gap) matter here for
the cloud mode and stay independent.

### What herdr got right, and where it lands (added 2026-09-09)

Three things make herdr popular, and the harness should have all three.
Each lands in a different place:

- **Persistent sessions, across machines.** A session is a Norns
  conversation; its state is the run log, not a process on the laptop.
  Attaching from another machine is the client (H3): open the same
  conversation from anywhere and see the same history and status. The
  *working tree* is on one gard, so a session followed from a second
  machine reads and edits the first machine's checkout. Moving the work
  itself to a new machine is fresh-gard resume (git-per-step SHAs, P2b),
  not H3.
- **Spaces, tabs, agents with status.** `nornsctl chat` grows from
  one-run-one-terminal to the session list above. "Spaces" are gards: a
  gard is a checkout on a machine, and that is what a developer thinks
  of as a place. Status is envelope data, so it works on encrypted
  sessions too.
- **A CLI that configures itself, from within itself.** `sleipnir` gains
  subcommands the agent can run through `bash`: `sleipnir allow
  list|add|remove`, `sleipnir config` (model, max steps, agent name),
  `sleipnir doctor`, and `sleipnir docs`, an AI-facing reference the
  system prompt points at. One rule: changes to the allow list always
  ask, whatever the allow list says, so the agent cannot grant itself
  permissions with a single "always". H1 follow-up, about a day.

### What H1 landed (2026-09-09)

`sleipnir` 0.1.0, in its own repo. Six tools rooted at the repository the
worker starts in; `edit_file` matches exactly, then line-wise ignoring
trailing whitespace and a uniform indent shift, and fails with line
numbers when ambiguous. `bash` kills the process group on timeout and
strips the worker's own credentials from the environment. The allow list
is `.sleipnir/allow` (`tool pattern`, shell commands split into simple
commands that must each match; backticks always ask). The approval loop
is enforced in the worker: a mutating call outside the list returns a
request with a token, the model asks with `ask_human`, and the retry
carries the token. Because the same process serves the run's LLM task,
the worker reads the user's answer from the messages before the retry
arrives, so a retry with no real answer is refused, and "always" appends
rules. The smoke run on a scratch repo exercised every branch: a
question without the token was refused and re-asked, "always" wrote
rules, the edit landed, the tests ran.

Found on the way: the model reaches for `bash cat` before `read_file`
until told otherwise (prompt fixed), and the SDK's 200-char elision of
old tool results is aggressive for a coding session, which is the case
for H2.

## Chains

`plan-chains.md` renders `{{output}}` in core from `run.output`. Under the
principle that is a content read. Two options, choose at chains phase 1:

- **Whole-block templates in core, mixed templates in the worker.** A
  step message that is exactly `{{output}}` or `{{input}}` is a pointer to
  a block, which core forwards opaque. A message with surrounding text
  becomes a `template` kind in the envelope that the LLM worker renders
  after decrypting. Small, and keeps chains usable in both modes.
- **All templating in the worker.** Simpler rule, one more thing the LLM
  worker does.

Either way, the chains plan should not grow a core-side string renderer.

## Drawbacks

- **Encryption makes the dashboard a thick client** for content. A
  browser-side decrypt hook is a new kind of code in a LiveView app and
  needs care around patches and reconnects.
- **Queryable transcripts go away** for encrypted runs. Tool-call
  histograms, cost, and state remain; "which files did it touch" does not.
  That was the observation product; encryption and observation trade off
  and a tenant picks.
- **Any cloud-side agent that reads runs** (the builder, a Slack
  connector) needs the key and so is, in the tenant's terms, a worker they
  chose to trust. The builder's fabricate mode on an encrypted run is a
  cloud-mode feature, not an E2E one.
- **We still do not beat Claude Code on the agent.** The harness is sold
  on the log, resume, fork, and the encryption claim. If the edit tool is
  bad nobody stays long enough to notice the rest.
- **Step latency** is unchanged from the coding-agent plan: hundreds of
  steps, each a round trip through the orchestrator. Encryption adds
  microseconds; the cloud round trip adds tens of milliseconds. Measure
  before calling it fine.

## Sequence and sizing

| Phase | Deliverable | Where | Size |
|---|---|---|---|
| P0 | Opaque-content audit: the eight fixes above, `content_fields/1` in the validator, and a conformance test that replays a run whose content is random bytes | norns | 3 days |
| H1 | `sleipnir` worker: six tools, allow list, `AGENTS.md` on start. Shipped 2026-09-09; self-config CLI follows | new repo | 3 days |
| H2 | Compaction: `context_policy`, `context_compacted` event, LLM-task summarisation | norns + SDK | 4 days |
| H3 | `nornsctl chat`: session list with status across gards, tabs, streaming, permissions inline, `/fork`, `/resume` | nornsctl | 1 week |
| H4 | Dogfood on norns for a week, fix the edit tool, write the README demo | all | 1 week, overlapping |
| E1 | SDK `ContentCipher`, key file, `nornsctl keys new`, built-in argument splitting | SDK + nornsctl | 3 days |
| E2 | Validator accepts the block shape; `run_started` records the kid; mode shown on the run page | norns | 1 day |
| E3 | Browser-side decrypt on `RunLive`, `AgentLive`, conversations | norns | 4 days |
| E4 | Elixir SDK cipher; Slack connector reads the key | SDK + template | 2 days |

P0 goes first and before chains phase 1, whatever happens to the rest:
it is three days, it prevents compaction and chains from growing content
reads, and it costs nothing if encryption never ships. H1 to H4 is the
harness in plaintext, about two and a half weeks, and it is usable and
demoable without E. E1 to E4 is another two weeks and turns the demo into
the claim.

Relative to `plan-coding-agent-runs.md`: Phase F (fork) stays alongside
and is what makes `/fork` in the client work. Phase 0 (CLI as a tool) is
dropped; it becomes a worse version of the same demo. Phase 1 (mirroring)
is deferred until someone asks for a fleet view of agents we do not run.
Phase 2 is this doc.

## What we are not doing

- Searchable encryption, or any analytics on content. Envelope analytics
  only.
- Key escrow, recovery, or per-user keys within a tenant. One key per
  agent, shared out of band, until a team asks for more.
- Encrypting the envelope. Tool names, steps, and usage are the product.
- Multiplexing PTYs. Sessions in the client are Norns runs, never shells.
- Filesystem snapshots. The developer's own gard has the working tree;
  managed gards get SHAs later.
- Encrypting agent defs beyond the system prompt. Names, models, and tool
  lists are configuration, not content.

## Open questions

- **Name.** Resolved for the worker: `sleipnir`, Odin's eight-legged
  horse, free on PyPI. "Cloud accelerated harness" describes the at-rest
  mode; "cloud coordinated" describes the E2E one; the product phrase can
  wait for the README.
- **Def system prompt as content** means the agents list cannot preview
  prompts on an encrypted agent. Placeholder text in the def plus a
  worker-local prompt file may be the better default for the harness
  anyway, since the prompt then lives in the repo.
- **Where the mode is decided.** Per agent (the def says encrypted, core
  refuses plaintext content on it) or per worker (whoever holds a key
  encrypts)? Per agent is easier to reason about and to show in the UI;
  per worker is one less field. Leaning per agent.
- **`user_response` and `agents send` from third parties.** A webhook
  payload arrives in plaintext at the ingest endpoint. Under E2E the hook
  ingest cannot encrypt it, so hooks on an encrypted agent either carry
  content the sender already encrypted or are refused. Decide at E2.
