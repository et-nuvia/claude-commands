---
name: training-videos
description: Create professional training videos with synchronized voiceover
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "training-videos" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "training-videos" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Produce training videos using Playwright, edge-tts, and ffmpeg. Configuration at `~/.claude/templates/training-videos.yaml`.

## Execute

```bash
# Determine flags from user request:
# "check status" → --status
# "create video for <id>" → --video <id> --yes
# "generate all" → --mode all --yes
# "just audio for <id>" → --video <id> --phase audio
~/.claude/scripts/training-videos.sh --full
```

## Response Handling

Read `next_action` from the JSON response and act accordingly:

**next_action: display_summary** — Success. Show `processed[]` video IDs and duration. If `failed[]` is non-empty, note which succeeded.

**next_action: investigate_failures** — Partial success or all failed. Show `processed[]` (succeeded) and `failed[]` (failed). For each failed video, re-run with --raw for details. Common causes: missing voiceover script, missing Playwright test, ffmpeg error.

**next_action: fix_error** — Setup error. Show `message` and `suggestion`. Common causes: no `training-videos.yaml` found (copy from template), missing tools (edge-tts, ffmpeg, npx, yq).

## Common Invocations

```bash
# Check which videos need updates
~/.claude/scripts/training-videos.sh --status

# Specific video, single phase
~/.claude/scripts/training-videos.sh --video <id> --phase audio
~/.claude/scripts/training-videos.sh --video <id> --phase video
~/.claude/scripts/training-videos.sh --video <id> --phase assembly

# Override voice or resolution
~/.claude/scripts/training-videos.sh --video <id> --voice en-US-GuyNeural --yes
```

## Section Flags

- `--validate` — check environment and tools only
- `--status` — show which videos need updates

## Debug

```bash
~/.claude/scripts/training-videos.sh --raw --validate
~/.claude/scripts/training-videos.sh --raw --video <id> --phase audio
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "training-videos" --event complete \
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
