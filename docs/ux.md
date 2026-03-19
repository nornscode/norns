# UX Design

**Status: Not yet implemented.**

## Core Concept

The primary interface is a chat-based workflow builder. Users describe what they want; the system generates and deploys workflow code.

## Chat Builder (the product)

The chat interface is where workflows are created:

- "Make an agent that summarizes open PRs every morning and posts to Slack"
- "Add a step that checks for security vulnerabilities before posting"
- "Change it to run at 8am instead of 9am"

The builder LLM translates these into Elixir workflow modules, wires up triggers and integrations, and deploys them. The user doesn't need to write code.

## Agent Management

A web UI for viewing and managing what the builder creates:

- View agent status (inactive / idle / running)
- View run history and step-by-step event logs
- Edit name, purpose, trigger schedule
- Start / stop agents
- View and edit the generated workflow code directly

## Visual Language

- Monochrome base with minimal accent colors for status indicators
- Clean typography, generous whitespace
- Blueprint aesthetic — subtle grid influence
