---
command: understand
group: knowledge-graph
backing_script: prompt-only
mutates: []
runtime: ~30s-5min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /understand

Builds an on-demand mental model of the application: architecture, patterns, entry points, data flow, integrations. For large codebases (>50 files, multi-service) it dispatches parallel `Explore` subagents partitioned by layer (structure, data, API); for small codebases it explores directly with native tools. No artifact is written — the output is a summary printed to the user.

> **Config:** none. This is a pure prompt command; it doesn't read `PROJECT.yaml`, `PROJECT-KNOWLEDGE.md`, or `.understand/graph.json`.

> **Related:** for a persistent, queryable graph use `/understand-scan` (build) + `/understand-explore` (query). `/understand` is the lightweight ad-hoc cousin — use it when you don't want to commit a graph file or pay for the full scan pipeline.

---

## When to use it

- First time looking at an unfamiliar repo and you want a quick mental model
- Onboarding handoff — a teammate asks "how does this thing work?"
- You want a one-shot overview without committing a `.understand/graph.json`

## Usage

```bash
/understand
```

**Common invocations:**

```bash
/understand                      # default: explore + summarize
```

## Arguments

None — invoke with no input.

## Dependencies

**External commands / packages** (must be on `PATH`):

None — the command uses only Claude Code's native tools (Glob, Grep, Read, Agent).

**Project files consumed:**

- Whatever's in the working directory. No required config files.

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Size the codebase** — Glob the tree to decide between parallel-subagent mode (large) and direct mode (small).
2. **Large codebase: parallel `Explore` dispatch** — three subagents (`model: sonnet`) in a single message:
   - Project structure / tech stack / entry points / build system
   - Data layer (DB, models, migrations, repositories, query patterns)
   - API/service layer (routes, controllers, middleware, integrations, auth)
3. **Small codebase: direct exploration** — Glob layout, Read entry points + configs, Grep for tech patterns.
4. **Pattern recognition** — naming conventions, error handling, auth/authz, state management, communication patterns.
5. **Dependency mapping** — internal module dependencies, external libs, service integrations, DB relationships.
6. **Synthesize and present** — architecture diagram (text), component map, data flow, key patterns, tech stack summary, dev workflow. Escalate to `model: opus` only when synthesis across 3+ services genuinely needs deeper reasoning.

## Example workflows

### Scenario: New-repo onboarding

```
/understand                     # mental model
/understand-scan                # if you want the queryable graph too
```

```
PROJECT OVERVIEW
├── Architecture: layered monolith (FastAPI + React)
├── Main Technologies: Python 3.14, FastAPI, SQLAlchemy, React 19, Vite
├── Key Patterns: repository pattern, JWT auth, event bus for notifications
└── Entry Point: backend/app/main.py

COMPONENT MAP
├── Frontend (frontend/src/)
│   └── pages/, components/, lib/api/
├── Backend (backend/app/)
│   └── routers/, services/, repositories/, models/
├── Database
│   └── Postgres via SQLAlchemy 2.x, alembic migrations
└── Tests
    └── pytest (backend), Vitest + Playwright (frontend)

KEY INSIGHTS
- Auth lives entirely in middleware/auth.py; routers are auth-agnostic
- Notifications fan out via app/events/ — adding a channel = new subscriber
- frontend/lib/api/ is the single API client; no direct fetch elsewhere
```

## Notes & gotchas

- **Ad-hoc, not persistent** — `/understand` summaries are printed and gone. For a graph you can query later, use `/understand-scan`.
- **Cost** — large codebases with 3 parallel subagents typically cost a few cents (sonnet); escalate to opus only when synthesis demands it.
- **Re-read budget** — if you're calling `/understand` more than once a week on the same repo, you're better off committing a graph via `/understand-scan` and using `/understand-explore --search` / `--node` for targeted lookups.
- **If it fails:** there's no script to debug — failures here mean a subagent ran out of context. Narrow the scope manually (e.g., `cd` into a subdirectory) and rerun.
