---
command: db-schema-sync
group: db
backing_script: ~/.claude/scripts/db-schema-sync.sh
mutates: []
runtime: ~60-180s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - schema_sync.databases.app.host_secret
  - schema_sync.databases.app.port
  - schema_sync.databases.app.name_secret
  - schema_sync.databases.app.user_secret
  - schema_sync.databases.app.pass_secret
  - schema_sync.databases.app.type
  - schema_sync.databases.analytics.host_secret
  - schema_sync.databases.analytics.type
  - schema_sync.open_metadata.url_secret
  - schema_sync.open_metadata.token_secret
  - schema_sync.open_metadata.service_name
  - schema_sync.open_metadata.database_service_type
  - schema_sync.auto_describe.enabled
  - schema_sync.auto_describe.model
  - schema_sync.auto_describe.context_file
requires_project_knowledge: none
project_knowledge_sections: []
---

# /db-schema-sync

Detects database schema changes introduced by a deployment, generates
human-readable descriptions for new tables and columns, and pushes a
structured changeset to Open Metadata so BI team ETL pipelines and
reports stay aligned. Designed to run as a post-migration step inside
CI/CD pipelines or interactively after a manual migration.

> **Config:** PROJECT.yaml **required** — reads the full `schema_sync`
> block, including `schema_sync.databases.*` and
> `schema_sync.open_metadata.*`. See Prerequisites below.

Note: this command writes to Open Metadata (external service) but does
not mutate local git state or the database itself.

---

## When to use it

- After running migrations in staging or production, to keep Open
  Metadata current
- When a breaking schema change (dropped column, type change) needs to
  be flagged to the BI team before ETL runs
- Adding a new table that the analytics pipeline should start ingesting

## Usage

```bash
/db-schema-sync
```

**Common invocations:**

```bash
/db-schema-sync                             # full interactive run (snapshot before assumed)
/db-schema-sync --snapshot --before         # pre-migration snapshot only
/db-schema-sync --snapshot --after          # post-migration snapshot only
/db-schema-sync --diff                      # diff existing snapshots
/db-schema-sync --sync --dry-run            # preview Open Metadata payloads before pushing
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--snapshot --before` | No | Capture the current schema state before running migrations |
| `--snapshot --after` | No | Capture schema state after migrations complete |
| `--diff` | No | Diff the before/after snapshots into a structured changeset |
| `--describe` | No | Generate the description prompt and template for new tables/columns |
| `--sync` | No | Push changeset to Open Metadata |
| `--sync --dry-run` | No | Preview payloads without pushing |
| `--skip-describe` | No | Skip description generation (CI/CD without LLM access) |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `mysql` | Snapshot MySQL/MariaDB schemas | install `mysql-client` |
| `psql` | Snapshot PostgreSQL schemas | install `postgresql-client` |
| `jq` | Parse and diff JSON snapshots; build Open Metadata payloads | `brew install jq` / `apt install jq` |
| `curl` | HTTP calls to the Open Metadata API | preinstalled on most systems |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: entire `schema_sync` block.
  Optional: `schema_sync.auto_describe.context_file` (domain glossary).
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Snapshot files (written to `/tmp/`) — before/after schema captures
- `descriptions.json` — LLM-written; picked up automatically by `--sync`

## Backing script

**Script**: `~/.claude/scripts/db-schema-sync.sh`

**Inputs:** stage flags (`--snapshot --before|--after`, `--diff`,
`--describe`, `--sync`, `--sync --dry-run`). Reads `schema_sync.*`
from PROJECT.yaml; secrets resolved at runtime from the configured
secrets backend.

**Outputs (structured JSON on stdout):**

- `--diff` → `added_tables[]`, `dropped_tables[]`, `modified_columns[]`,
  `index_changes[]`, `risk_assessment` (HIGH / MEDIUM / LOW per change)
- `--describe` → `describe-prompt.json` path, `descriptions-template.json`
  path, `descriptions.json` target path
- `--sync` → per-operation success/failure, total synced, total failed

**Invocation surface:**

```bash
~/.claude/scripts/db-schema-sync.sh --snapshot --before
~/.claude/scripts/db-schema-sync.sh --snapshot --after
~/.claude/scripts/db-schema-sync.sh --diff
~/.claude/scripts/db-schema-sync.sh --describe
~/.claude/scripts/db-schema-sync.sh --sync --dry-run
~/.claude/scripts/db-schema-sync.sh --sync
```

## How it works

1. **Pre-migration snapshot** — script connects to all configured
   databases and dumps table/column/index definitions to
   `/tmp/schema-before.json`. Run this *before* migrations.
2. **Migrations** — handled externally (deployment pipeline or manual
   step). This command does not run migrations.
3. **Post-migration snapshot** — same dump after migrations complete,
   written to `/tmp/schema-after.json`.
4. **Diff** — script diffs the two snapshots and emits a structured
   changeset. LLM reads it and produces a human-readable summary with a
   risk assessment: HIGH (dropped columns/tables, type changes), MEDIUM
   (new tables/columns), LOW (defaults, comments, new indexes).
5. **Auto-describe** — if `auto_describe.enabled` is true, script
   writes `describe-prompt.json` (all items needing descriptions). LLM
   reads the prompt, generates concise business-purpose descriptions,
   and writes them to `descriptions.json`. In CI/CD, use
   `generate-schema-descriptions.sh` (GitHub Models — free, or
   Anthropic API).
6. **Dry-run review** — LLM runs `--sync --dry-run`, presents the
   payloads, and waits for user approval before the real push.
7. **Sync** — pushes the changeset and descriptions to Open Metadata
   via its REST API. Reports per-operation results.

## Example workflows

### Scenario: Deployment pipeline (CI/CD)

```yaml
# GitHub Actions — post-migration stage
- run: ~/.claude/scripts/db-schema-sync.sh --snapshot --before
- run: make migrate
- run: ~/.claude/scripts/db-schema-sync.sh --snapshot --after
- run: ~/.claude/scripts/db-schema-sync.sh --diff
- run: |
    ~/.claude/scripts/db-schema-sync.sh --describe
    ~/.claude/scripts/generate-schema-descriptions.sh --provider github
- run: ~/.claude/scripts/db-schema-sync.sh --sync
```

### Scenario: Interactive diff review with output

```
/db-schema-sync --diff
```

```
Schema Changes Detected
────────────────────────────────────────────
Added tables:   1   (order_items)
Dropped tables: 0
Modified:       2   columns on orders, products

Risk assessment:
  HIGH:   orders.legacy_status dropped — ETL breakage likely
  MEDIUM: order_items (new table) — ETL may want to ingest
  LOW:    products.updated_at default changed

Recommend: alert BI team before syncing. Review ETL that reads orders.legacy_status.
```

## Notes & gotchas

- The `schema_sync` PROJECT.yaml block must be present before first
  use. If it is missing, the script returns an error and shows the
  required structure.
- Credentials are referenced by *secret name* in PROJECT.yaml and
  resolved at runtime — never stored in plaintext.
- Always run `--sync --dry-run` and review the payloads before pushing
  to Open Metadata, especially after a migration containing breaking
  changes.
- Description generation uses Opus by default (`auto_describe.model`).
  In CI/CD, GitHub Models (free via `GITHUB_TOKEN`) or Anthropic API
  can be used instead; pass `--skip-describe` if neither is available.
- **If it fails:** sync partial failure → the result JSON lists which
  operations succeeded/failed; retry the failed ones by re-running
  `--sync`. Connection failure → verify secret names resolve correctly.
  Debug with `~/.claude/scripts/db-schema-sync.sh --diff` in isolation
  before attempting sync.
