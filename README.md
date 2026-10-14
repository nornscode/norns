<p align="center">
  <img src="images/norns-logo-simple.png" alt="Norns" width="80" />
</p>

<h1 align="center">Norns</h1>

<p align="center">
  <a href="https://github.com/nornscode/norns/actions/workflows/ci.yml"><img src="https://github.com/nornscode/norns/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://elixir-lang.org/"><img src="https://img.shields.io/badge/elixir-1.18-purple.svg" alt="Elixir" /></a>
</p>

<p align="center">Agents that work while you're away.</p>

Norns runs agents that are on their own for days. They start from a cron schedule or a webhook, ask a person in Slack when they need a decision, hand jobs to other agents, and carry on through deploys and crashes. The run lives in Postgres rather than in a process, so losing the process costs you nothing.

The one I run every weekday morning goes like this. A trigger starts the steward. It reads the open issues and recent commits across a few repos and picks something worth doing today. It calls `ask_human` with a one-line proposal and the run parks; no process is waiting on it. A couple of hours later I see the question in Slack and reply "go". The run wakes up, calls `launch_agent`, and a coding agent picks the job up on a worker that has the repo checked out. The steward waits on the child, and when the coder opens a PR the steward posts the link and finishes.

For the two hours between the question and the answer, the steward was a row in a table. Deploy Norns in that window, restart every worker, and the reply still lands on the right run. Every step is in the event log, so if I want to know why it picked that issue, I can look.

- **A run can wait for a person for as long as that takes.** `ask_human` parks the run until a reply comes in through the API. `wait` sleeps without holding a process open. The Slack bridge in Mimir only carries messages; Norns holds the wait.
- **A run can hand work to another agent.** `launch_agent` starts a child run and waits for it. Parent and child are linked in the log, and a parent that crashes while waiting reattaches to its child instead of launching a second one.
- **Nothing has to be awake to start a run.** Cron triggers and inbound webhooks live in Norns tables, not in a worker.
- **A coding agent gets a machine of its own.** A [gard](docs/gards.md) pins a run's tool calls to one worker, so `read_file` and `bash` land on the same checkout every time.
- **A deploy or an eviction doesn't kill the run.** The next worker to connect replays the event log and continues from the last finished step. Tools that already ran are skipped, so resuming never sends the same email twice.
- **Agents are configuration.** Workers bring tools; an agent is a prompt, a model, a tool allowlist and a trigger. Once a Slack worker and a database worker are running, a new agent is an API call.

https://github.com/user-attachments/assets/b300b164-dc0c-44ea-a794-1de00b4f01a7

<p align="center"><sub>An agent calls <code>wait</code> (10s), then <code>say_hello</code>. I kill the worker twice mid-run. Each time a new worker connects and carries the run on from the event log. It resumes rather than restarting: steps that already finished are not run again.</sub></p>

## Get started

```bash
brew install nornscode/tap/nornsctl
nornsctl dev
nornsctl new my-agent
cd my-agent
uv sync
uv run my-agent-worker
```

That gives you a Norns server and a worker connected to it. The [hello agent](https://github.com/nornscode/norns-hello-agent) walks through the rest.

## How it works

Norns is an orchestrator written in Elixir on the BEAM. It never calls a model and never runs a tool. It holds the state of every run, decides what happens next, and hands the work to workers. Postgres is the only thing you run besides Norns. Background jobs go through Oban on the same database, and there is no Redis or message broker.

Workers connect over WebSocket, register their tools, and hold the API keys. There's usually more than one. Each worker brings its own set of tools (a Slack worker, a database worker, one that wraps your internal API), and the agent sees the union of everything connected. The orchestrator routes each tool call to a worker that registered that tool. If no worker is connected, tasks queue until one shows up. If a worker dies mid-task, the orchestrator notices and puts the task back in the queue.

```mermaid
sequenceDiagram
    participant O as Orchestrator
    participant A as Worker A<br/>llm, search_docs
    participant B as Worker B<br/>post_to_slack
    O->>A: llm_task
    Note right of A: calls Claude/GPT/etc
    A-->>O: response with tool calls
    O->>A: tool_task: search_docs
    A-->>O: result
    O->>B: tool_task: post_to_slack
    B-->>O: result
    Note over O,B: checkpoint, repeat
```

Every LLM call, tool call and tool result is an event in a Postgres log. The log is the run: a worker that picks a run up after a crash replays it to find out where things stand.

Side-effecting tools get a deterministic idempotency key derived from the run ID, step number and tool call ID. On replay, if a result already exists for that key, the tool is skipped. That's what keeps a resumed run from sending the same email twice.

Errors get classified, because retrying everything is as wrong as retrying nothing:

- Transient failures (timeouts, worker disconnects, upstream outages) get a few retries with exponential backoff.
- Rate limits get patient retries with linear backoff. The dependency is fine, you just have to wait.
- Validation and policy errors are terminal. Retrying won't fix a bad input.

The wire format is provider-neutral. Workers translate to whatever model API they use, and the keys never leave them.

## SDKs and examples

- [Python SDK](https://github.com/nornscode/norns-sdk-python) — `pip install norns-sdk` ([PyPI](https://pypi.org/project/norns-sdk/))
- [Elixir SDK](https://github.com/nornscode/norns-sdk-elixir) — `{:norns_sdk, "~> 0.1"}` ([Hex](https://hex.pm/packages/norns_sdk))
- [CLI (`nornsctl`)](https://github.com/nornscode/nornsctl)
- [Hello example](https://github.com/nornscode/norns-hello-agent)
- [Mimir](https://github.com/nornscode/norns-mimir-agent) — a Slack knowledge bot, and the steward loop from the top of this page
- [Sleipnir](https://github.com/nornscode/sleipnir) — a coding worker; the agent the steward hands off to

### Worker

```python
from norns import Norns, Agent, tool

@tool
def search_docs(query: str) -> str:
    return "..."

agent = Agent(
    name="support-bot",
    model="claude-sonnet-5",
    system_prompt="You are a support assistant.",
    tools=[search_docs],
)

norns = Norns("http://localhost:4000", api_key="nrn_...")
norns.run(agent)
```

### Client

```python
from norns import NornsClient

client = NornsClient("http://localhost:4000", api_key="nrn_...")
result = client.send_message("support-bot", "Where is my order?", wait=True)
print(result.output)
```

## Status

Norns is v0.x. I run Mimir and the steward on it and it holds up, but the APIs are still moving. Breaking changes get called out in release notes, so pin versions. Hit a bug or some jank? [Open an issue](https://github.com/nornscode/norns/issues).

Where it's going, and why some things aren't being built, is in [docs/roadmap.md](docs/roadmap.md) and [docs/decision-log.md](docs/decision-log.md).

## License

MIT
