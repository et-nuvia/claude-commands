---
name: worktree-docker-isolation
description: The per-worktree Docker isolation pattern (COMPOSE_PROJECT_NAME, ports !reset, worktree-clean, DB baseline caching, test-image staleness). Load when a project uses git worktrees together with Docker, or when worktree stacks collide, share containers, or migrations run against the wrong checkout.
---

# Per-worktree Docker isolation

**Required whenever a project combines git worktrees with Docker.**

Compose derives its project name from the working directory, so **a git worktree silently shares ONE stack with the primary checkout unless `COMPOSE_PROJECT_NAME` is set**. The failure mode is silent and expensive: `make migrate` in a worktree runs against the *other* checkout's bind-mounted source, reports "No migrations are pending", and the tables it should have created do not exist.

## The pattern (port it when a project has worktrees + Docker)

- A `scripts/compose-project-name.sh` prints `<project>` for the primary checkout and `<project>-<cksum of abs path>` for a linked worktree (detect via `git rev-parse --git-dir` vs `--git-common-dir`). **Compose project names must be lowercase** — a worktree id like `92E0E1` is rejected outright, hence hashing.
- The Makefile `export`s `COMPOSE_PROJECT_NAME` **once at parse time**, so all `docker compose` call sites inherit it with no per-call edits. Guard with `$(origin ...)` so an explicit caller choice survives.
- Host ports must be neutralised per worktree or stacks collide. **Compose *concatenates* `ports` across files rather than replacing them** — `ports: !reset []` in an extra generated (gitignored) layer is the only way to drop them.
- **Setting `COMPOSE_FILE`, like passing an explicit `-f`, REPLACES compose's automatic file discovery** — it must then name the base *and* every override explicitly or the tracked override silently stops loading and the stack comes up in prod shape with no bind-mounts.
- Provide a **`make worktree-clean`** that removes only that worktree's containers, volumes and per-worktree test images, and **never** passes `--rmi` (destroying shared layer cache forces every other checkout into a cold rebuild). Call it from `/task-close`. Keep a separate deliberate `make clean` for image/cache removal.

## Test-image lifecycle is the target's job (never hand-roll docker)

**Call `make test-<service>-<type>` / `lint-*` / `typecheck-*` and nothing else.** Do NOT write your own `docker build` / `docker run` for a worktree — the target owns build-if-stale and reclaim. If a target does not yet do this, add the prelude rather than working around it:

```makefile
test-unit:
	@../scripts/test-image.sh ensure backend
	@../scripts/run-jest.sh --target test-backend-unit $(_SCRIPT_FLAGS)
```

`scripts/test-image.sh` has three subcommands: `name <service>` (per-worktree tag), `ensure <service>` (stamp-check baked inputs → build with labels if stale → GC), `gc [--worktree <id>|--orphans|--all]`.

- **Label at build time**: `tim.repo=<project>` (PROJECT.yaml), `tim.service=<service>`, `tim.worktree=<cksum>` (`main` for the primary checkout). Tags address, labels reclaim — labels survive tag reuse. Service names come from PROJECT.yaml `components[].path`, never a hardcoded list, so the helper is identical across projects.
- **GC only after a build** (a warm stamp does no extra work), two bounded sweeps: label-filtered `docker image prune` for this worktree's dangling layers, then an orphan sweep `docker rmi`ing any image whose `tim.worktree` is absent from `git worktree list --porcelain`. The orphan sweep makes worktree removal self-healing without a git hook.
- **A reused per-worktree tag leaves dangling images, not extra tags** — ten rebuilds = one tag + nine untagged. Retention is a label-filtered prune, not tag bookkeeping. `TEST_IMAGE_KEEP` defaults to `1`; `N>1` is rarely useful since superseded images have no tag.
- **Guardrails**: never `docker builder prune` (shared layer cache — cold-rebuilds every checkout); never touch an unlabeled image (the label filter is the whole safety boundary); GC failure warns on stderr and never fails the target. `TEST_IMAGE_GC=0` disables.
- Disk-cost honesty: duplicate DB volumes and unused services (~2.0 GiB/worktree) both outweigh dangling images. Do image GC because it is cheap, not because it is the biggest win.

## Test-image staleness

If the test runner bind-mounts `src`, source edits are picked up without a rebuild — treating `src` as staleness forces a multi-minute rebuild on nearly every edit. Restrict staleness to genuinely *baked* inputs (`package*.json`, `tsconfig*`, jest config, Dockerfile).

But note **ts-jest with `isolatedModules` never type-checks**, so if an image rebuild was doubling as the compile gate, replace it explicitly — run `tsc --noEmit` over the bind-mounted src in parallel with the tests and fail on error. Otherwise a branch whose TypeScript does not compile reports a green test run.

## Provisioning cost

A full migration run against a blank DB is slow (measured 387s / 125 migrations on a real project) and every new worktree pays it. Cache a `mysqldump` outside every worktree (`~/.cache/<project>/`), keyed by the git **tree** hash of the migrations dir on the default branch plus the seed blob hash, so it self-invalidates.

**Only create a baseline from a checkout whose migrations match the default branch exactly** — a dump carries the `migrations` table, so one built on a branch with private migrations marks them applied and ships their tables into every worktree that restores it.

## IDE excludes for `.worktrees/`

- VS Code — `.vscode/settings.json`: `{ "search.exclude": { ".worktrees": true }, "files.watcherExclude": { ".worktrees/**": true } }`
- JetBrains — add `.worktrees/` to `.idea/.gitignore`
