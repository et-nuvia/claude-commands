---
command: rotate-secret
group: project-config
backing_script: ~/.claude/scripts/rotate-secret.sh
mutates: [infisical, aws]
runtime: ~10-30s (rotation itself may take minutes)
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - secrets.backend
  - secrets.required
  - secrets.rotation.enabled
  - secrets.rotation.schedules
requires_project_knowledge: none
project_knowledge_sections: []
---

# /rotate-secret

Checks rotation schedules, surfaces overdue secrets, and guides through the
correct rotation procedure for each secret type (database two-step,
API key, JWT dual-key, or manual). Tracks rotation history locally so the
schedule stays accurate across sessions.

> **Config:** PROJECT.yaml **required** — reads `secrets.backend`, `secrets.required`, `secrets.rotation.enabled`, and `secrets.rotation.schedules` (frequency, strategy, last-rotated date per bucket).

> **Note:** Rotation writes new values to Infisical or AWS Secrets Manager and may trigger credential changes in downstream systems (databases, third-party APIs). Follow the strategy-specific steps exactly — rotating a database password without the two-step pattern causes downtime.

---

## When to use it

- Checking whether any secrets are overdue for rotation
- Walking through a scheduled rotation for a specific bucket
- Setting up automated rotation reminders in CI or cron

## Usage

```bash
/rotate-secret [operation] [bucket]
```

**Common invocations:**

```bash
/rotate-secret                      # default: --status (check rotation schedule)
/rotate-secret status               # show overdue, approaching, and up-to-date buckets
/rotate-secret schedule             # show full rotation schedule with next-due dates
/rotate-secret rotate database      # guide through rotating the database bucket
/rotate-secret setup-reminders      # create cron/CI job for daily status checks
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `operation` | No | One of `status`, `schedule`, `rotate`, `setup-reminders`. Defaults to `status`. |
| `bucket` | With `rotate` | Bucket name from `secrets.required` (e.g., `database`, `api-keys`, `jwt`) |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `infisical` CLI | Update secrets in Infisical (home/WSL) | [infisical.com/docs/cli](https://infisical.com/docs/cli/overview) |
| `aws` CLI | Update secrets in AWS Secrets Manager (work/macOS) | `brew install awscli` |
| `jq` | Build and consume the result JSON | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `secrets.rotation.enabled = true`, `secrets.rotation.schedules` with at least one entry.
- `~/.claude/rotation-history.json` — written after each successful rotation; tracks last-rotated timestamps per project + bucket.

## Backing script

**Script**: `~/.claude/scripts/rotate-secret.sh`

**Inputs:** stage flag (`--status`, `--schedule`, `--rotate <bucket>`,
`--setup-reminders`). Reads PROJECT.yaml and `~/.claude/rotation-history.json`.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `guide_rotation`, `fix_error`}
- `due[]` — buckets overdue for rotation (immediate action)
- `approaching[]` — buckets due within the warning window
- `up_to_date[]` — buckets within schedule
- `intervention` — on `guide_rotation`: `{bucket, strategy, last_rotated, days_overdue}`

**Invocation surface:**

```bash
~/.claude/scripts/rotate-secret.sh --status
~/.claude/scripts/rotate-secret.sh --schedule
~/.claude/scripts/rotate-secret.sh --rotate <bucket>
~/.claude/scripts/rotate-secret.sh --setup-reminders
~/.claude/scripts/rotate-secret.sh --raw --status     # debug: bypass formatting
```

## How it works

1. **Status check** — script reads `secrets.rotation.schedules` from PROJECT.yaml
   and compares `last_rotated` timestamps in `~/.claude/rotation-history.json`
   against each bucket's `frequency_days`. Returns `display_summary` with
   `due[]`, `approaching[]`, `up_to_date[]`.
2. **Rotation dispatch** — `--rotate <bucket>` returns `guide_rotation` with
   the bucket's configured `strategy`. LLM selects the correct procedure:
   - **database (two-step):** generate new password → update DB user → update
     Infisical/AWS secret → wait for service refresh → verify connectivity.
   - **api-key:** guide user to provider dashboard → collect new key → update
     secret → revoke old key.
   - **jwt (dual-key):** generate new secret → write both old and new → wait
     full token TTL → remove old secret.
   - **manual:** document current value → show provider-specific steps →
     wait for user to update externally → write new value → verify.
3. **History update** — after successful rotation, LLM writes the current
   timestamp to `~/.claude/rotation-history.json` for the project + bucket.
4. **Reminder setup** — `--setup-reminders` generates a cron entry or CI
   scheduled job that runs `--status` daily and notifies when buckets are due.

## Example workflows

### Scenario: Daily rotation check

```
/rotate-secret status
```

Quick health check — no changes made. Use as a CI scheduled job via
`--setup-reminders` to surface overdue secrets automatically.

### Scenario: Database rotation

```
/rotate-secret rotate database
```

LLM walks through the two-step procedure, pausing for confirmation at each
step to avoid locking out the application.

### Scenario: Status output

```
/rotate-secret
```

```
Secret Rotation Status — nuvia-api
────────────────────────────────────────
  OVERDUE    database    last: 2025-11-01  (196 days, limit 90)
  DUE SOON   api-keys    last: 2026-02-14  (due in 6 days)
  OK         jwt         last: 2026-04-01  (45 days, limit 90)

Run: /rotate-secret rotate database   ← start here
```

## Notes & gotchas

- `secrets.rotation.enabled` must be `true` in PROJECT.yaml or the command
  returns `fix_error`. Add the `rotation` block under `secrets` if missing.
- Rotation history is stored in `~/.claude/rotation-history.json` (global, not
  per-repo). If this file is missing or the entry is absent, the script treats
  the secret as never-rotated.
- **Blast radius on database rotation:** skipping the two-step procedure (update
  DB user *before* updating the secret) will cause a gap where running services
  hold a credential that no longer works. Always follow the guided steps in order.
- Work (macOS) uses AWS Secrets Manager; home (WSL) uses Infisical. The
  correct CLI is selected automatically from `secrets.backend` in PROJECT.yaml.
- **If it fails (`fix_error`):** `secrets.rotation.enabled` not set → add to
  PROJECT.yaml. Auth failure → check `~/.infisical/` credentials or `aws
  sts get-caller-identity`. Debug with `~/.claude/scripts/rotate-secret.sh
  --raw --status`.
