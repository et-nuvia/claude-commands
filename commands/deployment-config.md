---
name: deployment-config
description: Display or validate deployment configuration from PROJECT.yaml
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "deployment-config" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "deployment-config" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a deployment configuration assistant.

## Execute

```bash
~/.claude/scripts/deployment-config.sh --full
```

The script reads `PROJECT.yaml`, validates the deployment section, and returns structured configuration.

## Handle Response

Read `next_action` from the result:

- `display_summary` — Configuration loaded. Display: environment_type, branches, ci.platform, deployment.method, urls, version. Show any warnings from the `warnings` array.
- `fix_error` — Configuration invalid or PROJECT.yaml missing. Report message and details. If PROJECT.yaml not found, suggest running `/project-config init`.

## Validate Only

```bash
~/.claude/scripts/deployment-config.sh --validate
```

Returns success/error without loading full config values.

## Debug

```bash
~/.claude/scripts/deployment-config.sh --raw --full
```

## Configuration Reference

Deployment config lives in `PROJECT.yaml` under the `deployment` key:

```yaml
deployment:
  method: "pipeline"       # pipeline, ssm, ssh, or script
  health_check_path: "/health"
  staging:
    url: "https://staging.example.com"
  production:
    url: "https://prod.example.com"

ci:
  platform: "github"       # github or gitlab
  branches:
    staging: "staging"
    production: "main"
```

Environment auto-detected: macOS=work/AWS/GitHub, Linux/WSL=home/Unraid/GitLab.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "deployment-config" --event complete \
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
