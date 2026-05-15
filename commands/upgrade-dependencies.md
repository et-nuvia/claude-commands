---
name: upgrade-dependencies
description: Upgrade all dependencies to their latest compatible versions
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "upgrade-dependencies" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "upgrade-dependencies" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Upgrade Python and/or Node.js dependencies to their latest compatible versions. Strategy: remove pins, resolve latest compatible set, test, security scan, then re-pin working versions.

## Execute

```bash
~/.claude/scripts/upgrade-dependencies.sh --full
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**edit_dependency_files** — Manual edit required. Read `section` to know which file and what to do:

- `python`: Remove version pins from `pyproject.toml` (keep lines with `# PINNED:` comment). Then: `~/.claude/scripts/upgrade-dependencies.sh --json --python-resolve`
- `python-versions`: Read `details.packages` and pin exact versions in `pyproject.toml`. Then verify: `docker compose run --rm app uv sync --frozen`
- `nodejs`: Set all deps to `"latest"` in `package.json` (keep forced pins). Then: `~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-resolve`
- `nodejs-versions`: Read `details.packages` and pin exact versions (no `^` or `~`) in `package.json`. Then: `docker compose run --rm frontend npm install && npm ci`
- `*-security`: Security vulnerabilities found. Report count and severity. Ask user: find alternative, accept risk, or pin previous version. Document any forced pins with `# PINNED: reason`.

**continue_upgrade_pipeline** — Step succeeded. Read `section` and run the next step:
- `python-resolve` → `~/.claude/scripts/upgrade-dependencies.sh --json --python-test`
- `python-test` → `~/.claude/scripts/upgrade-dependencies.sh --json --python-security`
- `python-security` → `~/.claude/scripts/upgrade-dependencies.sh --json --python-versions`
- `nodejs-resolve` → `~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-test`
- `nodejs-test` → `~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-security`
- `nodejs-security` → `~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-versions`

**fix_error** — Build/test/resolve failed. Read `details.log` for the error. Identify incompatible package, pin it with a `# PINNED:` comment, and restart resolution.

## Section Flags

`--python`, `--nodejs`, `--python-resolve`, `--python-test`, `--python-security`, `--python-versions`, `--nodejs-resolve`, `--nodejs-test`, `--nodejs-security`, `--nodejs-versions`

## Debug

```bash
~/.claude/scripts/upgrade-dependencies.sh --raw --python
~/.claude/scripts/upgrade-dependencies.sh --raw --nodejs
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "upgrade-dependencies" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
