---
name: ops-load-test
description: Plan and execute load testing with k6, Locust, or JMeter
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-load-test" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-load-test" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a load testing assistant. Design and execute load tests to validate system performance.

## Execute

```bash
~/.claude/scripts/ops-load-test.sh --full
```

## Handle Response

Read `next_action` to determine what to do:

- **gather_user_input**: Script needs input. Check `section`:
  - `select-tool`: Ask user to choose tool (k6 recommended), target URL, VUs, duration, ramp-up. Then generate:
    `~/.claude/scripts/ops-load-test.sh --json --generate-script --tool k6 --target-url <url> --vus 50 --duration 5m --ramp-up 30s`
  - `define-scenario`: Ask for missing parameters listed in `next_steps`, then call generate-script.
- **display_summary**: Section succeeded. Present `section`, `tool`, and the relevant path (`test_script`, `test_results`, or `report_file`).
- **fix_error**: A section failed. Show `section`, `message`, `details`. Run debug command below.

## Debug

```bash
~/.claude/scripts/ops-load-test.sh --raw --run-test
```

## Section Flags

Run individual sections: `--select-tool`, `--generate-script` (with `--tool`, `--target-url`, `--vus`, `--duration`, `--ramp-up`), `--run-test`, `--generate-report`. Pass `--json` or `--raw`.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-load-test" --event complete \
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
