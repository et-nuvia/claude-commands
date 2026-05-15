---
name: add-dependency
description: Add a new dependency with automated license and security verification
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "add-dependency" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "add-dependency" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Add a new dependency safely by running license validation, security scanning, and installation.

## Execute

```bash
~/.claude/scripts/add-dependency.sh --full --package "package-name"
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**display_summary** — Dependency added successfully. Report: package name, version, dependency_type, is_dev. Tell the user to document the dependency in README or DEPENDENCIES.md and commit the lock file changes.

**find_alternative** — Blocked by license or security. Report the blocking reason (forbidden license or CRITICAL/HIGH vulnerabilities). Tell the user to find an alternative package with a permissive license (MIT, Apache, BSD) or without critical vulnerabilities.

**review_and_decide** — Warning status. Report the concern (unknown license or MEDIUM vulnerabilities). Ask the user whether to proceed. If they approve, re-run the relevant section:
- Unknown license: `~/.claude/scripts/add-dependency.sh --json --security --package "package-name"`
- Medium vulnerabilities: `~/.claude/scripts/add-dependency.sh --json --add --package "package-name"`

**fix_error** — Script failed. Report the error message and details. Try the debug block below.

## Section Flags

Run individual sections when needed:
- `--validate` — License check only
- `--security` — License + security scan
- `--add` — Skip checks, just install
- `--verify` — Pin version only

Options: `--dev`, `--python`, `--nodejs`

## Debug

```bash
~/.claude/scripts/add-dependency.sh --raw --validate --package "package-name"
~/.claude/scripts/add-dependency.sh --raw --security --package "package-name"
~/.claude/scripts/add-dependency.sh --raw --add --package "package-name"
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "add-dependency" --event complete \
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
