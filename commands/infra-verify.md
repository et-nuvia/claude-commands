---
name: infra-verify
description: Verify infrastructure is correctly linked and accessible for this project
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-verify" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-verify" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Verify the infrastructure repository symlink is correct and all required tools are available.

## Execute

```bash
~/.claude/scripts/infra-verify.sh --full
```

Section flags: `--config`, `--link`, `--tools`, `--validate` (run one phase only).

## Handle Response by next_action

**`display_summary`** (status: success) — Verification passed. Show repo type, link path, and confirm Terraform/Ansible availability.

**`enable_infra`** (status: blocked) — Infrastructure not enabled. Instruct user to edit `PROJECT.yaml`: set `infrastructure.enabled: true`, configure `infrastructure.repo.url` and `infrastructure.repo.type`, then re-run `/infra-verify`.

**`clone_repo`** (status: intervention) — Infrastructure repo not cloned. The `details` field contains the repo URL and target path. Clone it:

```bash
REPO_URL="<url from details>"
INFRA_NAME=$(basename "$REPO_URL" .git)
mkdir -p "$HOME/.infrastructure"
git clone "$REPO_URL" "$HOME/.infrastructure/$INFRA_NAME"
```

Then re-run: `~/.claude/scripts/infra-verify.sh --json --full`

**`switch_branch`** (status: intervention) — Branch mismatch. Extract the expected branch from `details`. Switch the local infrastructure repo to it:
`cd ~/.infrastructure/<name> && git fetch origin && git checkout <branch> && git pull`

**`fix_symlink`** (status: intervention) — Symlink wrong, missing, or not a symlink. Get the correct paths from `details` and recreate:
`rm -f "$LINK_TARGET" && ln -s "$EXPECTED_PATH" "$LINK_TARGET"`

Re-run `~/.claude/scripts/infra-verify.sh --json --link` to confirm.

**`fix_error`** (status: error) — Hard error. Show `section`, `message`, and `details`.

## Debug

```bash
~/.claude/scripts/infra-verify.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-verify" --event complete \
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
