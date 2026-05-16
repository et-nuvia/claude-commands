---
command: db-user-audit
group: db
backing_script: ~/.claude/scripts/db-user-audit.sh
mutates: []
runtime: ~15-45s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - database.type
  - database.connection.host
  - database.connection.database
  - database.connection.user
requires_project_knowledge: none
project_knowledge_sections: []
---

# /db-user-audit

Connects to your database and enumerates all users, roles, and
permissions, flagging security issues such as superuser accounts,
passwordless users, expired passwords, and excessive privileges. Produces
a report with remediation SQL. Makes no changes; safe to run on any
schedule.

> **Config:** PROJECT.yaml optional — reads `database.type` and
> `database.connection.*` when present. Connection details can also be
> passed as CLI flags.

---

## When to use it

- Security review before a production deployment
- After adding a new database user, to confirm privileges are scoped correctly
- Periodic access audit (recommended monthly)

## Usage

```bash
/db-user-audit [--type <db-type> --host <host> --db <name> --user <admin>]
```

**Common invocations:**

```bash
/db-user-audit                                              # auto-detect from PROJECT.yaml
/db-user-audit --type postgresql --host localhost --db mydb --user admin
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--type <db-type>` | No | Database type: `postgresql` or `mysql`. Read from PROJECT.yaml when absent. |
| `--host <host>` | No | Database host. Read from PROJECT.yaml when absent. |
| `--db <name>` | No | Database name. Read from PROJECT.yaml when absent. |
| `--user <admin>` | No | Admin user to connect as. Read from PROJECT.yaml when absent. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `psql` | Query `pg_roles`, `pg_authid`, `information_schema` (PostgreSQL) | install `postgresql-client` |
| `mysql` | Query `mysql.user`, `information_schema.USER_PRIVILEGES` (MySQL) | install `mysql-client` |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. If present, reads `database.type` and
  `database.connection.*` so no flags are needed.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Report file (path returned in JSON) — written to `/tmp/` for LLM display

## Backing script

**Script**: `~/.claude/scripts/db-user-audit.sh`

**Inputs:** no required flags; optional `--type`, `--host`, `--db`,
`--user` overrides. Falls back to PROJECT.yaml if available.

**Outputs (structured JSON on stdout):** `next_action` ∈
{`display_summary`, `remediate_high_risk`, `remediate_medium_risk`,
`fix_connection`, `fix_error`}, plus `database_type`, `total_users`,
`superuser_count`, `passwordless_count`, `expired_password_count`,
`findings[]` (each with `severity`, `user`, `issue`, `remediation_sql`),
`report_file`.

**Invocation surface:**

```bash
~/.claude/scripts/db-user-audit.sh                           # auto-detect from PROJECT.yaml
~/.claude/scripts/db-user-audit.sh --type postgresql --host localhost --db mydb --user admin
~/.claude/scripts/db-user-audit.sh --raw                     # debug: unformatted output
```

## How it works

1. **Detect** — reads PROJECT.yaml for connection details or uses
   CLI flags. Returns `fix_connection` if the connection cannot be
   established.
2. **Enumerate users** — queries the database catalog for all
   users/roles: login privilege, superuser status, password presence,
   password expiry, `CREATEDB`/`CREATEROLE` grants.
3. **Classify findings** — assigns severity:
   - **HIGH**: superusers beyond the default admin account; users with
     no password set.
   - **MEDIUM**: expired passwords; users with `CREATEDB` or
     `CREATEROLE` they don't need.
   - **LOW**: informational (locked accounts, read-only users).
4. **Remediation SQL** — for each HIGH and MEDIUM finding, generates
   the specific `ALTER ROLE` / `REVOKE` SQL statement needed.
5. **Route** — returns `remediate_high_risk` (needs immediate action),
   `remediate_medium_risk` (address this week), or `display_summary`
   (no significant issues).
6. **Report** — LLM presents findings with remediation SQL, severity
   grouping, and next steps (including scheduling the next audit).

## Example workflows

### Scenario: Pre-deployment security check

```
/db-user-audit         # confirm no excessive permissions
/deploy-risk           # cross-check deployment risk
/deploy-to-stage
```

### Scenario: Audit report with findings

```
/db-user-audit
```

```
Database User Audit — app_production (PostgreSQL)
────────────────────────────────────────────
Users:        8 total   Superusers: 2   Passwordless: 1

HIGH RISK (immediate action required):
  • app_legacy — no password set
    Fix: ALTER ROLE app_legacy WITH PASSWORD 'REPLACE_ME';

MEDIUM RISK (address this week):
  • reporting_user — CREATEDB privilege unnecessary
    Fix: ALTER ROLE reporting_user NOCREATEDB;

Report: /tmp/db-user-audit-20260516-143022.txt
Next audit: recommended in 30 days
```

## Notes & gotchas

- The script connects with the admin user configured in PROJECT.yaml or
  supplied via flags. This user must have permission to read
  `pg_authid` (PostgreSQL) or `mysql.user` (MySQL) — a regular
  application user typically cannot.
- Superuser count includes the default `postgres` / `root` account.
  The script flags accounts *beyond* the expected default as HIGH risk.
- `remediate_high_risk` means findings that could allow unauthorized
  access. Address these before any deployment to production.
- **If it fails:** `fix_connection` → verify host, port, and admin
  credentials. Other errors: debug with
  `~/.claude/scripts/db-user-audit.sh --raw`.
- Schedule regular audits (monthly) — access creep is silent and
  cumulative.
