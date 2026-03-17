# Automaton

## Project Overview

Agent builder web app. Users build, test, debug, and interact with AI agents through a chat interface.

## Tech Stack

- **Backend/Frontend:** Elixir, Phoenix LiveView
- **Database:** PostgreSQL
- **Styling:** Tailwind CSS (Phoenix default)

## Conventions

- Follow standard Phoenix project conventions
- Use LiveView for all interactive UI — no separate frontend framework
- Keep contexts (Ecto schemas + business logic) in `lib/automaton/`
- Keep web layer (controllers, live views, components) in `lib/automaton_web/`
