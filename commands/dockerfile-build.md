---
name: dockerfile-build
description: Generate a new Dockerfile following best practices (multi-stage, DHI base images, security hardening)
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "dockerfile-build" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "dockerfile-build" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Auto-detect project type and generate a production-ready Dockerfile with multi-stage build, testing stage controlled by `RUN_TESTS` build arg, and non-root user security hardening.

Supported types: Python (pyproject.toml), Node.js (package.json), Next.js, Rust (Cargo.toml), Generic.

## Execute

```bash
~/.claude/scripts/dockerfile-build.sh --full
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**display_summary** — Dockerfile generated successfully at the path in `data.dockerfile_path`. Report: project type, file path. Tell the user to review the Dockerfile, adjust ENTRYPOINT/CMD for their application, and test with:
```bash
docker build --build-arg RUN_TESTS=true .
docker build .
```

**fix_validation_issues** — Validation failed. Read `data.issues[]` and fix each issue in the generated Dockerfile using the Edit tool. Required elements: multi-stage build with `AS testing` stage, `ARG RUN_TESTS=false`, `USER` directive with non-root user. After fixing, re-validate: `~/.claude/scripts/dockerfile-build.sh --json --validate`

**fix_error** — Script failed. Report error and try the debug block.

## Section Flags

- `--detect` — Detect project type only
- `--generate` — Generate Dockerfile only
- `--validate` — Validate existing Dockerfile

## Debug

```bash
~/.claude/scripts/dockerfile-build.sh --raw --detect
~/.claude/scripts/dockerfile-build.sh --raw --generate
~/.claude/scripts/dockerfile-build.sh --raw --validate
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "dockerfile-build" --event complete \
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
