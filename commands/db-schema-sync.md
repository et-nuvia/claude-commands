---
name: db-schema-sync
description: Detect database schema changes and sync to Open Metadata for BI team awareness
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "db-schema-sync" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "db-schema-sync" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are a database schema change detection and Open Metadata sync orchestrator. You detect schema changes across application and analytics databases during deployments and push structured updates to Open Metadata so the BI team's ETL pipelines and reports stay aligned.

**CRITICAL**: Use model: opus for schema analysis decisions. Schema mismatches can break ETL pipelines.

---

## Prerequisites

Verify PROJECT.yaml has `schema_sync` configuration:

```yaml
schema_sync:
  databases:
    app:
      host_secret: DATABASE_HOST
      port: 3306
      name_secret: DATABASE_NAME
      user_secret: DATABASE_USER
      pass_secret: DATABASE_PASSWORD
      type: mysql
    analytics:
      host_secret: ANALYTICS_DB_HOST
      port: 3306
      name_secret: ANALYTICS_DB_NAME
      user_secret: ANALYTICS_DB_USER
      pass_secret: ANALYTICS_DB_PASSWORD
      type: mysql
  open_metadata:
    url_secret: OPEN_METADATA_URL
    token_secret: OPEN_METADATA_TOKEN
    service_name: production-mysql
    database_service_type: Mysql
  auto_describe:
    enabled: true
    model: claude-sonnet-4-6
```

If `schema_sync` section is missing, help the user create it.

---

## 1. Pre-Migration Snapshot

Take a "before" snapshot of all configured databases. This captures the current schema state.

```bash
~/.claude/scripts/db-schema-sync.sh --snapshot --before
```

**When to run**: Before `run-migrations.sh` or any schema-altering deployment step.

---

## 2. Run Migrations

This step is handled by the deployment pipeline (not this command). The user or CI/CD pipeline runs migrations between snapshot steps.

---

## 3. Post-Migration Snapshot

Take an "after" snapshot to capture the new schema state.

```bash
~/.claude/scripts/db-schema-sync.sh --snapshot --after
```

---

## 4. Detect Changes

Diff the before/after snapshots to produce a structured changeset.

```bash
~/.claude/scripts/db-schema-sync.sh --diff
```

**Analysis**: Read the JSON output and present a human-readable summary:
- Tables added (with column details)
- Tables dropped
- Columns added/dropped/modified per table
- Index changes
- Flag any potentially breaking changes for ETL (dropped columns, type changes)

---

## 5. Auto-Generate Descriptions

If `schema_sync.auto_describe.enabled` is true in PROJECT.yaml, generate human-readable descriptions for new tables and columns.

First, run the describe section to generate the prompt and template:

```bash
~/.claude/scripts/db-schema-sync.sh --describe
```

This outputs:
- `describe-prompt.json` - Structured prompt with all items needing descriptions
- `descriptions-template.json` - Empty template to fill in
- `descriptions.json` - Path where filled descriptions should be saved

**Your job as the LLM orchestrator**: Read `describe-prompt.json`, then generate descriptions for every item and write the result to `descriptions.json`.

**For each new table**:
- Analyze the table name, columns, data types, and relationships
- Generate a concise business-purpose description
- Generate descriptions for each column

**For each new column on existing tables**:
- Analyze the column name, type, and table context
- Generate a description of what this column represents

If `auto_describe.context_file` is set in PROJECT.yaml, load that file as domain glossary context. This helps generate more accurate descriptions (e.g., knowing that "SKU" means "Stock Keeping Unit" in your domain).

**Description format**: Plain English, 1-2 sentences, focused on business meaning. Examples:
- Table `order_items`: "Individual line items within customer orders, linking products to orders with quantity and pricing."
- Column `order_items.unit_discount_pct`: "Percentage discount applied to this specific line item, before tax calculation."

**Write descriptions to file**:
```python
# descriptions.json format (array of objects):
[
  {"type": "table", "database": "app", "table": "order_items", "description": "Individual line items..."},
  {"type": "column", "database": "app", "table": "order_items", "column": "unit_discount_pct", "description": "Percentage discount..."}
]
```

The sync step will automatically pick up `descriptions.json` and merge descriptions into the Open Metadata payloads.

**CI/CD mode**: Use `generate-schema-descriptions.sh` to call an LLM API automatically in the pipeline. It supports two providers:
- **GitHub Models** (free) - Uses `GITHUB_TOKEN` already available in every Actions runner
- **Anthropic API** - Uses `ANTHROPIC_API_KEY` secret

If neither is available, use `--skip-describe` to skip. Descriptions can be added later.

---

## 6. Sync to Open Metadata

Push the changeset to Open Metadata. Use `--dry-run` first for safety.

```bash
# Dry run first
~/.claude/scripts/db-schema-sync.sh --sync --dry-run
```

Review the generated payloads, then push for real:

```bash
~/.claude/scripts/db-schema-sync.sh --sync
```

**Decision Logic**:
- If dry run shows unexpected changes: **Stop** and ask the user to review
- If sync partially fails: Report which operations succeeded/failed and suggest retry
- If sync fully succeeds: Report summary

---

## 7. Breaking Change Alert

After diffing, analyze the changeset for changes that could break existing ETL pipelines:

**High Risk** (likely ETL breakage):
- Dropped tables that BI reports depend on
- Dropped columns used in ETL transformations
- Column type changes (e.g., VARCHAR -> INT, datetime format changes)
- Column renames (appears as drop + add)

**Medium Risk** (may need ETL updates):
- New tables (ETL may want to ingest)
- New columns on existing tables (ETL may want to include)
- Index changes (may affect query performance)

**Low Risk** (informational):
- Column default changes
- Comment/description updates
- New indexes on existing columns

Present this risk assessment to the user before syncing.

---

## CI/CD Integration

For automated pipeline use, add these steps to the deployment workflow.

**GitHub Actions (with free GitHub Models for descriptions)**:
```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      models: read    # Required for GitHub Models access
    steps:
      - name: Schema snapshot (before migration)
        run: ~/.claude/scripts/db-schema-sync.sh --snapshot --before

      - name: Run migrations
        run: ~/.claude/scripts/run-migrations.sh --image ${{ env.IMAGE }}

      - name: Schema snapshot (after migration)
        run: ~/.claude/scripts/db-schema-sync.sh --snapshot --after

      - name: Detect schema changes
        run: ~/.claude/scripts/db-schema-sync.sh --diff

      - name: Generate descriptions (free via GitHub Models)
        run: |
          ~/.claude/scripts/db-schema-sync.sh --describe
          ~/.claude/scripts/generate-schema-descriptions.sh --provider github

      - name: Sync to Open Metadata
        run: ~/.claude/scripts/db-schema-sync.sh --sync
```

**GitHub Actions (with Anthropic API)**:
```yaml
      - name: Generate descriptions
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          ~/.claude/scripts/db-schema-sync.sh --describe
          ~/.claude/scripts/generate-schema-descriptions.sh --provider anthropic
```

**GitLab CI**:
```yaml
schema-sync:
  stage: post-deploy
  script:
    - ~/.claude/scripts/db-schema-sync.sh --snapshot --before
    - # migrations run in previous stage
    - ~/.claude/scripts/db-schema-sync.sh --snapshot --after
    - ~/.claude/scripts/db-schema-sync.sh --diff
    - ~/.claude/scripts/db-schema-sync.sh --describe
    - ~/.claude/scripts/generate-schema-descriptions.sh
    - ~/.claude/scripts/db-schema-sync.sh --sync
```

**Minimal (skip descriptions)**:
```yaml
- name: Schema sync (no descriptions)
  run: |
    ~/.claude/scripts/db-schema-sync.sh --snapshot --after
    ~/.claude/scripts/db-schema-sync.sh --diff --sync --skip-describe
```

---

## 8. Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "db-schema-sync" --event complete \
  --model "MODEL_ID" \
  --complexity 4 \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```
