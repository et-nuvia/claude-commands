# Worktrees and Docker Isolation

Worktrees are the default form of task isolation in this repo.
[`/task-start`](commands/task-start.md) runs
`git worktree add .worktrees/<task_id>` rather than `git checkout -b`, so
several tasks coexist on disk and nothing has to be stashed to look at
something else.

That is a straightforward win — until the project also uses Docker, at
which point an unconfigured worktree will quietly run your commands
against the wrong checkout. This page covers both halves: working in a
worktree, and making Docker respect the boundary.

## Branch mode is not deprecated

Both modes are permanent, first-class citizens. `--no-worktree` gives you
plain branch mode, and the scripts detect which one they're in via
`is_in_worktree()` and adapt. `.worktrees/` is gitignored globally and
per-repo. Standard `git worktree` commands behave identically on macOS and
on WSL/Debian.

Use branch mode when the task is a five-minute fix. Use a worktree when
you'll be switching between this and something else.

## Working inside a worktree without fighting the tool

The Bash tool's working directory **persists between calls**, and `cd`
chained with a pipe or redirect is hard-blocked as a path-resolution
bypass. Those two facts together dictate the whole workflow:

- **`cd` into the worktree exactly once**, as its own standalone command
  with no `&&`, `;`, pipe, or redirect. Every later command inherits it.
- **Never** write `cd .worktrees/<id> && make …`, and never follow a `cd`
  with a redirect. That's the blocked pattern, and no allowlist entry can
  approve it.
- To target a worktree **from somewhere else in a single call**, use path
  flags instead of `cd`: `make -C <worktree> <target>`,
  `git -C <worktree> <subcommand>`,
  `task-continue.sh --dir <worktree>`. These are single non-compound
  commands and auto-approve.
- **If you're unsure whether you already `cd`'d, don't re-`cd` "to be
  safe"** — use a path flag. Transcript analysis found the same worktree
  `cd`'d over 100 times in one long session; every defensive re-`cd` is a
  wasted round-trip that buys nothing.
- Prefer **absolute paths** in Read/Grep/Glob. Those tools take a path
  argument, so file inspection never needs a `cd` at all.

## Why Docker needs configuring

Compose derives its project name from the working directory. A git
worktree therefore **silently shares one stack with the primary
checkout** unless `COMPOSE_PROJECT_NAME` is set.

The failure mode is silent and expensive: `make migrate` inside a worktree
runs against the *other* checkout's bind-mounted source, reports "No
migrations are pending", and the tables it was supposed to create simply
don't exist. Nothing errors. You find out later, somewhere else.

> **This isolation is required, not optional, for any project combining
> worktrees and Docker.** The full pattern lives in the
> `worktree-docker-isolation` skill; what follows is the shape of it.

### The pattern

**Name the project per worktree.** A `scripts/compose-project-name.sh`
prints `<project>` for the primary checkout and
`<project>-<cksum-of-abs-path>` for a linked one — detect the difference
with `git rev-parse --git-dir` versus `--git-common-dir`. Compose project
names must be **lowercase**, so a worktree id like `92E0E1` is rejected
outright; hashing sidesteps that.

**Export it once, at Makefile parse time**, so every `docker compose` call
site inherits it with no per-call edits. Guard with `$(origin …)` so an
explicit caller choice still wins.

**Neutralise host ports**, or two stacks collide on the same port.
Compose **concatenates** `ports` across files rather than replacing them,
so the only thing that actually drops them is `ports: !reset []` in an
extra generated (gitignored) layer.

**Beware `COMPOSE_FILE`.** Setting it — like passing an explicit `-f` —
*replaces* compose's automatic file discovery. It must then name the base
file *and* every override explicitly, or the tracked override silently
stops loading and the stack comes up in production shape with no
bind-mounts.

**Provide `make worktree-clean`** that removes only that worktree's
containers, volumes, and per-worktree test images. It must **never** pass
`--rmi`: destroying the shared layer cache forces every other checkout
into a cold rebuild. Call it from [`/task-close`](commands/task-close.md),
and keep a separate, deliberate `make clean` for image and cache removal.

## Test images are the target's job

**Call `make test-<service>-<type>`, `lint-*`, or `typecheck-*` — and
nothing else.** Do not hand-roll `docker build`, `docker run`, or image
cleanup for a worktree. Those targets already detect the worktree, build
only when the *baked* inputs changed, and reclaim their own dangling and
orphaned images.

If a target doesn't yet do this, add the prelude rather than scripting
around it:

```makefile
test-unit:
	@../scripts/test-image.sh ensure backend
	@../scripts/run-jest.sh --target test-backend-unit $(_SCRIPT_FLAGS)
```

`scripts/test-image.sh` has three subcommands: `name <service>` (the
per-worktree tag), `ensure <service>` (stamp-check baked inputs → build
with labels if stale → GC), and `gc [--worktree <id>|--orphans|--all]`.

**Tags address, labels reclaim.** Images are labelled at build time with
`tim.repo`, `tim.service`, and `tim.worktree` (`main` for the primary
checkout). Labels survive tag reuse, which is what makes cleanup
reliable — a reused per-worktree tag leaves *dangling images*, not extra
tags, so ten rebuilds means one tag and nine untagged. Retention is a
label-filtered prune, not tag bookkeeping. Service names come from
`PROJECT.yaml` `components[].path`, never a hardcoded list, so the helper
is identical across projects.

The orphan sweep — `docker rmi` on any image whose `tim.worktree` is
absent from `git worktree list --porcelain` — is what makes worktree
removal self-healing without needing a git hook.

**Guardrails:**

- Never `docker builder prune`. It's the shared layer cache; you'd
  cold-rebuild every checkout.
- Never touch an unlabeled image. The label filter *is* the safety
  boundary.
- GC failure warns on stderr and never fails the target. `TEST_IMAGE_GC=0`
  disables it entirely.

**Honest accounting:** duplicate DB volumes and unused services cost
roughly 2 GiB per worktree, which outweighs dangling images considerably.
Do image GC because it's cheap, not because it's the biggest win.

## Staleness: what actually needs a rebuild

If the test runner bind-mounts `src`, source edits are picked up without a
rebuild. Treating `src` as a staleness input forces a multi-minute rebuild
on nearly every edit. Restrict staleness to genuinely **baked** inputs:
`package*.json`, `tsconfig*`, jest config, the Dockerfile.

One catch worth knowing before you make that change: **ts-jest with
`isolatedModules` never type-checks.** If an image rebuild was doubling as
your compile gate, removing it means a branch whose TypeScript doesn't
compile now reports a green test run. Replace the gate explicitly — run
`tsc --noEmit` over the bind-mounted `src` in parallel with the tests and
fail on error.

## Provisioning cost

A full migration run against a blank database is slow — one measured case
was 387s for 125 migrations — and every new worktree pays it. Cache a
`mysqldump` outside every worktree (`~/.cache/<project>/`), keyed by the
git **tree** hash of the migrations directory on the default branch plus
the seed blob hash, so it self-invalidates.

> **Only build a baseline from a checkout whose migrations match the
> default branch exactly.** A dump carries the `migrations` table with it,
> so a baseline built on a branch with private migrations marks them
> applied and ships their tables into every worktree that restores it.

## IDE excludes

Stop your editor from indexing every worktree as separate source:

- **VS Code** — `.vscode/settings.json`:
  `{ "search.exclude": { ".worktrees": true }, "files.watcherExclude": { ".worktrees/**": true } }`
- **JetBrains** — add `.worktrees/` to `.idea/.gitignore`

---

**See also:** [Skills and Subagents](11-skills-and-subagents) ·
[Workflows](08-workflows) · [`/task-start`](commands/task-start.md) ·
[`/task-close`](commands/task-close.md)
