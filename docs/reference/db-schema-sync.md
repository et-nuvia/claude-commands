# Database Schema Sync & Open Metadata Integration

**Purpose**: Automatically detect database schema changes during deployments and sync them to Open Metadata so the BI team's ETL pipelines and reports stay aligned with the actual database structure.

**Philosophy**: Schema changes should never be a surprise. Every column added, dropped, or modified gets detected, documented with auto-generated descriptions, and pushed to the data catalog before the BI team discovers breakage in their reports.

---

## Overview

| Component | Path | Purpose |
|-----------|------|---------|
| Command | `commands/db-schema-sync.md` | LLM orchestrator for interactive use (`/db-schema-sync`) |
| Core Script | `scripts/db-schema-sync.sh` | Schema snapshot, diff, describe, and sync engine |
| Description Generator | `scripts/generate-schema-descriptions.sh` | Calls LLM API in CI/CD to auto-generate descriptions |

### What It Detects

| Change Type | Detection | ETL Risk |
|-------------|-----------|----------|
| Table added | New table in after snapshot | Low - new data source |
| Table dropped | Missing from after snapshot | High - breaks existing ETL |
| Column added | New column on existing table | Low - new field available |
| Column dropped | Missing from after snapshot | High - breaks transformations |
| Column type changed | data_type/full_type differs | High - type mismatch in ETL |
| Column nullability changed | nullable flag differs | Medium - may break NOT NULL assumptions |
| Column default changed | default_value differs | Low - informational |
| Index added/dropped | Index list differs | Low - query performance only |

---

## Architecture

```
                    CI/CD Pipeline
                         |
    +--------------------+--------------------+
    |                    |                    |
    v                    v                    v
 SNAPSHOT             SNAPSHOT             DIFF
 (before)             (after)           (compare)
    |                    |                    |
    v                    v                    v
 before.json         after.json         changeset.json
                                             |
                                    +--------+--------+
                                    |                 |
                                    v                 v
                               DESCRIBE            SYNC
                            (LLM generates      (push to Open
                             descriptions)       Metadata API)
                                    |                 |
                                    v                 v
                            descriptions.json   Open Metadata
                                                  Catalog
```

---

## Configuration (PROJECT.yaml)

Add the `schema_sync` section to your project's `PROJECT.yaml`:

```yaml
schema_sync:
  databases:
    app:
      host_secret: DATABASE_HOST           # Secret name (not the value)
      port: 3306
      name_secret: DATABASE_NAME
      user_secret: DATABASE_USER
      pass_secret: DATABASE_PASSWORD
      type: mysql                          # mysql or postgres
    analytics:
      host_secret: ANALYTICS_DB_HOST
      port: 3306
      name_secret: ANALYTICS_DB_NAME
      user_secret: ANALYTICS_DB_USER
      pass_secret: ANALYTICS_DB_PASSWORD
      type: mysql

  open_metadata:
    url_secret: OPEN_METADATA_URL          # Secret name for OM base URL
    token_secret: OPEN_METADATA_TOKEN      # Secret name for OM auth token
    service_name: production-mysql         # OM database service name
    database_service_type: Mysql           # Mysql, Postgres, etc.

  auto_describe:
    enabled: true                          # Auto-generate descriptions
    model: claude-sonnet-4-6                 # Model for description generation
    context_file: docs/domain-glossary.md  # Optional: business terminology reference
```

**Key points**:
- All database credentials and Open Metadata credentials are secret _names_, not values
- Secrets are resolved at runtime from your configured backend (AWS Secrets Manager or Infisical)
- `context_file` is optional but recommended - it gives the LLM domain knowledge for better descriptions

---

## Script Reference

### db-schema-sync.sh

Core engine with section-based execution. Follows the standard `--json`/`--raw` output pattern.

**Output modes**:
- `--json` (default): Structured JSON for LLM/pipeline consumption
- `--raw`: Verbose colored output for human debugging

**Sections**:

| Flag | Section | Description |
|------|---------|-------------|
| `--snapshot --before` | Snapshot | Capture current schema state (pre-migration) |
| `--snapshot --after` | Snapshot | Capture new schema state (post-migration) |
| `--diff` | Diff | Compare before/after, produce `changeset.json` |
| `--describe` | Describe | Generate LLM prompt + template for descriptions |
| `--sync` | Sync | Push changeset to Open Metadata API |
| `--full` | Full | After-snapshot + diff + describe (if enabled) + sync |

**Additional options**:

| Flag | Purpose |
|------|---------|
| `--snapshot-dir <dir>` | Override snapshot directory (default: `/tmp/db-schema-sync`) |
| `--changeset <path>` | Use existing changeset file for sync |
| `--descriptions <path>` | Use existing descriptions file for sync |
| `--db <name>` | Target specific database (`app`, `analytics`, or `all`) |
| `--dry-run` | Generate payloads but don't push to Open Metadata |
| `--skip-describe` | Skip description generation even if auto_describe is enabled |

**Combinable flags**: `--diff --sync` runs diff then sync in sequence.

### generate-schema-descriptions.sh

Standalone LLM API caller for CI/CD pipelines. Reads `describe-prompt.json` (generated by `--describe`), calls an LLM, and writes `descriptions.json`.

**Options**:

| Flag | Purpose |
|------|---------|
| `--provider <name>` | API provider: `anthropic` or `github` (auto-detected if omitted) |
| `--model <model>` | Model ID (default: from PROJECT.yaml or provider default) |
| `--snapshot-dir <dir>` | Snapshot directory containing prompt files |
| `--max-tokens <n>` | Max response tokens (default: 4096) |
| `--dry-run` | Print what would be sent without calling API |

**Provider auto-detection** (when `--provider` is omitted):
1. Running in GitHub Actions with `GITHUB_TOKEN` set? → `github`
2. `ANTHROPIC_API_KEY` set? → `anthropic`
3. Secrets manager configured? → tries to resolve `ANTHROPIC_API_KEY` from backend

---

## Intermediate Files

All files are stored in `--snapshot-dir` (default `/tmp/db-schema-sync`):

| File | Created By | Consumed By | Description |
|------|-----------|-------------|-------------|
| `{db}-before.json` | `--snapshot --before` | `--diff` | Full schema snapshot pre-migration |
| `{db}-after.json` | `--snapshot --after` | `--diff` | Full schema snapshot post-migration |
| `changeset.json` | `--diff` | `--sync`, `--describe` | Structured diff of all changes |
| `describe-prompt.json` | `--describe` | `generate-schema-descriptions.sh` | LLM prompt with schema context |
| `descriptions-template.json` | `--describe` | `generate-schema-descriptions.sh` | Empty template for LLM to fill |
| `descriptions.json` | `generate-schema-descriptions.sh` | `--sync` | Filled descriptions, merged into OM payloads |
| `om-payloads.json` | `--sync --dry-run` | (review) | Generated Open Metadata API payloads |

### Snapshot Schema

```json
{
  "database": "app",
  "type": "mysql",
  "actual_name": "myapp_production",
  "tag": "before",
  "snapshot_time": "2026-03-05T10:30:00-06:00",
  "table_count": 42,
  "tables": [
    {
      "name": "orders",
      "type": "BASE TABLE",
      "columns": [
        {
          "name": "id",
          "position": 1,
          "data_type": "bigint",
          "full_type": "bigint unsigned",
          "nullable": false,
          "key": "PRI",
          "extra": "auto_increment"
        }
      ],
      "indexes": [
        { "name": "PRIMARY", "unique": true, "columns": ["id"] }
      ]
    }
  ]
}
```

### Changeset Schema

```json
{
  "version": "a1b2c3d",
  "timestamp": "2026-03-05T10:35:00-06:00",
  "total_changes": 5,
  "databases": [
    {
      "database": "app",
      "tables_added": [ /* full table objects */ ],
      "tables_dropped": [ /* full table objects */ ],
      "tables_modified": [
        {
          "table": "orders",
          "columns_added": [ /* column objects */ ],
          "columns_dropped": [ /* column objects */ ],
          "columns_modified": [
            {
              "column": "status",
              "before": { "data_type": "varchar", "full_type": "varchar(20)" },
              "after": { "data_type": "varchar", "full_type": "varchar(50)" }
            }
          ]
        }
      ],
      "index_changes": [
        {
          "table": "orders",
          "indexes_added": [],
          "indexes_dropped": []
        }
      ],
      "summary": {
        "tables_added": 1,
        "tables_dropped": 0,
        "tables_modified": 2,
        "index_changes": 1
      }
    }
  ]
}
```

### Descriptions Schema

```json
[
  {
    "type": "table",
    "database": "app",
    "table": "order_items",
    "description": "Individual line items within customer orders, linking products to orders with quantity and pricing."
  },
  {
    "type": "column",
    "database": "app",
    "table": "order_items",
    "column": "unit_discount_pct",
    "description": "Percentage discount applied to this specific line item, before tax calculation."
  }
]
```

---

## Pipeline Integration

### GitHub Actions (Recommended)

Full example with free GitHub Models for descriptions:

```yaml
name: Deploy with Schema Sync

on:
  push:
    branches: [staging]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      models: read        # Required for free GitHub Models access

    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update && sudo apt-get install -y jq
          sudo wget -qO /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          sudo chmod +x /usr/bin/yq

      # ---- Schema Sync: Before ----
      - name: Schema snapshot (before migration)
        run: ~/.claude/scripts/db-schema-sync.sh --json --snapshot --before

      # ---- Deploy ----
      - name: Run database migrations
        run: ~/.claude/scripts/run-migrations.sh ${{ env.IMAGE }}

      # ---- Schema Sync: After + Diff ----
      - name: Schema snapshot (after migration)
        run: ~/.claude/scripts/db-schema-sync.sh --json --snapshot --after

      - name: Detect schema changes
        id: diff
        run: |
          OUTPUT=$(~/.claude/scripts/db-schema-sync.sh --json --diff)
          echo "changes=$(echo $OUTPUT | jq -r '.total_changes')" >> $GITHUB_OUTPUT

      # ---- Schema Sync: Describe (free via GitHub Models) ----
      - name: Generate schema descriptions
        if: steps.diff.outputs.changes != '0'
        run: |
          ~/.claude/scripts/db-schema-sync.sh --json --describe
          ~/.claude/scripts/generate-schema-descriptions.sh --provider github

      # ---- Schema Sync: Push to Open Metadata ----
      - name: Sync to Open Metadata
        if: steps.diff.outputs.changes != '0'
        run: ~/.claude/scripts/db-schema-sync.sh --json --sync
```

### GitHub Actions (Anthropic API)

Replace the describe step:

```yaml
      - name: Generate schema descriptions
        if: steps.diff.outputs.changes != '0'
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          ~/.claude/scripts/db-schema-sync.sh --json --describe
          ~/.claude/scripts/generate-schema-descriptions.sh --provider anthropic
```

### GitLab CI

```yaml
stages:
  - deploy
  - schema-sync

deploy:
  stage: deploy
  script:
    - ~/.claude/scripts/db-schema-sync.sh --json --snapshot --before
    - ~/.claude/scripts/run-migrations.sh $IMAGE
  artifacts:
    paths:
      - /tmp/db-schema-sync/

schema-sync:
  stage: schema-sync
  needs: [deploy]
  script:
    - ~/.claude/scripts/db-schema-sync.sh --json --snapshot --after
    - ~/.claude/scripts/db-schema-sync.sh --json --diff
    - ~/.claude/scripts/db-schema-sync.sh --json --describe
    - ~/.claude/scripts/generate-schema-descriptions.sh
    - ~/.claude/scripts/db-schema-sync.sh --json --sync
  allow_failure: true  # Don't block deployment if OM sync fails
```

### Minimal Pipeline (No Descriptions)

For projects that don't need auto-descriptions:

```yaml
      - name: Schema sync
        run: |
          ~/.claude/scripts/db-schema-sync.sh --json --snapshot --after
          ~/.claude/scripts/db-schema-sync.sh --json --diff --sync --skip-describe
```

---

## LLM Description Providers

### GitHub Models (Free)

GitHub provides free access to AI models through their [Models marketplace](https://github.com/marketplace/models).

| Aspect | Detail |
|--------|--------|
| Cost | Free (included with GitHub Actions) |
| Auth | Built-in `GITHUB_TOKEN` (no secrets needed) |
| Permission | `models: read` in job permissions |
| Endpoint | `https://models.inference.ai.azure.com/chat/completions` |
| Default model | `gpt-4o` |
| Latency | ~5-15 seconds for typical schema |

**Auto-detected** when `GITHUB_ACTIONS=true` and `GITHUB_TOKEN` is set.

### Anthropic API

| Aspect | Detail |
|--------|--------|
| Cost | Pay per token (~$0.01-0.05 per schema sync) |
| Auth | `ANTHROPIC_API_KEY` secret |
| Endpoint | `https://api.anthropic.com/v1/messages` |
| Default model | `claude-sonnet-4-6` |
| Latency | ~3-10 seconds for typical schema |

---

## Domain Glossary (context_file)

The optional `auto_describe.context_file` gives the LLM business context for better descriptions. Create a markdown file with your domain terminology:

```markdown
# Domain Glossary

## Business Terms
- **MRR**: Monthly Recurring Revenue
- **ARR**: Annual Recurring Revenue
- **Churn**: Customer cancellation or downgrade
- **SKU**: Stock Keeping Unit - unique product identifier
- **LTV**: Lifetime Value of a customer

## Data Conventions
- All monetary values are stored in cents (integer)
- Timestamps are UTC unless column name ends with `_local`
- Soft deletes use `deleted_at` (NULL = active)
- `owner_id` always references the `owners` table (property owners)

## Key Relationships
- owners -> properties -> units -> leases -> tenants
- owners -> invoices -> invoice_items
```

This context is included in the LLM prompt, resulting in descriptions like:
- "Monthly Recurring Revenue (MRR) calculated from active lease agreements, stored in cents."
- Instead of the generic: "Numeric value representing some revenue metric."

---

## Open Metadata API Operations

The sync step makes these API calls:

| Change | HTTP Method | Endpoint | Behavior |
|--------|------------|----------|----------|
| Table added | `PUT` | `/api/v1/tables` | Creates table entity with columns |
| Table dropped | `DELETE` | `/api/v1/tables/name/{fqn}?hardDelete=false` | Soft-deletes (preserves history) |
| Columns modified | `PATCH` | `/api/v1/tables/{id}` | JSON Patch on column list |
| Table not in OM | `PUT` | `/api/v1/tables` | Creates full table from after snapshot |

**FQN format**: `{service_name}.{database_name}.{schema_name}.{table_name}`

**Descriptions** are included in the `description` field of table and column payloads when `descriptions.json` is available.

---

## Interactive Use

Run `/db-schema-sync` in Claude Code for an interactive, guided workflow:

1. Validates PROJECT.yaml configuration
2. Takes before/after snapshots
3. Presents human-readable diff summary
4. Flags ETL breaking changes with risk levels
5. Generates descriptions using the LLM directly (no API call needed)
6. Dry-runs the sync for review
7. Pushes to Open Metadata on approval

---

## Troubleshooting

### "No databases configured"
Add `schema_sync.databases` section to PROJECT.yaml.

### "Failed to resolve secrets"
Check that secret names in PROJECT.yaml match your secrets manager. Verify with:
```bash
# AWS
aws secretsmanager get-secret-value --secret-id DATABASE_HOST

# Infisical
infisical secrets get DATABASE_HOST
```

### "Table not found in OM"
The sync step handles this gracefully - if a modified table doesn't exist in Open Metadata, it creates it from the after snapshot instead of patching.

### "API returned invalid JSON" (descriptions)
The description generator tries to extract JSON from the LLM response even if it includes markdown fences. If it still fails, check `describe-raw-response.txt` in the snapshot directory. Common causes:
- Model returned explanation text alongside JSON
- Response was truncated (increase `--max-tokens`)

### Debugging
Use `--raw` mode for verbose colored output:
```bash
~/.claude/scripts/db-schema-sync.sh --raw --snapshot --before
```

---

## Security Considerations

- Database credentials are never logged or written to intermediate files
- Credentials are resolved from the secrets manager at runtime and held only in memory
- Open Metadata auth tokens follow the same pattern
- Snapshot files contain schema metadata only (no row data)
- The `--dry-run` flag allows reviewing API payloads before sending
- Dropped tables use soft-delete in Open Metadata (recoverable)
