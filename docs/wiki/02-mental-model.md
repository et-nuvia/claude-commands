# Mental Model

This repo is **four layers**. Understanding the layering is the difference
between using it and fighting it.

```
┌──────────────────────────────────────────────────────────────┐
│  COMMANDS  (commands/*.md)                                   │
│  Thin workflow descriptions Claude reads when you type /foo. │
│  Almost no logic. Mostly: "run script X, then format output  │
│  per docs/reference/ux/Y.md."                                │
└────────────────────────────┬─────────────────────────────────┘
                             │ invokes
┌────────────────────────────▼─────────────────────────────────┐
│  SCRIPTS  (scripts/*.sh, *.py)                               │
│  The actual logic. Read PROJECT.yaml + profile, do work,     │
│  emit JSON with a `next_action` directive telling the        │
│  command what to do next.                                    │
└────────────────────────────┬─────────────────────────────────┘
                             │ read
┌────────────────────────────▼─────────────────────────────────┐
│  TEMPLATES  (templates/)        PROFILES  (profiles/)        │
│  Per-project contracts:         Per-machine config:          │
│  - PROJECT.yaml                 - active.yaml (gitignored)   │
│  - PROJECT-KNOWLEDGE.md         - registry hosts, tokens,    │
│  - task-*.md (V4 doc types)       task backend, etc.         │
│  - scaffold trees                                            │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  REFERENCE DOCS  (docs/reference/)                           │
│  Linked from commands at runtime. Defines output formatting  │
│  (commit confirmation, progress updates, errors), authoring  │
│  rules, and tech-stack standards (docker, makefile,          │
│  testing, pipelines).                                        │
└──────────────────────────────────────────────────────────────┘
```

## Why this split

**Commands stay thin** so they're easy to read and edit. A command file is
mostly prose telling Claude what workflow to follow. The real work is in
scripts, which are testable, version-controllable, and shellcheck-able.

**Scripts return `next_action`** so commands don't need branching logic.
A script can say "the user has uncommitted changes, ask them to stash" and
the command just renders that prompt. No `case` statements in commands.

**Templates separate "what a project should look like" from "what this
project happens to look like."** Scaffolding stamps templates into new
projects. PROJECT.yaml is the single source of truth for per-project config.

**Profiles separate "what a machine knows" from "what a script does."**
Same script runs on work and home machines — values differ because the
active profile differs. No `if [[ uname == Darwin ]]` in business logic.

## Reading order when something breaks

1. Read the **command** (`commands/foo.md`) to see what workflow it describes
2. Read the **script** it calls (`scripts/foo.sh`) for actual behavior
3. Check the **profile** (`~/.claude/profiles/active.yaml`) and the project's
   **PROJECT.yaml** for config values
4. Check **docs/reference/** for the formatting/standards the command links to

## What lives where — examples

- `/git-commit` → `commands/git-commit.md` → `scripts/git-commit.sh` →
  reads profile for `identity.email`, formats output per
  `docs/reference/ux/commit-confirmation.md`
- `/task-start` → `commands/task-start.md` → `scripts/task-start.sh` →
  reads `PROJECT.yaml` for task backend, profile for tokens, stamps
  `templates/task-TSK.md` into the new task doc
- `/scaffold` → `commands/scaffold.md` → `scripts/scaffold.sh` →
  copies from `templates/python-project/` or `templates/nextjs-project/`
