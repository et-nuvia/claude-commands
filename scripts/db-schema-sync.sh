#!/usr/bin/env bash
set -euo pipefail

# db-schema-sync.sh - Detect database schema changes and sync to Open Metadata
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/db-schema-sync.sh [--json|--raw] [--full|--section] [options]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --snapshot:  Take schema snapshot of configured databases
#   --diff:      Compare two snapshots and generate changeset
#   --describe:  Generate descriptions for new tables/columns (outputs prompt for LLM)
#   --sync:      Push changeset to Open Metadata API
#   --full:      Run snapshot-before, snapshot-after, diff, describe, sync (default)
#
# Options:
#   --before:            Tag snapshot as "before" (pre-migration)
#   --after:             Tag snapshot as "after" (post-migration)
#   --snapshot-dir:      Directory for snapshot storage (default: /tmp/db-schema-sync)
#   --changeset:         Path to existing changeset JSON (for --sync only)
#   --descriptions:      Path to descriptions JSON (for --sync, merges into payloads)
#   --dry-run:           Generate changeset but don't push to Open Metadata
#   --db <name>:         Target specific database (app|analytics|all, default: all)
#   --skip-describe:     Skip description generation even if auto_describe is enabled
#
# CI/CD Integration:
#   # Pre-migration: capture current state
#   db-schema-sync.sh --json --snapshot --before
#
#   # Run migrations here...
#
#   # Post-migration: capture new state, diff, sync
#   db-schema-sync.sh --json --snapshot --after
#   db-schema-sync.sh --json --diff
#   db-schema-sync.sh --json --sync
#
#   # Or all-in-one (requires --before snapshot already taken):
#   db-schema-sync.sh --json --snapshot --after
#   db-schema-sync.sh --json --diff --sync
#
# PROJECT.yaml Configuration:
#   schema_sync:
#     databases:
#       app:
#         host_secret: DATABASE_HOST      # Secret name in secrets manager
#         port: 3306
#         name_secret: DATABASE_NAME      # Secret name for DB name
#         user_secret: DATABASE_USER      # Secret name for DB user
#         pass_secret: DATABASE_PASSWORD  # Secret name for DB password
#         type: mysql                     # mysql or postgres
#       analytics:
#         host_secret: ANALYTICS_DB_HOST
#         port: 3306
#         name_secret: ANALYTICS_DB_NAME
#         user_secret: ANALYTICS_DB_USER
#         pass_secret: ANALYTICS_DB_PASSWORD
#         type: mysql
#     open_metadata:
#       url_secret: OPEN_METADATA_URL           # Secret name for OM URL
#       token_secret: OPEN_METADATA_TOKEN       # Secret name for OM auth token
#       service_name: production-mysql           # OM service name for this DB cluster
#       database_service_type: Mysql             # Mysql, Postgres, etc.
#     auto_describe:
#       enabled: true                            # Auto-generate descriptions for new schema
#       model: claude-sonnet-4-6                   # Model for description generation
#       context_file: ""                         # Optional: path to domain glossary/context

# Global variables
OUTPUT_MODE="json"
SECTION="full"
SNAPSHOT_TAG=""
SNAPSHOT_DIR="/tmp/db-schema-sync"
CHANGESET_FILE=""
DRY_RUN=false
TARGET_DB="all"
DO_SYNC=false
DO_DESCRIBE=false
SKIP_DESCRIBE=false
DESCRIPTIONS_FILE=""

# Loaded from PROJECT.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Get a secret value - delegates to the project's secrets backend
get_secret_value() {
    local secret_name="$1"
    local value=""

    local backend
    backend=$(get_secrets_backend)

    case "$backend" in
        aws)
            # Try AWS Secrets Manager via CLI
            value=$(aws secretsmanager get-secret-value \
                --secret-id "$secret_name" \
                --query 'SecretString' \
                --output text 2>/dev/null || echo "")
            ;;
        infisical)
            # Try Infisical CLI
            value=$(infisical secrets get "$secret_name" --plain 2>/dev/null || echo "")
            ;;
        env)
            # Fallback: environment variable (for local dev / CI)
            value="${!secret_name:-}"
            ;;
        *)
            log "${YELLOW}Warning: Unknown secrets backend '$backend', trying env var${NC}"
            value="${!secret_name:-}"
            ;;
    esac

    echo "$value"
}

# Get list of configured database names from PROJECT.yaml
get_configured_databases() {
    yaml_get_array '.schema_sync.databases | keys' PROJECT.yaml
}

# Get database config value
get_db_config() {
    local db_name="$1"
    local key="$2"
    local default="${3:-}"
    get_config ".schema_sync.databases.${db_name}.${key}" "$default"
}

# Get Open Metadata config value
get_om_config() {
    local key="$1"
    local default="${2:-}"
    get_config ".schema_sync.open_metadata.${key}" "$default"
}

# Run a SQL query against a database
run_query() {
    local db_type="$1"
    local host="$2"
    local port="$3"
    local user="$4"
    local pass="$5"
    local dbname="$6"
    local query="$7"

    case "$db_type" in
        mysql)
            MYSQL_PWD="$pass" mysql -h "$host" -P "$port" -u "$user" "$dbname" \
                --batch --skip-column-names -e "$query" 2>/dev/null
            ;;
        postgres)
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$dbname" \
                -t -A -F $'\t' -c "$query" 2>/dev/null
            ;;
        *)
            log "${RED}Unsupported database type: $db_type${NC}"
            return 1
            ;;
    esac
}

# Snapshot schema for a single database
snapshot_database() {
    local db_name="$1"
    local tag="$2"
    local output_file="$3"

    local db_type host port user pass dbname

    db_type=$(get_db_config "$db_name" "type" "mysql")

    # Resolve secrets
    local host_secret port_val user_secret pass_secret name_secret
    host_secret=$(get_db_config "$db_name" "host_secret" "")
    port_val=$(get_db_config "$db_name" "port" "3306")
    user_secret=$(get_db_config "$db_name" "user_secret" "")
    pass_secret=$(get_db_config "$db_name" "pass_secret" "")
    name_secret=$(get_db_config "$db_name" "name_secret" "")

    if [[ -z "$host_secret" || -z "$user_secret" || -z "$pass_secret" || -z "$name_secret" ]]; then
        log "${RED}Missing secret configuration for database '$db_name'${NC}"
        return 1
    fi

    host=$(get_secret_value "$host_secret")
    user=$(get_secret_value "$user_secret")
    pass=$(get_secret_value "$pass_secret")
    dbname=$(get_secret_value "$name_secret")

    if [[ -z "$host" || -z "$user" || -z "$pass" || -z "$dbname" ]]; then
        log "${RED}Failed to resolve secrets for database '$db_name'${NC}"
        return 1
    fi

    log "${CYAN}Snapshotting $db_name ($db_type @ $host:$port_val/$dbname)${NC}"

    # Build schema snapshot as JSON
    local tables_json="[]"

    # Get all tables
    local table_query
    case "$db_type" in
        mysql)
            table_query="SELECT TABLE_NAME, TABLE_TYPE, TABLE_COMMENT
                         FROM information_schema.TABLES
                         WHERE TABLE_SCHEMA = '${dbname}'
                         ORDER BY TABLE_NAME"
            ;;
        postgres)
            table_query="SELECT table_name, table_type, ''
                         FROM information_schema.tables
                         WHERE table_schema = 'public'
                         ORDER BY table_name"
            ;;
    esac

    local tables
    tables=$(run_query "$db_type" "$host" "$port_val" "$user" "$pass" "$dbname" "$table_query")

    if [[ -z "$tables" ]]; then
        log "${YELLOW}No tables found in $db_name${NC}"
        echo '{"database": "'"$db_name"'", "type": "'"$db_type"'", "tag": "'"$tag"'", "tables": [], "snapshot_time": "'"$(date -Iseconds)"'"}' > "$output_file"
        return 0
    fi

    # For each table, get columns
    local all_tables="[]"

    while IFS=$'\t' read -r tbl_name tbl_type tbl_comment; do
        [[ -z "$tbl_name" ]] && continue

        local col_query
        case "$db_type" in
            mysql)
                col_query="SELECT COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT, IS_NULLABLE,
                                  DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION,
                                  NUMERIC_SCALE, COLUMN_TYPE, COLUMN_KEY, EXTRA, COLUMN_COMMENT
                           FROM information_schema.COLUMNS
                           WHERE TABLE_SCHEMA = '${dbname}' AND TABLE_NAME = '${tbl_name}'
                           ORDER BY ORDINAL_POSITION"
                ;;
            postgres)
                col_query="SELECT column_name, ordinal_position, column_default, is_nullable,
                                  data_type, character_maximum_length, numeric_precision,
                                  numeric_scale, udt_name, '', '', ''
                           FROM information_schema.columns
                           WHERE table_schema = 'public' AND table_name = '${tbl_name}'
                           ORDER BY ordinal_position"
                ;;
        esac

        local columns
        columns=$(run_query "$db_type" "$host" "$port_val" "$user" "$pass" "$dbname" "$col_query")

        local cols_json="[]"
        while IFS=$'\t' read -r col_name col_pos col_default col_nullable col_datatype col_maxlen col_precision col_scale col_fulltype col_key col_extra col_comment; do
            [[ -z "$col_name" ]] && continue

            cols_json=$(echo "$cols_json" | jq \
                --arg name "$col_name" \
                --arg pos "$col_pos" \
                --arg default "$col_default" \
                --arg nullable "$col_nullable" \
                --arg datatype "$col_datatype" \
                --arg maxlen "${col_maxlen:-}" \
                --arg precision "${col_precision:-}" \
                --arg scale "${col_scale:-}" \
                --arg fulltype "$col_fulltype" \
                --arg key "${col_key:-}" \
                --arg extra "${col_extra:-}" \
                --arg comment "${col_comment:-}" \
                '. + [{
                    name: $name,
                    position: ($pos | tonumber),
                    default_value: (if $default == "NULL" or $default == "" then null else $default end),
                    nullable: ($nullable == "YES"),
                    data_type: $datatype,
                    max_length: (if $maxlen == "" or $maxlen == "NULL" then null else ($maxlen | tonumber) end),
                    precision: (if $precision == "" or $precision == "NULL" then null else ($precision | tonumber) end),
                    scale: (if $scale == "" or $scale == "NULL" then null else ($scale | tonumber) end),
                    full_type: $fulltype,
                    key: (if $key == "" then null else $key end),
                    extra: (if $extra == "" then null else $extra end),
                    comment: (if $comment == "" then null else $comment end)
                }]')
        done <<< "$columns"

        # Get indexes
        local idx_query
        local indexes_json="[]"
        case "$db_type" in
            mysql)
                idx_query="SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)
                           FROM information_schema.STATISTICS
                           WHERE TABLE_SCHEMA = '${dbname}' AND TABLE_NAME = '${tbl_name}'
                           GROUP BY INDEX_NAME, NON_UNIQUE"
                ;;
            postgres)
                idx_query="SELECT i.relname, CASE WHEN ix.indisunique THEN 0 ELSE 1 END,
                                  string_agg(a.attname, ',' ORDER BY array_position(ix.indkey, a.attnum))
                           FROM pg_class t
                           JOIN pg_index ix ON t.oid = ix.indrelid
                           JOIN pg_class i ON i.oid = ix.indexrelid
                           JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
                           WHERE t.relname = '${tbl_name}' AND t.relkind = 'r'
                           GROUP BY i.relname, ix.indisunique"
                ;;
        esac

        local indexes
        indexes=$(run_query "$db_type" "$host" "$port_val" "$user" "$pass" "$dbname" "$idx_query")
        while IFS=$'\t' read -r idx_name idx_nonunique idx_columns; do
            [[ -z "$idx_name" ]] && continue
            indexes_json=$(echo "$indexes_json" | jq \
                --arg name "$idx_name" \
                --arg unique "$(if [[ "$idx_nonunique" == "0" ]]; then echo "true"; else echo "false"; fi)" \
                --arg columns "$idx_columns" \
                '. + [{name: $name, unique: ($unique == "true"), columns: ($columns | split(","))}]')
        done <<< "$indexes"

        all_tables=$(echo "$all_tables" | jq \
            --arg name "$tbl_name" \
            --arg type "$tbl_type" \
            --arg comment "${tbl_comment:-}" \
            --argjson columns "$cols_json" \
            --argjson indexes "$indexes_json" \
            '. + [{
                name: $name,
                type: $type,
                comment: (if $comment == "" then null else $comment end),
                columns: $columns,
                indexes: $indexes
            }]')

    done <<< "$tables"

    # Write snapshot
    jq -n \
        --arg database "$db_name" \
        --arg type "$db_type" \
        --arg tag "$tag" \
        --arg dbname "$dbname" \
        --arg snapshot_time "$(date -Iseconds)" \
        --argjson tables "$all_tables" \
        '{
            database: $database,
            type: $type,
            actual_name: $dbname,
            tag: $tag,
            snapshot_time: $snapshot_time,
            table_count: ($tables | length),
            tables: $tables
        }' > "$output_file"

    local count
    count=$(jq '.table_count' "$output_file")
    log "${GREEN}Snapshot complete: $count tables${NC}"
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section: Take schema snapshot
section_snapshot() {
    log "${BLUE}Taking Schema Snapshot (tag: $SNAPSHOT_TAG)${NC}"

    require_project_config

    if [[ -z "$SNAPSHOT_TAG" ]]; then
        exit_with_json "error" "Snapshot tag required" "Use --before or --after to tag the snapshot"
    fi

    mkdir -p "$SNAPSHOT_DIR"

    local databases
    databases=$(get_configured_databases)

    if [[ -z "$databases" ]]; then
        exit_with_json "error" "No databases configured" "Add schema_sync.databases section to PROJECT.yaml"
    fi

    local results="[]"
    local errors=0

    while IFS= read -r db_name; do
        [[ -z "$db_name" ]] && continue

        if [[ "$TARGET_DB" != "all" && "$TARGET_DB" != "$db_name" ]]; then
            continue
        fi

        local snapshot_file="${SNAPSHOT_DIR}/${db_name}-${SNAPSHOT_TAG}.json"

        if snapshot_database "$db_name" "$SNAPSHOT_TAG" "$snapshot_file"; then
            local table_count
            table_count=$(jq '.table_count' "$snapshot_file")
            results=$(echo "$results" | jq \
                --arg db "$db_name" \
                --arg file "$snapshot_file" \
                --arg count "$table_count" \
                '. + [{database: $db, file: $file, table_count: ($count | tonumber), status: "success"}]')
        else
            errors=$((errors + 1))
            results=$(echo "$results" | jq \
                --arg db "$db_name" \
                '. + [{database: $db, status: "error"}]')
        fi
    done <<< "$databases"

    local status="success"
    [[ $errors -gt 0 ]] && status="partial"

    local json
    json=$(jq -n \
        --arg status "$status" \
        --arg section "snapshot" \
        --arg tag "$SNAPSHOT_TAG" \
        --arg snapshot_dir "$SNAPSHOT_DIR" \
        --arg timestamp "$(date -Iseconds)" \
        --argjson results "$results" \
        --arg errors "$errors" \
        '{
            status: $status,
            section: $section,
            tag: $tag,
            snapshot_dir: $snapshot_dir,
            results: $results,
            error_count: ($errors | tonumber),
            timestamp: $timestamp
        }')
    log_json "$json"

    [[ $errors -gt 0 ]] && exit 1
    exit 0
}

# Section: Diff snapshots
section_diff() {
    log "${BLUE}Comparing Schema Snapshots${NC}"

    local databases
    databases=$(get_configured_databases)

    if [[ -z "$databases" ]]; then
        exit_with_json "error" "No databases configured"
    fi

    local all_changes="[]"
    local total_changes=0

    while IFS= read -r db_name; do
        [[ -z "$db_name" ]] && continue

        if [[ "$TARGET_DB" != "all" && "$TARGET_DB" != "$db_name" ]]; then
            continue
        fi

        local before_file="${SNAPSHOT_DIR}/${db_name}-before.json"
        local after_file="${SNAPSHOT_DIR}/${db_name}-after.json"

        if [[ ! -f "$before_file" ]]; then
            log "${RED}Missing before snapshot for $db_name${NC}"
            continue
        fi
        if [[ ! -f "$after_file" ]]; then
            log "${RED}Missing after snapshot for $db_name${NC}"
            continue
        fi

        log "${CYAN}Diffing $db_name...${NC}"

        local changes
        changes=$(diff_snapshots "$before_file" "$after_file" "$db_name")

        local change_count
        change_count=$(echo "$changes" | jq '.total_changes')
        total_changes=$((total_changes + change_count))

        all_changes=$(echo "$all_changes" | jq --argjson ch "$changes" '. + [$ch]')

    done <<< "$databases"

    # Write changeset to file
    CHANGESET_FILE="${SNAPSHOT_DIR}/changeset.json"
    jq -n \
        --argjson databases "$all_changes" \
        --arg total "$total_changes" \
        --arg timestamp "$(date -Iseconds)" \
        --arg version "$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
        '{
            version: $version,
            timestamp: $timestamp,
            total_changes: ($total | tonumber),
            databases: $databases
        }' > "$CHANGESET_FILE"

    local status="success"
    [[ $total_changes -eq 0 ]] && status="no_changes"

    local json
    json=$(jq -n \
        --arg status "$status" \
        --arg section "diff" \
        --arg changeset_file "$CHANGESET_FILE" \
        --arg total "$total_changes" \
        --arg timestamp "$(date -Iseconds)" \
        --argjson databases "$all_changes" \
        '{
            status: $status,
            section: $section,
            changeset_file: $changeset_file,
            total_changes: ($total | tonumber),
            databases: $databases,
            timestamp: $timestamp
        }')
    log_json "$json"

    if [[ "$DO_SYNC" == true ]]; then
        section_sync
    else
        exit 0
    fi
}

# Diff two snapshot files and produce a structured changeset
diff_snapshots() {
    local before_file="$1"
    local after_file="$2"
    local db_name="$3"

    local before_tables after_tables
    before_tables=$(jq -r '.tables[].name' "$before_file" | sort)
    after_tables=$(jq -r '.tables[].name' "$after_file" | sort)

    local tables_added tables_dropped tables_common
    tables_added=$(comm -13 <(echo "$before_tables") <(echo "$after_tables"))
    tables_dropped=$(comm -23 <(echo "$before_tables") <(echo "$after_tables"))
    tables_common=$(comm -12 <(echo "$before_tables") <(echo "$after_tables"))

    local changes_json='{}'
    changes_json=$(echo "$changes_json" | jq --arg db "$db_name" '.database = $db')

    # Tables added
    local added_arr="[]"
    while IFS= read -r tbl; do
        [[ -z "$tbl" ]] && continue
        local tbl_info
        tbl_info=$(jq --arg name "$tbl" '.tables[] | select(.name == $name)' "$after_file")
        added_arr=$(echo "$added_arr" | jq --argjson t "$tbl_info" '. + [$t]')
    done <<< "$tables_added"

    # Tables dropped
    local dropped_arr="[]"
    while IFS= read -r tbl; do
        [[ -z "$tbl" ]] && continue
        local tbl_info
        tbl_info=$(jq --arg name "$tbl" '.tables[] | select(.name == $name)' "$before_file")
        dropped_arr=$(echo "$dropped_arr" | jq --argjson t "$tbl_info" '. + [$t]')
    done <<< "$tables_dropped"

    # Tables modified (column-level diff)
    local modified_arr="[]"
    while IFS= read -r tbl; do
        [[ -z "$tbl" ]] && continue

        local before_cols after_cols
        before_cols=$(jq --arg name "$tbl" '[.tables[] | select(.name == $name) | .columns[].name] | sort | .[]' "$before_file" | tr -d '"')
        after_cols=$(jq --arg name "$tbl" '[.tables[] | select(.name == $name) | .columns[].name] | sort | .[]' "$after_file" | tr -d '"')

        local cols_added cols_dropped cols_common
        cols_added=$(comm -13 <(echo "$before_cols") <(echo "$after_cols"))
        cols_dropped=$(comm -23 <(echo "$before_cols") <(echo "$after_cols"))
        cols_common=$(comm -12 <(echo "$before_cols") <(echo "$after_cols"))

        # Check for modified columns (same name, different attributes)
        local cols_modified="[]"
        while IFS= read -r col; do
            [[ -z "$col" ]] && continue

            local before_col after_col
            before_col=$(jq --arg tbl "$tbl" --arg col "$col" \
                '.tables[] | select(.name == $tbl) | .columns[] | select(.name == $col)' "$before_file")
            after_col=$(jq --arg tbl "$tbl" --arg col "$col" \
                '.tables[] | select(.name == $tbl) | .columns[] | select(.name == $col)' "$after_file")

            # Compare key attributes
            local before_sig after_sig
            before_sig=$(echo "$before_col" | jq -S '{data_type, full_type, nullable, default_value, key, extra}')
            after_sig=$(echo "$after_col" | jq -S '{data_type, full_type, nullable, default_value, key, extra}')

            if [[ "$before_sig" != "$after_sig" ]]; then
                cols_modified=$(echo "$cols_modified" | jq \
                    --arg col "$col" \
                    --argjson before "$before_col" \
                    --argjson after "$after_col" \
                    '. + [{column: $col, before: $before, after: $after}]')
            fi
        done <<< "$cols_common"

        # Build column adds/drops as JSON arrays
        local cols_added_arr="[]"
        while IFS= read -r col; do
            [[ -z "$col" ]] && continue
            local col_info
            col_info=$(jq --arg tbl "$tbl" --arg col "$col" \
                '.tables[] | select(.name == $tbl) | .columns[] | select(.name == $col)' "$after_file")
            cols_added_arr=$(echo "$cols_added_arr" | jq --argjson c "$col_info" '. + [$c]')
        done <<< "$cols_added"

        local cols_dropped_arr="[]"
        while IFS= read -r col; do
            [[ -z "$col" ]] && continue
            local col_info
            col_info=$(jq --arg tbl "$tbl" --arg col "$col" \
                '.tables[] | select(.name == $tbl) | .columns[] | select(.name == $col)' "$before_file")
            cols_dropped_arr=$(echo "$cols_dropped_arr" | jq --argjson c "$col_info" '. + [$c]')
        done <<< "$cols_dropped"

        # Only add to modified if there are actual changes
        local has_changes
        has_changes=$(echo "$cols_added_arr $cols_dropped_arr $cols_modified" | jq -s '.[0] + .[1] + .[2] | length')
        if [[ "$has_changes" -gt 0 ]]; then
            modified_arr=$(echo "$modified_arr" | jq \
                --arg tbl "$tbl" \
                --argjson added "$cols_added_arr" \
                --argjson dropped "$cols_dropped_arr" \
                --argjson modified "$cols_modified" \
                '. + [{
                    table: $tbl,
                    columns_added: $added,
                    columns_dropped: $dropped,
                    columns_modified: $modified
                }]')
        fi
    done <<< "$tables_common"

    # Index changes (simplified: compare index lists per common table)
    local index_changes="[]"
    while IFS= read -r tbl; do
        [[ -z "$tbl" ]] && continue

        local before_idx after_idx
        before_idx=$(jq -S --arg name "$tbl" '.tables[] | select(.name == $name) | .indexes // []' "$before_file")
        after_idx=$(jq -S --arg name "$tbl" '.tables[] | select(.name == $name) | .indexes // []' "$after_file")

        if [[ "$before_idx" != "$after_idx" ]]; then
            local before_names after_names
            before_names=$(echo "$before_idx" | jq -r '.[].name' | sort)
            after_names=$(echo "$after_idx" | jq -r '.[].name' | sort)

            local idx_added idx_dropped
            idx_added=$(comm -13 <(echo "$before_names") <(echo "$after_names"))
            idx_dropped=$(comm -23 <(echo "$before_names") <(echo "$after_names"))

            if [[ -n "$idx_added" || -n "$idx_dropped" ]]; then
                local idx_added_arr="[]"
                while IFS= read -r idx; do
                    [[ -z "$idx" ]] && continue
                    local idx_info
                    idx_info=$(echo "$after_idx" | jq --arg name "$idx" '.[] | select(.name == $name)')
                    idx_added_arr=$(echo "$idx_added_arr" | jq --argjson i "$idx_info" '. + [$i]')
                done <<< "$idx_added"

                local idx_dropped_arr="[]"
                while IFS= read -r idx; do
                    [[ -z "$idx" ]] && continue
                    local idx_info
                    idx_info=$(echo "$before_idx" | jq --arg name "$idx" '.[] | select(.name == $name)')
                    idx_dropped_arr=$(echo "$idx_dropped_arr" | jq --argjson i "$idx_info" '. + [$i]')
                done <<< "$idx_dropped"

                index_changes=$(echo "$index_changes" | jq \
                    --arg tbl "$tbl" \
                    --argjson added "$idx_added_arr" \
                    --argjson dropped "$idx_dropped_arr" \
                    '. + [{table: $tbl, indexes_added: $added, indexes_dropped: $dropped}]')
            fi
        fi
    done <<< "$tables_common"

    # Count total changes
    local total
    total=$(jq -n \
        --argjson added "$added_arr" \
        --argjson dropped "$dropped_arr" \
        --argjson modified "$modified_arr" \
        --argjson indexes "$index_changes" \
        '($added | length) + ($dropped | length) + ($modified | length) + ($indexes | length)')

    # Assemble result
    jq -n \
        --arg db "$db_name" \
        --argjson tables_added "$added_arr" \
        --argjson tables_dropped "$dropped_arr" \
        --argjson tables_modified "$modified_arr" \
        --argjson index_changes "$index_changes" \
        --arg total "$total" \
        '{
            database: $db,
            tables_added: $tables_added,
            tables_dropped: $tables_dropped,
            tables_modified: $tables_modified,
            index_changes: $index_changes,
            total_changes: ($total | tonumber),
            summary: {
                tables_added: ($tables_added | length),
                tables_dropped: ($tables_dropped | length),
                tables_modified: ($tables_modified | length),
                index_changes: ($index_changes | length)
            }
        }'
}

# Section: Generate description prompt for new schema elements
section_describe() {
    log "${BLUE}Generating Description Prompts for New Schema Elements${NC}"

    # Load changeset
    if [[ -z "$CHANGESET_FILE" ]]; then
        CHANGESET_FILE="${SNAPSHOT_DIR}/changeset.json"
    fi

    if [[ ! -f "$CHANGESET_FILE" ]]; then
        exit_with_json "error" "No changeset file found" "Run --diff first"
    fi

    local total_changes
    total_changes=$(jq '.total_changes' "$CHANGESET_FILE")

    if [[ "$total_changes" -eq 0 ]]; then
        exit_with_json "success" "No schema changes - nothing to describe"
    fi

    # Check auto_describe config
    local auto_describe_enabled
    auto_describe_enabled=$(get_config ".schema_sync.auto_describe.enabled" "false")
    local context_file
    context_file=$(get_config ".schema_sync.auto_describe.context_file" "")

    # Load optional domain context/glossary
    local domain_context=""
    if [[ -n "$context_file" && -f "$context_file" ]]; then
        domain_context=$(cat "$context_file")
        log "${CYAN}Loaded domain context from $context_file${NC}"
    fi

    # Build a structured prompt that captures all new schema elements needing descriptions
    local prompt_data
    prompt_data=$(build_description_prompt "$CHANGESET_FILE" "$domain_context")

    # Write prompt file for LLM consumption
    local prompt_file="${SNAPSHOT_DIR}/describe-prompt.json"
    echo "$prompt_data" > "$prompt_file"

    # Write an empty descriptions template that the LLM should fill in
    local template_file="${SNAPSHOT_DIR}/descriptions-template.json"
    generate_descriptions_template "$CHANGESET_FILE" > "$template_file"

    # Set the descriptions file path for downstream use
    DESCRIPTIONS_FILE="${SNAPSHOT_DIR}/descriptions.json"

    local items_count
    items_count=$(echo "$prompt_data" | jq '.items_needing_descriptions')

    local json
    json=$(jq -n \
        --arg status "success" \
        --arg section "describe" \
        --arg prompt_file "$prompt_file" \
        --arg template_file "$template_file" \
        --arg descriptions_file "$DESCRIPTIONS_FILE" \
        --arg items_count "$items_count" \
        --arg auto_describe "$auto_describe_enabled" \
        --arg timestamp "$(date -Iseconds)" \
        '{
            status: $status,
            section: $section,
            items_needing_descriptions: ($items_count | tonumber),
            auto_describe_enabled: ($auto_describe == "true"),
            prompt_file: $prompt_file,
            template_file: $template_file,
            descriptions_file: $descriptions_file,
            instructions: "Fill in descriptions-template.json and save as descriptions.json. The LLM command will do this automatically if auto_describe is enabled.",
            timestamp: $timestamp
        }')
    log_json "$json"

    # Don't exit if we're chaining into sync
    if [[ "$DO_SYNC" != true ]]; then
        exit 0
    fi
}

# Build a structured prompt with all schema elements needing descriptions
build_description_prompt() {
    local changeset_file="$1"
    local domain_context="$2"

    local items="[]"
    local item_count=0

    local db_count
    db_count=$(jq '.databases | length' "$changeset_file")

    for ((i=0; i<db_count; i++)); do
        local db_name
        db_name=$(jq -r ".databases[$i].database" "$changeset_file")

        # New tables need table + column descriptions
        local added_count
        added_count=$(jq ".databases[$i].tables_added | length" "$changeset_file")
        for ((j=0; j<added_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_added[$j].name" "$changeset_file")

            local columns_summary
            columns_summary=$(jq -r "[.databases[$i].tables_added[$j].columns[] |
                \"\(.name) (\(.full_type))\"] | join(\", \")" "$changeset_file")

            # Add table description request
            items=$(echo "$items" | jq \
                --arg db "$db_name" \
                --arg table "$table_name" \
                --arg columns "$columns_summary" \
                '. + [{
                    type: "table",
                    database: $db,
                    table: $table,
                    columns_summary: $columns,
                    instruction: "Describe the business purpose of this table in 1-2 sentences."
                }]')
            item_count=$((item_count + 1))

            # Add column description requests
            local col_count
            col_count=$(jq ".databases[$i].tables_added[$j].columns | length" "$changeset_file")
            for ((k=0; k<col_count; k++)); do
                local col_name col_type
                col_name=$(jq -r ".databases[$i].tables_added[$j].columns[$k].name" "$changeset_file")
                col_type=$(jq -r ".databases[$i].tables_added[$j].columns[$k].full_type" "$changeset_file")

                items=$(echo "$items" | jq \
                    --arg db "$db_name" \
                    --arg table "$table_name" \
                    --arg column "$col_name" \
                    --arg coltype "$col_type" \
                    '. + [{
                        type: "column",
                        database: $db,
                        table: $table,
                        column: $column,
                        data_type: $coltype,
                        instruction: "Describe what this column represents in 1 sentence."
                    }]')
                item_count=$((item_count + 1))
            done
        done

        # New columns on existing tables
        local mod_count
        mod_count=$(jq ".databases[$i].tables_modified | length" "$changeset_file")
        for ((j=0; j<mod_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_modified[$j].table" "$changeset_file")

            local cols_added_count
            cols_added_count=$(jq ".databases[$i].tables_modified[$j].columns_added | length" "$changeset_file")
            for ((k=0; k<cols_added_count; k++)); do
                local col_name col_type
                col_name=$(jq -r ".databases[$i].tables_modified[$j].columns_added[$k].name" "$changeset_file")
                col_type=$(jq -r ".databases[$i].tables_modified[$j].columns_added[$k].full_type" "$changeset_file")

                items=$(echo "$items" | jq \
                    --arg db "$db_name" \
                    --arg table "$table_name" \
                    --arg column "$col_name" \
                    --arg coltype "$col_type" \
                    '. + [{
                        type: "column",
                        database: $db,
                        table: $table,
                        column: $column,
                        data_type: $coltype,
                        instruction: "Describe what this new column represents in 1 sentence."
                    }]')
                item_count=$((item_count + 1))
            done
        done
    done

    jq -n \
        --argjson items "$items" \
        --arg count "$item_count" \
        --arg domain_context "$domain_context" \
        '{
            items_needing_descriptions: ($count | tonumber),
            domain_context: (if $domain_context == "" then null else $domain_context end),
            system_prompt: "You are a database documentation expert. Generate clear, concise business-oriented descriptions for database schema elements. Focus on WHAT the data represents and WHY it exists, not technical implementation. Use plain English suitable for BI analysts and report builders.",
            items: $items
        }'
}

# Generate a blank descriptions template matching the changeset structure
generate_descriptions_template() {
    local changeset_file="$1"

    local descriptions="[]"
    local db_count
    db_count=$(jq '.databases | length' "$changeset_file")

    for ((i=0; i<db_count; i++)); do
        local db_name
        db_name=$(jq -r ".databases[$i].database" "$changeset_file")

        # New tables
        local added_count
        added_count=$(jq ".databases[$i].tables_added | length" "$changeset_file")
        for ((j=0; j<added_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_added[$j].name" "$changeset_file")

            descriptions=$(echo "$descriptions" | jq \
                --arg db "$db_name" \
                --arg table "$table_name" \
                '. + [{type: "table", database: $db, table: $table, description: ""}]')

            local col_count
            col_count=$(jq ".databases[$i].tables_added[$j].columns | length" "$changeset_file")
            for ((k=0; k<col_count; k++)); do
                local col_name
                col_name=$(jq -r ".databases[$i].tables_added[$j].columns[$k].name" "$changeset_file")
                descriptions=$(echo "$descriptions" | jq \
                    --arg db "$db_name" \
                    --arg table "$table_name" \
                    --arg column "$col_name" \
                    '. + [{type: "column", database: $db, table: $table, column: $column, description: ""}]')
            done
        done

        # New columns on modified tables
        local mod_count
        mod_count=$(jq ".databases[$i].tables_modified | length" "$changeset_file")
        for ((j=0; j<mod_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_modified[$j].table" "$changeset_file")

            local cols_added_count
            cols_added_count=$(jq ".databases[$i].tables_modified[$j].columns_added | length" "$changeset_file")
            for ((k=0; k<cols_added_count; k++)); do
                local col_name
                col_name=$(jq -r ".databases[$i].tables_modified[$j].columns_added[$k].name" "$changeset_file")
                descriptions=$(echo "$descriptions" | jq \
                    --arg db "$db_name" \
                    --arg table "$table_name" \
                    --arg column "$col_name" \
                    '. + [{type: "column", database: $db, table: $table, column: $column, description: ""}]')
            done
        done
    done

    echo "$descriptions" | jq '.'
}

# Section: Sync changeset to Open Metadata
section_sync() {
    log "${BLUE}Syncing Schema Changes to Open Metadata${NC}"

    require_project_config

    # Load changeset
    if [[ -z "$CHANGESET_FILE" ]]; then
        CHANGESET_FILE="${SNAPSHOT_DIR}/changeset.json"
    fi

    if [[ ! -f "$CHANGESET_FILE" ]]; then
        exit_with_json "error" "No changeset file found" "Run --diff first or provide --changeset <path>"
    fi

    local total_changes
    total_changes=$(jq '.total_changes' "$CHANGESET_FILE")

    if [[ "$total_changes" -eq 0 ]]; then
        exit_with_json "success" "No schema changes to sync" "Database schema unchanged"
    fi

    # Load descriptions if available
    if [[ -z "$DESCRIPTIONS_FILE" ]]; then
        DESCRIPTIONS_FILE="${SNAPSHOT_DIR}/descriptions.json"
    fi
    local has_descriptions=false
    if [[ -f "$DESCRIPTIONS_FILE" ]]; then
        has_descriptions=true
        log "${CYAN}Loading descriptions from $DESCRIPTIONS_FILE${NC}"
    fi

    # Get Open Metadata configuration
    local om_url_secret om_token_secret om_service_name om_service_type
    om_url_secret=$(get_om_config "url_secret" "")
    om_token_secret=$(get_om_config "token_secret" "")
    om_service_name=$(get_om_config "service_name" "")
    om_service_type=$(get_om_config "database_service_type" "Mysql")

    if [[ -z "$om_url_secret" || -z "$om_token_secret" || -z "$om_service_name" ]]; then
        exit_with_json "error" "Open Metadata not configured" "Add schema_sync.open_metadata section to PROJECT.yaml"
    fi

    local om_url om_token
    om_url=$(get_secret_value "$om_url_secret")
    om_token=$(get_secret_value "$om_token_secret")

    if [[ -z "$om_url" || -z "$om_token" ]]; then
        exit_with_json "error" "Failed to resolve Open Metadata credentials"
    fi

    # Remove trailing slash from URL
    om_url="${om_url%/}"

    if [[ "$DRY_RUN" == true ]]; then
        log "${YELLOW}DRY RUN - would sync $total_changes changes to $om_url${NC}"

        # Generate the API payloads but don't send
        local payloads_file="${SNAPSHOT_DIR}/om-payloads.json"
        generate_om_payloads "$CHANGESET_FILE" "$om_service_name" "$om_service_type" > "$payloads_file"

        local json
        json=$(jq -n \
            --arg status "dry_run" \
            --arg section "sync" \
            --arg total "$total_changes" \
            --arg payloads_file "$payloads_file" \
            --arg om_url "$om_url" \
            --arg service_name "$om_service_name" \
            --arg timestamp "$(date -Iseconds)" \
            '{
                status: $status,
                section: $section,
                total_changes: ($total | tonumber),
                payloads_file: $payloads_file,
                open_metadata_url: $om_url,
                service_name: $service_name,
                message: "Dry run complete - payloads generated but not sent",
                timestamp: $timestamp
            }')
        log_json "$json"
        exit 0
    fi

    # Push changes to Open Metadata
    local sync_results
    sync_results=$(push_to_open_metadata "$CHANGESET_FILE" "$om_url" "$om_token" "$om_service_name" "$om_service_type")

    local sync_status
    sync_status=$(echo "$sync_results" | jq -r '.status')

    local json
    json=$(jq -n \
        --arg status "$sync_status" \
        --arg section "sync" \
        --arg total "$total_changes" \
        --arg om_url "$om_url" \
        --arg service_name "$om_service_name" \
        --arg timestamp "$(date -Iseconds)" \
        --argjson results "$sync_results" \
        '{
            status: $status,
            section: $section,
            total_changes: ($total | tonumber),
            open_metadata_url: $om_url,
            service_name: $service_name,
            sync_results: $results,
            timestamp: $timestamp
        }')
    log_json "$json"

    if [[ "$sync_status" != "success" ]]; then
        exit 1
    fi
    exit 0
}

# Generate Open Metadata API payloads from changeset
generate_om_payloads() {
    local changeset_file="$1"
    local service_name="$2"
    local service_type="$3"

    local payloads="[]"

    # Process each database in the changeset
    local db_count
    db_count=$(jq '.databases | length' "$changeset_file")

    for ((i=0; i<db_count; i++)); do
        local db_name
        db_name=$(jq -r ".databases[$i].database" "$changeset_file")

        # Get actual database name from the after snapshot
        local actual_db_name="$db_name"
        local after_file="${SNAPSHOT_DIR}/${db_name}-after.json"
        if [[ -f "$after_file" ]]; then
            actual_db_name=$(jq -r '.actual_name // .database' "$after_file")
        fi

        # Tables added - create table entities
        local added_count
        added_count=$(jq ".databases[$i].tables_added | length" "$changeset_file")
        for ((j=0; j<added_count; j++)); do
            local table_name columns_payload
            table_name=$(jq -r ".databases[$i].tables_added[$j].name" "$changeset_file")

            columns_payload=$(jq "[.databases[$i].tables_added[$j].columns[] | {
                name: .name,
                dataType: (.data_type | ascii_upcase),
                dataTypeDisplay: .full_type,
                dataLength: .max_length,
                constraint: (if .key == \"PRI\" then \"PRIMARY_KEY\" elif .key == \"UNI\" then \"UNIQUE\" else null end),
                ordinalPosition: .position,
                description: .comment
            }]" "$changeset_file")

            local payload
            payload=$(jq -n \
                --arg name "$table_name" \
                --arg fqn "${service_name}.${actual_db_name}.${table_name}" \
                --arg db "$actual_db_name" \
                --arg service "$service_name" \
                --arg serviceType "$service_type" \
                --argjson columns "$columns_payload" \
                '{
                    action: "create_table",
                    table: $name,
                    fqn: $fqn,
                    database: $db,
                    service: $service,
                    serviceType: $serviceType,
                    columns: $columns
                }')
            payloads=$(echo "$payloads" | jq --argjson p "$payload" '. + [$p]')
        done

        # Tables dropped - mark as deleted
        local dropped_count
        dropped_count=$(jq ".databases[$i].tables_dropped | length" "$changeset_file")
        for ((j=0; j<dropped_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_dropped[$j].name" "$changeset_file")

            local payload
            payload=$(jq -n \
                --arg name "$table_name" \
                --arg fqn "${service_name}.${actual_db_name}.${table_name}" \
                '{action: "delete_table", table: $name, fqn: $fqn}')
            payloads=$(echo "$payloads" | jq --argjson p "$payload" '. + [$p]')
        done

        # Tables modified - patch columns
        local mod_count
        mod_count=$(jq ".databases[$i].tables_modified | length" "$changeset_file")
        for ((j=0; j<mod_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_modified[$j].table" "$changeset_file")
            local fqn="${service_name}.${actual_db_name}.${table_name}"

            # Columns added
            local cols_added
            cols_added=$(jq "[.databases[$i].tables_modified[$j].columns_added[] | {
                name: .name,
                dataType: (.data_type | ascii_upcase),
                dataTypeDisplay: .full_type,
                dataLength: .max_length,
                constraint: (if .key == \"PRI\" then \"PRIMARY_KEY\" elif .key == \"UNI\" then \"UNIQUE\" else null end),
                ordinalPosition: .position,
                description: .comment
            }]" "$changeset_file")

            local cols_added_count
            cols_added_count=$(echo "$cols_added" | jq 'length')
            if [[ "$cols_added_count" -gt 0 ]]; then
                local payload
                payload=$(jq -n \
                    --arg table "$table_name" \
                    --arg fqn "$fqn" \
                    --argjson columns "$cols_added" \
                    '{action: "add_columns", table: $table, fqn: $fqn, columns: $columns}')
                payloads=$(echo "$payloads" | jq --argjson p "$payload" '. + [$p]')
            fi

            # Columns dropped
            local cols_dropped
            cols_dropped=$(jq "[.databases[$i].tables_modified[$j].columns_dropped[].name]" "$changeset_file")
            local cols_dropped_count
            cols_dropped_count=$(echo "$cols_dropped" | jq 'length')
            if [[ "$cols_dropped_count" -gt 0 ]]; then
                local payload
                payload=$(jq -n \
                    --arg table "$table_name" \
                    --arg fqn "$fqn" \
                    --argjson columns "$cols_dropped" \
                    '{action: "drop_columns", table: $table, fqn: $fqn, column_names: $columns}')
                payloads=$(echo "$payloads" | jq --argjson p "$payload" '. + [$p]')
            fi

            # Columns modified
            local cols_mod
            cols_mod=$(jq "[.databases[$i].tables_modified[$j].columns_modified[] | {
                column: .column,
                before: {dataType: (.before.data_type | ascii_upcase), dataTypeDisplay: .before.full_type, nullable: .before.nullable},
                after: {dataType: (.after.data_type | ascii_upcase), dataTypeDisplay: .after.full_type, nullable: .after.nullable}
            }]" "$changeset_file")
            local cols_mod_count
            cols_mod_count=$(echo "$cols_mod" | jq 'length')
            if [[ "$cols_mod_count" -gt 0 ]]; then
                local payload
                payload=$(jq -n \
                    --arg table "$table_name" \
                    --arg fqn "$fqn" \
                    --argjson modifications "$cols_mod" \
                    '{action: "modify_columns", table: $table, fqn: $fqn, modifications: $modifications}')
                payloads=$(echo "$payloads" | jq --argjson p "$payload" '. + [$p]')
            fi
        done
    done

    echo "$payloads" | jq '.'
}

# Push changes to Open Metadata via REST API
# Look up a description from descriptions.json
# Usage: lookup_description "table" "db_name" "table_name" ["column_name"]
lookup_description() {
    local item_type="$1"
    local db="$2"
    local table="$3"
    local column="${4:-}"

    if [[ ! -f "$DESCRIPTIONS_FILE" ]]; then
        echo ""
        return
    fi

    local desc=""
    if [[ "$item_type" == "table" ]]; then
        desc=$(jq -r --arg db "$db" --arg tbl "$table" \
            '[.[] | select(.type == "table" and .database == $db and .table == $tbl)][0].description // ""' \
            "$DESCRIPTIONS_FILE" 2>/dev/null || echo "")
    elif [[ "$item_type" == "column" ]]; then
        desc=$(jq -r --arg db "$db" --arg tbl "$table" --arg col "$column" \
            '[.[] | select(.type == "column" and .database == $db and .table == $tbl and .column == $col)][0].description // ""' \
            "$DESCRIPTIONS_FILE" 2>/dev/null || echo "")
    fi

    echo "$desc"
}

push_to_open_metadata() {
    local changeset_file="$1"
    local om_url="$2"
    local om_token="$3"
    local service_name="$4"
    local service_type="$5"

    local api_base="${om_url}/api/v1"
    local auth_header="Authorization: Bearer ${om_token}"
    local content_type="Content-Type: application/json"

    local successes=0
    local failures=0
    local errors_detail="[]"

    # Process each database
    local db_count
    db_count=$(jq '.databases | length' "$changeset_file")

    for ((i=0; i<db_count; i++)); do
        local db_name
        db_name=$(jq -r ".databases[$i].database" "$changeset_file")

        local actual_db_name="$db_name"
        local after_file="${SNAPSHOT_DIR}/${db_name}-after.json"
        if [[ -f "$after_file" ]]; then
            actual_db_name=$(jq -r '.actual_name // .database' "$after_file")
        fi

        # Ensure database entity exists in OM
        local db_fqn="${service_name}.${actual_db_name}"
        local db_payload
        db_payload=$(jq -n \
            --arg name "$actual_db_name" \
            --arg service "$service_name" \
            '{name: $name, service: {type: "databaseService", id: $service}}')

        # Create or get database schema entity
        local schema_fqn="${service_name}.${actual_db_name}.${actual_db_name}"

        # Process added tables - use PUT /tables to create
        local added_count
        added_count=$(jq ".databases[$i].tables_added | length" "$changeset_file")
        for ((j=0; j<added_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_added[$j].name" "$changeset_file")

            log "  Creating table: ${table_name}"

            # Look up table description
            local table_desc
            table_desc=$(lookup_description "table" "$db_name" "$table_name")

            local columns_payload
            columns_payload=$(jq "[.databases[$i].tables_added[$j].columns[] | {
                name: .name,
                dataType: (.data_type | ascii_upcase),
                dataTypeDisplay: .full_type,
                dataLength: (if .max_length then .max_length else 0 end),
                constraint: (if .key == \"PRI\" then \"PRIMARY_KEY\" elif .key == \"UNI\" then \"UNIQUE\" else null end),
                ordinalPosition: .position,
                description: (.comment // \"\")
            }]" "$changeset_file")

            # Merge column descriptions from descriptions file
            if [[ -f "$DESCRIPTIONS_FILE" ]]; then
                local col_count_inner
                col_count_inner=$(echo "$columns_payload" | jq 'length')
                for ((k=0; k<col_count_inner; k++)); do
                    local cname
                    cname=$(echo "$columns_payload" | jq -r ".[$k].name")
                    local cdesc
                    cdesc=$(lookup_description "column" "$db_name" "$table_name" "$cname")
                    if [[ -n "$cdesc" ]]; then
                        columns_payload=$(echo "$columns_payload" | jq --arg idx "$k" --arg desc "$cdesc" \
                            '.[$idx | tonumber].description = $desc')
                    fi
                done
            fi

            local table_payload
            table_payload=$(jq -n \
                --arg name "$table_name" \
                --arg dbSchema "$schema_fqn" \
                --arg desc "$table_desc" \
                --argjson columns "$columns_payload" \
                '{
                    name: $name,
                    databaseSchema: {type: "databaseSchema", fullyQualifiedName: $dbSchema},
                    columns: $columns,
                    tableType: "Regular",
                    description: (if $desc == "" then null else $desc end)
                }')

            local response
            response=$(curl -s -w "\n%{http_code}" -X PUT \
                -H "$auth_header" -H "$content_type" \
                -d "$table_payload" \
                "${api_base}/tables" 2>/dev/null) || true

            local http_code
            http_code=$(echo "$response" | tail -1)
            if [[ "$http_code" =~ ^(200|201)$ ]]; then
                successes=$((successes + 1))
                log "${GREEN}    Created: $table_name${NC}"
            else
                failures=$((failures + 1))
                local body
                body=$(echo "$response" | sed '$d')
                errors_detail=$(echo "$errors_detail" | jq \
                    --arg action "create_table" \
                    --arg table "$table_name" \
                    --arg code "$http_code" \
                    --arg body "$body" \
                    '. + [{action: $action, table: $table, http_code: $code, response: $body}]')
                log "${RED}    Failed: $table_name (HTTP $http_code)${NC}"
            fi
        done

        # Process dropped tables - use DELETE /tables/name/{fqn}
        local dropped_count
        dropped_count=$(jq ".databases[$i].tables_dropped | length" "$changeset_file")
        for ((j=0; j<dropped_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_dropped[$j].name" "$changeset_file")
            local table_fqn="${service_name}.${actual_db_name}.${actual_db_name}.${table_name}"

            log "  Soft-deleting table: ${table_name}"

            local response
            response=$(curl -s -w "\n%{http_code}" -X DELETE \
                -H "$auth_header" \
                "${api_base}/tables/name/${table_fqn}?hardDelete=false" 2>/dev/null) || true

            local http_code
            http_code=$(echo "$response" | tail -1)
            if [[ "$http_code" =~ ^(200|204)$ ]]; then
                successes=$((successes + 1))
                log "${GREEN}    Deleted: $table_name${NC}"
            else
                failures=$((failures + 1))
                local body
                body=$(echo "$response" | sed '$d')
                errors_detail=$(echo "$errors_detail" | jq \
                    --arg action "delete_table" \
                    --arg table "$table_name" \
                    --arg code "$http_code" \
                    --arg body "$body" \
                    '. + [{action: $action, table: $table, http_code: $code, response: $body}]')
                log "${RED}    Failed to delete: $table_name (HTTP $http_code)${NC}"
            fi
        done

        # Process modified tables - use PATCH /tables/{id}/columns
        local mod_count
        mod_count=$(jq ".databases[$i].tables_modified | length" "$changeset_file")
        for ((j=0; j<mod_count; j++)); do
            local table_name
            table_name=$(jq -r ".databases[$i].tables_modified[$j].table" "$changeset_file")
            local table_fqn="${service_name}.${actual_db_name}.${actual_db_name}.${table_name}"

            log "  Updating table: ${table_name}"

            # Get current table from OM to get its ID and current columns
            local current_table
            current_table=$(curl -s -H "$auth_header" \
                "${api_base}/tables/name/${table_fqn}?fields=columns" 2>/dev/null) || true

            local table_id
            table_id=$(echo "$current_table" | jq -r '.id // ""')

            if [[ -z "$table_id" || "$table_id" == "null" ]]; then
                log "${YELLOW}    Table not found in OM, creating instead${NC}"
                # Fall back to creating the full table from the after snapshot
                local after_table
                after_table=$(jq --arg name "$table_name" '.tables[] | select(.name == $name)' "${SNAPSHOT_DIR}/${db_name}-after.json")

                local columns_payload
                columns_payload=$(echo "$after_table" | jq '[.columns[] | {
                    name: .name,
                    dataType: (.data_type | ascii_upcase),
                    dataTypeDisplay: .full_type,
                    dataLength: (if .max_length then .max_length else 0 end),
                    ordinalPosition: .position
                }]')

                local table_payload
                table_payload=$(jq -n \
                    --arg name "$table_name" \
                    --arg dbSchema "$schema_fqn" \
                    --argjson columns "$columns_payload" \
                    '{
                        name: $name,
                        databaseSchema: {type: "databaseSchema", fullyQualifiedName: $dbSchema},
                        columns: $columns,
                        tableType: "Regular"
                    }')

                local response
                response=$(curl -s -w "\n%{http_code}" -X PUT \
                    -H "$auth_header" -H "$content_type" \
                    -d "$table_payload" \
                    "${api_base}/tables" 2>/dev/null) || true

                local http_code
                http_code=$(echo "$response" | tail -1)
                if [[ "$http_code" =~ ^(200|201)$ ]]; then
                    successes=$((successes + 1))
                else
                    failures=$((failures + 1))
                fi
                continue
            fi

            # Build JSON Patch operations for column changes
            local patch_ops="[]"

            # Add new columns
            local cols_added_count
            cols_added_count=$(jq ".databases[$i].tables_modified[$j].columns_added | length" "$changeset_file")
            for ((k=0; k<cols_added_count; k++)); do
                local col_payload
                col_payload=$(jq ".databases[$i].tables_modified[$j].columns_added[$k] | {
                    name: .name,
                    dataType: (.data_type | ascii_upcase),
                    dataTypeDisplay: .full_type,
                    dataLength: (if .max_length then .max_length else 0 end),
                    ordinalPosition: .position
                }" "$changeset_file")

                patch_ops=$(echo "$patch_ops" | jq --argjson col "$col_payload" \
                    '. + [{op: "add", path: "/columns/-", value: $col}]')
            done

            # For dropped/modified columns, we need to rebuild the full column list
            # since JSON Patch on arrays by index is fragile
            local cols_dropped_count cols_mod_count
            cols_dropped_count=$(jq ".databases[$i].tables_modified[$j].columns_dropped | length" "$changeset_file")
            cols_mod_count=$(jq ".databases[$i].tables_modified[$j].columns_modified | length" "$changeset_file")

            if [[ "$cols_dropped_count" -gt 0 || "$cols_mod_count" -gt 0 ]]; then
                # Build full column list from after snapshot
                local full_columns
                full_columns=$(jq --arg name "$table_name" '[.tables[] | select(.name == $name) | .columns[] | {
                    name: .name,
                    dataType: (.data_type | ascii_upcase),
                    dataTypeDisplay: .full_type,
                    dataLength: (if .max_length then .max_length else 0 end),
                    ordinalPosition: .position
                }]' "${SNAPSHOT_DIR}/${db_name}-after.json")

                patch_ops=$(jq -n --argjson cols "$full_columns" \
                    '[{op: "replace", path: "/columns", value: $cols}]')
            fi

            if [[ $(echo "$patch_ops" | jq 'length') -gt 0 ]]; then
                local response
                response=$(curl -s -w "\n%{http_code}" -X PATCH \
                    -H "$auth_header" -H "$content_type" \
                    -d "$patch_ops" \
                    "${api_base}/tables/${table_id}" 2>/dev/null) || true

                local http_code
                http_code=$(echo "$response" | tail -1)
                if [[ "$http_code" =~ ^(200|201)$ ]]; then
                    successes=$((successes + 1))
                    log "${GREEN}    Updated: $table_name${NC}"
                else
                    failures=$((failures + 1))
                    local body
                    body=$(echo "$response" | sed '$d')
                    errors_detail=$(echo "$errors_detail" | jq \
                        --arg action "modify_table" \
                        --arg table "$table_name" \
                        --arg code "$http_code" \
                        --arg body "$body" \
                        '. + [{action: $action, table: $table, http_code: $code, response: $body}]')
                    log "${RED}    Failed to update: $table_name (HTTP $http_code)${NC}"
                fi
            fi
        done
    done

    local status="success"
    [[ $failures -gt 0 && $successes -eq 0 ]] && status="error"
    [[ $failures -gt 0 && $successes -gt 0 ]] && status="partial"

    jq -n \
        --arg status "$status" \
        --arg successes "$successes" \
        --arg failures "$failures" \
        --argjson errors "$errors_detail" \
        '{
            status: $status,
            successes: ($successes | tonumber),
            failures: ($failures | tonumber),
            errors: $errors
        }'
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --snapshot) SECTION="snapshot"; shift ;;
            --diff) SECTION="diff"; shift ;;
            --describe) SECTION="describe"; shift ;;
            --sync)
                if [[ "$SECTION" == "diff" || "$SECTION" == "describe" ]]; then
                    DO_SYNC=true
                else
                    SECTION="sync"
                fi
                shift ;;
            --full) SECTION="full"; shift ;;
            --before) SNAPSHOT_TAG="before"; shift ;;
            --after) SNAPSHOT_TAG="after"; shift ;;
            --snapshot-dir) SNAPSHOT_DIR="$2"; shift 2 ;;
            --changeset) CHANGESET_FILE="$2"; shift 2 ;;
            --descriptions) DESCRIPTIONS_FILE="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            --skip-describe) SKIP_DESCRIBE=true; shift ;;
            --db) TARGET_DB="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Ensure PROJECT.yaml exists
    if [[ ! -f "PROJECT.yaml" ]]; then
        exit_with_json "error" "PROJECT.yaml not found" "Run: /project-config init"
    fi

    # Ensure snapshot directory exists
    mkdir -p "$SNAPSHOT_DIR"

    # Execute sections
    case "$SECTION" in
        snapshot)
            section_snapshot
            ;;
        diff)
            section_diff
            ;;
        describe)
            section_describe
            ;;
        sync)
            section_sync
            ;;
        full)
            # Full flow: before snapshot should already exist
            # Take after snapshot, diff, describe (if enabled), sync
            if [[ ! -d "$SNAPSHOT_DIR" ]] || ! ls "${SNAPSHOT_DIR}"/*-before.json >/dev/null 2>&1; then
                exit_with_json "error" "No 'before' snapshots found" \
                    "Run --snapshot --before first (before migrations), then --full or --snapshot --after"
            fi

            SNAPSHOT_TAG="after"
            section_snapshot 2>/dev/null || true

            # Diff (don't sync yet - describe first if enabled)
            SECTION="diff"
            local auto_describe_enabled
            auto_describe_enabled=$(get_config ".schema_sync.auto_describe.enabled" "false")

            if [[ "$auto_describe_enabled" == "true" && "$SKIP_DESCRIBE" != "true" ]]; then
                DO_SYNC=false
                section_diff 2>/dev/null || true
                SECTION="describe"
                DO_SYNC=true
                section_describe
            else
                DO_SYNC=true
                section_diff
            fi
            ;;
    esac
}

main "$@"
