---
command: db-restore
group: db
backing_script: ~/.claude/scripts/db-restore.sh
mutates: [db]
runtime: ~2-30min (size-dependent)
destructive: true
requires_project_yaml: required
project_yaml_fields:
  - database.type
  - database.connection.host
  - database.connection.database
  - database.connection.user
  - database.backup.directory
requires_project_knowledge: none
project_knowledge_sections: []
---

# /db-restore

Restores a database from a backup file with integrity pre-checks and
post-restore verification. Guides you through choosing a backup and a
target database, confirms before writing, then validates table counts and
indexes after the restore completes.

> **Config:** PROJECT.yaml **required** — reads `database.type`,
> `database.connection.*`, and `database.backup.directory`

> ⚠️ **Destructive — confirm twice.** Restoring overwrites the target
> database. Choosing an existing database as the target permanently
> replaces its contents. Always restore to a new or test database first.

---

## When to use it

- Recovering a staging or dev database after data corruption or a bad migration
- Validating a production backup by restoring it to a test database
- Seeding a fresh environment from a known-good snapshot

## Usage

```bash
/db-restore [--backup-file <path>] [--target-db <name>] [--create-db]
```

**Common invocations:**

```bash
/db-restore                                          # guided: picks latest backup, prompts for target
/db-restore --backup-file /backups/app_20260515.sql.gz --target-db app_test --create-db
/db-restore --detect                                 # config check only
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--backup-file <path>` | No | Path to the backup file to restore. Prompted interactively when multiple backups exist. |
| `--target-db <name>` | No | Database name to restore into. Prompted if not supplied. |
| `--create-db` | No | Create the target database before restoring. Required when the target does not yet exist. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `psql` / `pg_restore` | PostgreSQL restore | install `postgresql-client` |
| `mysql` | MySQL/MariaDB restore | install `mysql-client` |
| `mongorestore` | MongoDB restore | install `mongodb-database-tools` |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `gzip` / `gunzip` | Decompress `.gz` backup files | preinstalled on most systems |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `database.type`,
  `database.connection.*`, `database.backup.directory`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Backup file (path resolved from `database.backup.directory`) — read during restore

## Backing script

**Script**: `~/.claude/scripts/db-restore.sh`

**Inputs:** optional `--backup-file <path>`, `--target-db <name>`,
`--create-db`. Reads `database.*` from PROJECT.yaml.

**Outputs (structured JSON on stdout):** `next_action` ∈
{`display_summary`, `provide_input`, `select_backup`, `fix_backup_path`,
`fix_connection`, `fix_error`}, plus `target_database`, `tables_restored`,
`duration`, `invalid_indexes`, `report_file`.

**Invocation surface:**

```bash
~/.claude/scripts/db-restore.sh --full                              # guided full run
~/.claude/scripts/db-restore.sh --full --target-db <name> --create-db
~/.claude/scripts/db-restore.sh --full --backup-file <path> --target-db <name>
~/.claude/scripts/db-restore.sh --detect                            # config only
~/.claude/scripts/db-restore.sh --verify --backup-file <path>       # integrity check only
~/.claude/scripts/db-restore.sh --check                             # post-restore verification only
~/.claude/scripts/db-restore.sh --raw --full                        # debug: unformatted output
```

## How it works

1. **Detect** — reads PROJECT.yaml for database type and connection
   details. Returns `provide_input` if required fields are missing.
2. **Select backup** — lists available backup files. If only one exists,
   uses it automatically; otherwise returns `select_backup` so the user
   can choose.
3. **Verify backup** — runs integrity checks (readable, non-zero,
   decompresses, SQL header present) before touching the target.
4. **Confirm target** — if no `--target-db` was supplied, returns
   `provide_input` to ask whether to restore into a new test database,
   a new named database, or an existing database (destructive path).
5. **Restore** — creates the target database if `--create-db`, then
   pipes the backup through the appropriate client (`psql`, `mysql`,
   `mongorestore`). Duration is tracked.
6. **Post-restore check** — queries table counts, checks for invalid
   indexes (PostgreSQL), and writes a report file.
7. **Summary** — LLM reports tables restored, duration, any invalid
   indexes, and the report path. Recommends running `ANALYZE` and smoke
   tests.

## Example workflows

### Scenario: Safe staging recovery

```
/db-backup-verify                   # confirm a valid backup exists
/db-restore --target-db app_staging_recovery --create-db
/db-schema-sync                     # re-sync metadata if needed
```

### Scenario: Restore with abbreviated output

```
/db-restore --backup-file /backups/app_20260515_0300.sql.gz --target-db app_test --create-db
```

```
Restore Complete
────────────────────────────────────────────
Target DB:  app_test (created)
Backup:     app_20260515_0300.sql.gz
Tables:     84 restored
Duration:   4m 12s
Invalid indexes: 0

Report: /tmp/db-restore-20260516-143022.txt

Next steps:
  • Run ANALYZE on app_test to update planner statistics
  • Execute smoke tests against app_test before promoting
```

## Notes & gotchas

- **Always restore to a new or test database first.** Overwriting the
  live production database with a backup is a two-step permanent
  operation with no undo.
- The backup is integrity-checked *before* the restore begins. If
  verification fails the restore is aborted — no partial write.
- `--create-db` is a separate step from the restore; if the target
  already exists and you pass `--create-db`, the script returns an error
  rather than silently dropping the existing database.
- **If it fails mid-restore:** the target database may be in a partial
  state. Drop it (`DROP DATABASE <name>;`) and rerun from scratch. Check
  `fix_error` details and run
  `~/.claude/scripts/db-restore.sh --raw --full` for verbose output.
- Post-restore invalid indexes (PostgreSQL) should be rebuilt with
  `REINDEX DATABASE <name>;` before routing traffic to the restored DB.
