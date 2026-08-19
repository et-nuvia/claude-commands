---
name: cicd-reference
description: CI/CD pipeline stage flows, the ~/.claude/scripts pipeline and deployment script catalogs, and docker-exec usage. Load when setting up or debugging a CI/CD pipeline, checking pipeline status/logs/jobs, running a deployment script, or wiring docker exec into a Makefile.
---

# CI/CD Reference

Platforms, registries, and deploy methods: see the Environment Detection table in the global CLAUDE.md.

## Pipeline principles

- **Build once, deploy many** — staging images promoted (re-tagged) to production
- **Auto-rollback** on production smoke-test failure · `PUSH_IMAGES` toggle for dry runs
- Modular reusable workflows (GitHub) / templates (GitLab) · auto-detect platform from git remote

## Stage flows

Branches configured in PROJECT.yaml:

| Branch | Flow |
|---|---|
| other branches | `Lint → Test` |
| staging | `Lint → Test → Security → Build → Deploy → Smoke → Cleanup → E2E → Notify` |
| production | `Lint → Test → Security → Promote → Deploy → Smoke → Rollback(on failure) → Cleanup → Notify` |

Skills: `/pipeline-setup`, `/deployment-config`

**See**: [CI/CD Pipeline Guide](docs/pipelines.md)

## Pipeline Scripts (`~/.claude/scripts/`)

GitHub + GitLab; platform auto-detected from PROJECT.yaml `git:` block.

- `pipeline-status.sh [--pipeline-id <id>]` — status (~50 tokens)
- `pipeline-watch.sh [--pipeline-id <id>] [--interval <s>]` — watch to completion, no prompts
- `pipeline-jobs.sh [--pipeline-id <id>]` — list jobs
- `pipeline-logs.sh --job-id <id> [--lines <n>]` — job logs

Use these instead of manual curl/API calls or bash polling loops (which require approval); only fetch logs for failed jobs.

**See**: [Git Platform Integration](docs/reference/git-platforms.md)

## Deployment Scripts (`~/.claude/scripts/`)

JSON output; auto-detect branches/CI platform when PROJECT.yaml missing; optional checks skip gracefully.

`deployment-config.sh` · `validate-git-state.sh` · `git-branch-check.sh` · `analyze-deployment-risk.sh` (code-aware scoring) · `git-merge.sh` (squash/regular + conflict handling) · `deployment-rollback.sh` (revert commits) · `monitor-pipeline.sh` · `check-health.sh` · `check-deployed-version.sh` · `run-e2e-tests.sh` · `smoke-tests.sh` (critical + extended)

**See**: [Deployment Scripts Guide](scripts/DEPLOYMENT_SCRIPTS.md)

## Docker Exec

`~/.claude/scripts/docker-exec.sh -s <service> [-- cmd...]` — resolves container (explicit `container_name` → `docker compose ps` → auto-generated pattern), auto-starts the service if down. Use in Makefiles instead of hardcoding `docker compose exec <service>`.

**See**: [Docker Exec Reference](docs/reference/docker-exec.md)

## CI/Docker change gate

**BEFORE** pushing CI or Docker changes, run `~/.claude/scripts/ci-lint-local.sh --json --full` and fix all issues — do NOT use the remote pipeline as your linter.
