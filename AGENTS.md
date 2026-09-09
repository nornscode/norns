# Norns

Notes for coding agents working in this repo.

## Conventions

Project conventions, architecture, and the directory layout live in [CLAUDE.md](CLAUDE.md). Read it first; everything there applies here too.

## Running tests

All mix commands run inside Docker Compose:

```bash
docker compose run --rm -e POSTGRES_HOST=db app mix test
```

## Design docs

`docs/` holds the plans and decisions. Start with [docs/roadmap.md](docs/roadmap.md) for sequencing and [docs/decision-log.md](docs/decision-log.md) for what's built and why.
