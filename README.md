# Automaton

A chat-first platform for building and running **AI-enabled workflows**.

Automaton combines deterministic workflow backbones with agentic reasoning loops so teams can build, operate, and audit reliable AI systems — not just prompt wrappers.

## Core Runtime Ideas

- Agents are durable workflows with explicit lifecycle (`inactive`, `idle`, `running`)
- Signals and queries support interactive, stateful runs
- Deterministic gates enforce policy and safety before action
- Every run is replayable and version-pinned (agent, policy, prompt)

## Tech Stack (implementation detail)

- Elixir / Phoenix LiveView
- PostgreSQL
- Oban (background jobs and scheduling)
- Tailwind CSS
