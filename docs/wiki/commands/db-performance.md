---
command: db-performance
group: db
backing_script: ~/.claude/scripts/db-performance.sh
mutates: []
runtime: ~30-120s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - database.type
  - database.connection.host
  - database.connection.database
  - database.connection.user
requires_project_knowledge: none
project_knowledge_sections: []
---

# /db-performance

Connects to your database, collects runtime statistics on slow queries,
missing indexes, unused indexes, and table bloat, then produces a
prioritized report and an index-suggestion file. Makes no schema changes;
safe to run on production read replicas.

> **Config:** PROJECT.yaml **required** — reads `database.type` and
> `database.connection.*`

---

## When to use it

- Response times are degrading and you need a data-driven starting point
- Before and after adding an index, to confirm the improvement
- Periodic ops review (monthly performance baseline)

## Usage

```bash
/db-performance
```

**Common invocations:**

```bash
/db-performance                    # default: full collect + analyze
/db-performance --detect           # connection check only
/db-performance --analyze          # generate report from previously collected data
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--detect` | No | Verify connection and extension availability only; no data collection |
| `--collect` | No | Collect stats only; skip report generation |
| `--analyze` | No | Generate report from data collected in a prior `--collect` run |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `psql` | Query `pg_stat_statements`, `pg_stat_user_tables`, `pg_index` (PostgreSQL) | install `postgresql-client` |
| `mysql` | Query `performance_schema` slow-query data (MySQL/MariaDB) | install `mysql-client` |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `database.type`,
  `database.connection.{host,database,user}`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `/tmp/db-performance-report.json` — written by `--collect`, read by `--analyze`
- `/tmp/db-performance-index-suggestions.sql` — written by `--analyze` for review

## Backing script

**Script**: `~/.claude/scripts/db-performance.sh`

**Inputs:** section flags; reads `database.*` from PROJECT.yaml.

**Outputs (structured JSON on stdout):** `next_action` ∈
{`display_summary`, `enable_extension`, `fix_connection`, `fix_error`},
plus `slow_query_count`, `tables_needing_indexes`, `unused_indexes`,
`bloated_tables`, `report_path`, `index_suggestions_path`.

**Invocation surface:**

```bash
~/.claude/scripts/db-performance.sh --full      # detect + collect + analyze
~/.claude/scripts/db-performance.sh --detect    # connection + extension check
~/.claude/scripts/db-performance.sh --collect   # gather stats
~/.claude/scripts/db-performance.sh --analyze   # build report from collected data
~/.claude/scripts/db-performance.sh --raw --full  # debug: unformatted output
```

## How it works

1. **Detect** — connects to the database and checks that required
   extensions or schemas are available (`pg_stat_statements` for
   PostgreSQL, `performance_schema` for MySQL). Returns
   `enable_extension` if the extension is absent so the user can
   enable it before rerunning.
2. **Collect** — queries slow-query logs/stats, `EXPLAIN`-level index
   usage, unused index candidates, and table/index bloat metrics. Writes
   raw stats to `/tmp/db-performance-report.json`.
3. **Analyze** — LLM reads the JSON; script pre-ranks findings by
   estimated impact. LLM applies query-optimization reasoning (Opus
   recommended for complex patterns), generates an index-suggestion
   `.sql` file, and identifies bloat candidates for `VACUUM` or
   `REINDEX`.
4. **Report** — presents slow-query count, index gaps, unused indexes,
   and bloated tables. Lists top recommendations ranked by estimated
   improvement. Points the user to the report and suggestion files for
   hands-on review.

## Example workflows

### Scenario: Investigating a latency spike

```
/db-performance        # identify slow queries and missing indexes
# review /tmp/db-performance-index-suggestions.sql in staging
/db-backup-verify      # confirm backup before applying
# apply index in staging, benchmark, then promote to production
```

### Scenario: Analysis output

```
/db-performance
```

```
Database Performance Analysis
────────────────────────────────────────────
DB: app_production (PostgreSQL 16.2)

Slow queries:       12  (avg 1.4s, worst 8.2s)
Missing indexes:     5 tables
Unused indexes:      3 (wasting ~420 MB)
Bloated tables:      2 (orders: 34% bloat, events: 41% bloat)

Top recommendations:
  1. Add index on orders(customer_id, created_at) — covers 4 slow queries
  2. DROP INDEX idx_events_legacy — unused 90 days, 380 MB
  3. VACUUM FULL events — 41% bloat, 1.2 GB reclaim

Report:      /tmp/db-performance-report.json
Index SQL:   /tmp/db-performance-index-suggestions.sql
```

## Notes & gotchas

- PostgreSQL: `pg_stat_statements` must be loaded in `shared_preload_libraries`
  and requires a superuser to create. The script returns `enable_extension`
  if it is absent — run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;`
  as a superuser, then rerun.
- Statistics are cumulative since the last `pg_stat_statements_reset()`.
  A freshly restarted database will show misleadingly low slow-query counts.
- Index suggestions are for review only — test every suggestion in staging
  before applying to production. New indexes trade write latency for read speed.
- **If it fails:** `fix_connection` → check host, port, credentials, and
  network access. Other errors: debug with
  `~/.claude/scripts/db-performance.sh --raw --full`.
