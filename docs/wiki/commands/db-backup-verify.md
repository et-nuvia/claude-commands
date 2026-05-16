---
command: db-backup-verify
group: db
backing_script: ~/.claude/scripts/db-backup-verify.sh
mutates: []
runtime: ~15-60s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - database.type
  - database.connection.host
  - database.connection.database
  - database.connection.user
  - database.backup.directory
  - database.backup.retention_days
requires_project_knowledge: none
project_knowledge_sections: []
---

# /db-backup-verify

Checks that your database backups exist, are readable, pass integrity
validation, and comply with the retention policy — without touching the
live database. Optionally performs a test restore to a temporary database
to confirm the backup is actually usable. Safe to run on any schedule.

> **Config:** PROJECT.yaml **required** — reads `database.type`,
> `database.connection.*`, `database.backup.directory`, and optionally
> `database.backup.retention_days`

---

## When to use it

- Before a major deployment, to confirm a valid backup exists
- As part of a scheduled ops check (daily/weekly backup health)
- After suspecting backup corruption or a missed backup run

## Usage

```bash
/db-backup-verify
```

**Common invocations:**

```bash
/db-backup-verify                  # default: full check (config → list → verify → retention)
/db-backup-verify --test-restore   # also spin up a temp DB and restore into it
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--test-restore` | No | Performs an actual restore to a temporary database to prove the backup is loadable |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `psql` / `mysql` / `mongodump` | Connect to DB and validate SQL syntax (type-dependent) | install per DB engine |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `gzip` / `gunzip` | Decompress compressed backup files for inspection | preinstalled on most systems |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `database.backup.directory`. Optional:
  `database.backup.retention_days` (defaults to 7 if absent).
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Backup directory (configured path) — the `.sql`, `.dump`, or `.gz` files inspected

## Backing script

**Script**: `~/.claude/scripts/db-backup-verify.sh`

**Inputs:** no required flags for a full run; section flags for targeted
runs. Reads `database.*` from PROJECT.yaml.

**Outputs (structured JSON on stdout):** `next_action` ∈
{`display_summary`, `fix_error`}, plus `backup_count`, `latest_backup`,
`checks` (readable, size, compression, SQL syntax, age), `retention`
(old_count, retention_days, compliant).

**Invocation surface:**

```bash
~/.claude/scripts/db-backup-verify.sh --full          # all sections
~/.claude/scripts/db-backup-verify.sh --config        # load + validate config only
~/.claude/scripts/db-backup-verify.sh --list          # list available backups
~/.claude/scripts/db-backup-verify.sh --verify        # integrity check on latest backup
~/.claude/scripts/db-backup-verify.sh --test-restore  # restore to temp DB
~/.claude/scripts/db-backup-verify.sh --retention     # retention policy compliance
~/.claude/scripts/db-backup-verify.sh --raw --full    # debug: unformatted output
```

## How it works

1. **Config** — reads PROJECT.yaml to locate the backup directory and
   resolve database credentials. Returns `fix_error` if the directory
   path is missing.
2. **List** — enumerates backup files, sorts by modification time, picks
   the latest.
3. **Verify** — checks: file is readable, size is non-zero, compression
   (if `.gz`) decompresses cleanly, SQL header is present (for `.sql`
   dumps). Records each check as passed/failed.
4. **Test restore** *(optional)* — creates a temporary database, loads
   the backup into it, confirms table counts are non-zero, then drops
   the temp database.
5. **Retention** — counts backups older than `retention_days` and flags
   if any are outside the window.
6. **Report** — LLM presents a human-readable summary: each check's
   pass/fail, the latest backup path and age, retention compliance, and
   corrective recommendations for any failures.

## Example workflows

### Scenario: Pre-deployment backup check

```
/db-backup-verify          # confirm backup exists and is valid
/deploy-to-stage           # proceed with confidence
```

### Scenario: Test-restore verification with output

```
/db-backup-verify --test-restore
```

```
Backup Verification
────────────────────────────────────
Latest:    /backups/app_20260516_0300.sql.gz  (2.4 GB, 6h old)
Checks:    readable ✓  size ✓  compression ✓  SQL syntax ✓  age ✓
Retention: 14 backups found — 2 older than 7 days (non-compliant)

Test restore: temp_verify_20260516 created, 84 tables loaded — OK
Temp database dropped.

Action: delete backups older than 7 days to meet retention policy.
```

## Notes & gotchas

- The `--test-restore` section creates and immediately drops a temporary
  database — it does not touch the live database at any point.
- SQL syntax checking reads only the first few kilobytes of the dump,
  not the full file. A structurally valid header does not guarantee a
  complete backup.
- Retention compliance is informational only — the command never deletes
  backups.
- **If it fails:** `fix_error` on config → add `database.backup.directory`
  to PROJECT.yaml. Corrupted backup → run a fresh backup immediately.
  Debug with `~/.claude/scripts/db-backup-verify.sh --raw --full`.
