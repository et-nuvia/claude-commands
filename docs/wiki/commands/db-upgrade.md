---
command: db-upgrade
group: db
backing_script: ~/.claude/scripts/db-upgrade.sh
mutates: [db]
runtime: ~60-300s (planning only; execution is manual)
destructive: true
requires_project_yaml: required
project_yaml_fields:
  - database.type
  - database.connection.host
  - database.connection.database
  - database.connection.user
requires_project_knowledge: none
project_knowledge_sections: []
---

# /db-upgrade

Produces a comprehensive major-version upgrade plan for your database:
detects the current version, identifies breaking changes, estimates
downtime, and generates step-by-step upgrade scripts. The command
**plans only** — no changes are applied automatically.

> **Config:** PROJECT.yaml **required** — reads `database.type` and
> `database.connection.*`

> ⚠️ **Destructive — confirm twice.** Executing the generated upgrade
> scripts modifies the database engine in place (or replaces it, depending
> on strategy). Always run the full plan in staging before touching
> production.

---

## When to use it

- Planning a PostgreSQL or MySQL major version bump (e.g., PG 14 → 16)
- Assessing downtime impact and breaking changes before scheduling a
  maintenance window
- Generating upgrade runbooks for team review or change-management sign-off

## Usage

```bash
/db-upgrade [--target-version <version>] [--strategy <strategy>]
```

**Common invocations:**

```bash
/db-upgrade                                                       # guided: detects current version, prompts for target + strategy
/db-upgrade --target-version 16 --strategy pg_upgrade            # non-interactive
/db-upgrade --detect                                              # version check only
/db-upgrade --breaking-changes --target-version 16               # breaking-change report only
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--target-version <n>` | No | Major version to upgrade to. Prompted interactively if omitted. |
| `--strategy <name>` | No | Upgrade strategy. Prompted if omitted. Options: `pg_upgrade`, `dump_restore`, `logical_replication`, `blue_green`. |
| `--detect` | No | Detect current DB version only; skip planning. |
| `--breaking-changes` | No | List breaking changes for the target version only. |
| `--estimate` | No | Estimate database size and projected downtime only. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `psql` | Connect and query version / catalog info (PostgreSQL) | install `postgresql-client` |
| `mysql` | Connect and query version info (MySQL/MariaDB) | install `mysql-client` |
| `pg_upgrade` | In-place binary upgrade (PostgreSQL, `pg_upgrade` strategy) | install new PG version alongside old |
| `pg_dumpall` | Full cluster dump (`dump_restore` strategy) | install `postgresql-client` |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `database.type`,
  `database.connection.{host,database,user}`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Generated plan doc and upgrade scripts (paths returned in JSON output)

## Backing script

**Script**: `~/.claude/scripts/db-upgrade.sh`

**Inputs:** optional `--target-version <n>`, `--strategy <name>`, and
section flags. Reads `database.*` from PROJECT.yaml.

**Outputs (structured JSON on stdout):** `next_action` ∈
{`display_summary`, `provide_target_version`, `provide_strategy`,
`configure_database`, `fix_connection`, `fix_error`}, plus
`database_type`, `current_version`, `target_version`, `strategy`,
`estimated_downtime`, `plan_file`, `script_files[]`.

**Invocation surface:**

```bash
~/.claude/scripts/db-upgrade.sh --full                                     # guided full plan
~/.claude/scripts/db-upgrade.sh --full --target-version 16 --strategy pg_upgrade
~/.claude/scripts/db-upgrade.sh --detect                                   # version only
~/.claude/scripts/db-upgrade.sh --breaking-changes --target-version 16    # breaking changes
~/.claude/scripts/db-upgrade.sh --estimate                                 # size + downtime
~/.claude/scripts/db-upgrade.sh --raw --full                               # debug
```

## How it works

1. **Detect** — connects to the database and reads the current major
   version. Returns `configure_database` if PROJECT.yaml is missing the
   required fields.
2. **Target version** — if `--target-version` is not supplied, presents
   available upgrade targets and waits for the user to choose. Returns
   `provide_target_version`.
3. **Breaking changes** — identifies deprecated functions, changed
   behaviors, and removed features between the current and target
   version. Flags any that appear in the connected database.
4. **Estimate** — measures total database size and estimates restore
   duration under each strategy to project a maintenance window.
5. **Strategy selection** — presents the four strategies
   (`pg_upgrade`, `dump_restore`, `logical_replication`, `blue_green`)
   with their trade-offs; waits for user input if not supplied.
6. **Plan generation** — generates a step-by-step plan document and
   runnable upgrade scripts tailored to the chosen strategy and
   environment. Opus is used for analysis to ensure correctness.
7. **Summary** — reports database type, versions, strategy, estimated
   downtime, and paths to the generated files. Reminds the user to test
   in staging first.

## Example workflows

### Scenario: Planning a PG version bump

```
/db-backup-verify                              # confirm backup before planning
/db-upgrade --target-version 16 --strategy dump_restore
# review generated scripts in staging
# schedule maintenance window, then execute scripts manually
```

### Scenario: Interactive guided plan with output

```
/db-upgrade
```

```
Database Upgrade Plan
────────────────────────────────────────────
Current: PostgreSQL 14.11
Target:  PostgreSQL 16.3
Strategy: dump_restore

Estimated downtime: ~18 minutes (DB size: 4.2 GB)

Breaking changes detected: 2
  • pg_class.relhasoids removed — check application OID usage
  • ALTER TABLE … RENAME COLUMN restricted in triggers — review migration scripts

Generated files:
  Plan:    /tmp/db-upgrade-plan-20260516.md
  Scripts: /tmp/db-upgrade-step1-dump.sh
           /tmp/db-upgrade-step2-restore.sh
           /tmp/db-upgrade-step3-verify.sh

Test in staging before production. Review breaking changes above.
```

## Notes & gotchas

- This command **generates a plan only**. The scripts must be reviewed
  and executed manually — nothing is applied automatically.
- `logical_replication` and `blue_green` strategies require duplicate
  infrastructure or a replica. The plan document describes the
  prerequisites in detail.
- Breaking changes listed by the script are pattern-matched against the
  database catalog — false positives are possible. Have a DBA review
  before execution.
- **If it fails:** `fix_connection` → verify credentials and network.
  `provide_target_version` mid-run → re-run with `--target-version`.
  Debug with `~/.claude/scripts/db-upgrade.sh --raw --full`.
- Always take a verified backup (`/db-backup-verify`) immediately before
  executing the upgrade scripts in any environment.
