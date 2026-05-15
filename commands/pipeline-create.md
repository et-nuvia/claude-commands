---
name: pipeline-create
description: Generate CI/CD pipeline configuration for GitHub Actions or GitLab CI
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "pipeline-create" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "pipeline-create" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Generate an optimized CI/CD pipeline using the pipeline-create script. The script auto-detects platform and language from the project, reads PROJECT.yaml for configuration, and produces a ready-to-use pipeline file.

## Execute
```bash
~/.claude/scripts/pipeline-create.sh --full
```

## Response Handling

Parse the JSON output and act on `next_action`:

**`display_summary`** — Pipeline generated successfully. Report:
- Platform detected and pipeline file path (`pipeline_file`)
- Stages included and key features enabled
- Next steps: configure CI/CD secrets, commit the file, push to trigger first run

**`prompt_user`** — Script needs input to proceed. Check `section` to know what is missing:
- `section: detect` — Cannot auto-detect platform; ask user for platform (github/gitlab) and rerun with `--platform github` or `--platform gitlab`
- `section: gather` — PROJECT.yaml missing; run `/project-config init` first, then retry
- `section: preferences` — Ask user: which optional stages to include (security scanning, E2E tests, notifications, migrations)?

**`generate_pipeline`** — Preferences gathered; run: `~/.claude/scripts/pipeline-create.sh --json --generate`

**`fix_error`** — Report the `message` and `section` to the user with remediation steps.

## Sections Reference
| Flag | Purpose |
|------|---------|
| `--detect` | Platform detection only |
| `--gather` | Load project info from PROJECT.yaml |
| `--preferences` | Collect pipeline feature preferences |
| `--generate` | Generate pipeline file |
| `--full` | Run all sections in sequence (default) |

## Debug
```bash
~/.claude/scripts/pipeline-create.sh --raw --detect
```

## Notes
- Requires PROJECT.yaml with `git.platform`, `tech_stack.languages`, `ci.branches`, `docker.registry`
- Run `/project-config init` first if PROJECT.yaml is missing
- For non-standard setups (monorepos, custom tools), ask the user for requirements before running
- After generation: review the file, configure secrets in GitHub/GitLab settings, test with a push

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "pipeline-create" --event complete \
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
