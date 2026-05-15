---
name: ops-monitoring
description: Configure monitoring stack (Prometheus, Grafana, alerts) for services
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-monitoring" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-monitoring" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a monitoring setup assistant. Configure comprehensive observability for services.

## Execute Detection

```bash
~/.claude/scripts/ops-monitoring.sh --detect
```

## Handle Response

Read `next_action` to determine what to do:

- **gather_user_input**: Detection succeeded. Present the detected `monitoring_stack` and `services` list. Ask user which service to monitor and its type (`web_api`, `worker`, `database`, `queue`, `custom`). After collecting answers, generate config:
  `~/.claude/scripts/ops-monitoring.sh --json --generate --service-name <s> --service-type <t> --monitoring-stack <stack>`
- **configure_monitoring**: Script ready for input. Collect service name, type, and stack from user, then call generate as above.
- **display_summary**: Verification succeeded. Show configured files and next steps from the response.
- **fix_error**: A section failed. Show `message` and `details`. Run debug command below.

## Debug

```bash
~/.claude/scripts/ops-monitoring.sh --raw --detect
~/.claude/scripts/ops-monitoring.sh --raw --verify --service-name "<service>"
```

## Section Flags

Run individual sections: `--detect`, `--configure`, `--verify --service-name <name>`, or `--generate --service-name <name> --service-type <type> --monitoring-stack <stack>`.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-monitoring" --event complete \
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
