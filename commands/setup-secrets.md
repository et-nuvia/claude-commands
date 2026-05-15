---
name: setup-secrets
description: Set up Infisical project, folders, secrets, and local .secrets/ directory
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "setup-secrets" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "setup-secrets" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Create or validate the Infisical secrets infrastructure for a project. Handles project creation, folder setup, secret population, machine identity access, local `.secrets/` directory, and docker-compose validation.

## Execute

```bash
# Parse user intent from $ARGUMENTS:
# no args or "full" → --full (run all sections)
# "validate" → --validate (check existing setup)
# "create-project" → --create-project
# "create-folders" → --create-folders
# "populate" → --populate
# "local-setup" → --local-setup
# "verify" → --verify
~/.claude/scripts/setup-secrets.sh --full
```

Script automatically:
- Reads PROJECT.yaml for project name, secrets config, and required buckets
- Detects secrets backend (infisical vs aws)
- Reads machine identity credentials from `~/.infisical/`
- Authenticates with Infisical API
- Checks if project already exists

## Response Handling

Read `next_action` from the JSON response and act accordingly:

**next_action: display_summary** — Setup complete or validation passed. Show the summary of what was created/verified: project ID, folders, secret counts, `.secrets/` status, docker-compose status.

**next_action: gather_secret_values** — Script created folders but needs secret values from the user. Show `missing_secrets[]` with folder and key names. Ask the user for values (or generate random ones for session_secret/nextauth_secret types). Then re-run with `--populate` passing values.

**next_action: confirm_action** — Project doesn't exist yet and needs to be created, or destructive action pending. Show what will be created and ask for confirmation. Re-run with `--create-project` after confirmation.

**next_action: fix_config** — PROJECT.yaml missing or incomplete. Show `message` with what's missing. User should run `/project-config init` or add the `secrets` section.

**next_action: fix_error** — Authentication or API failure. Show `message` and `details`. Common causes: missing `~/.infisical/` credentials, Infisical unreachable, wrong project ID.

**next_action: fix_compose** — docker-compose.yml doesn't match the standard pattern. Show `issues[]` describing what needs to change (e.g., env vars instead of secret files, wrong secrets path). Fix the docker-compose.yml based on the issues.

## Section Flags

```bash
~/.claude/scripts/setup-secrets.sh --validate        # Check existing setup
~/.claude/scripts/setup-secrets.sh --create-project   # Create Infisical project
~/.claude/scripts/setup-secrets.sh --create-folders   # Create folders in Infisical
~/.claude/scripts/setup-secrets.sh --populate         # Populate secrets
~/.claude/scripts/setup-secrets.sh --local-setup      # Create .secrets/ directory
~/.claude/scripts/setup-secrets.sh --verify           # Verify docker-compose + connectivity
```

## Debug

```bash
~/.claude/scripts/setup-secrets.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "setup-secrets" --event complete \
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
