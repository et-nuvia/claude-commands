#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Database performance analysis with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/db-performance.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --detect:    Detect database type and test connection
#   --collect:   Collect performance statistics
#   --analyze:   Analyze performance and generate report
#   --full:      Run all sections end-to-end (default)
#
# next_action values:
#   display_summary     - Analysis complete, show results to user
#   fix_error           - Script error, fix before retrying
#   fix_connection      - Database connection failed
#   enable_extension    - pg_stat_statements not enabled

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, detect, collect, analyze

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)  echo "display_summary" ;;
        error)
            # Context-dependent mapping not possible here; use default
            echo "fix_error" ;;
        *)        echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Database connection variables
DB_TYPE=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""

# Statistics files
TMP_DIR="/tmp/db-perf-$$"
SLOW_QUERIES="$TMP_DIR/slow-queries.txt"
MISSING_INDEXES="$TMP_DIR/missing-indexes.txt"
INDEX_USAGE="$TMP_DIR/index-usage.txt"
TABLE_SIZES="$TMP_DIR/table-sizes.txt"
TABLE_BLOAT="$TMP_DIR/table-bloat.txt"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

cleanup_temp() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup_temp EXIT

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

section_detect() {
    log "${BLUE}Detecting Database Type and Connection${NC}"

    mkdir -p "$TMP_DIR"

    if [[ -f "PROJECT.yaml" ]]; then
        DB_TYPE=$(yaml_get '.database.type' PROJECT.yaml)
        DB_HOST=$(yaml_get '.database.connection.host' PROJECT.yaml)
        DB_PORT=$(yaml_get '.database.connection.port' PROJECT.yaml)
        DB_NAME=$(yaml_get '.database.connection.database' PROJECT.yaml)
        DB_USER=$(yaml_get '.database.connection.user' PROJECT.yaml)
        log "${GREEN}✓${NC} Database config loaded from PROJECT.yaml"
    fi

    if [[ -z "$DB_TYPE" ]] || [[ "$DB_TYPE" == "null" ]]; then
        exit_with_json "error" "Database type not configured" "Configure database in PROJECT.yaml or provide connection details"
    fi

    if [[ -z "$DB_NAME" ]] || [[ "$DB_NAME" == "null" ]]; then
        exit_with_json "error" "Database name not configured" "Configure database.connection.database in PROJECT.yaml"
    fi

    DB_HOST=${DB_HOST:-localhost}
    DB_USER=${DB_USER:-postgres}

    log "${CYAN}Database: $DB_TYPE${NC}"
    log "${CYAN}Host: $DB_HOST${NC}"
    log "${CYAN}Database: $DB_NAME${NC}"

    case "$DB_TYPE" in
        postgresql|postgres)
            DB_TYPE="postgresql"
            DB_PORT=${DB_PORT:-5432}
            log ""
            log "Testing PostgreSQL connection..."
            if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT version();" > /dev/null 2>&1; then
                exit_with_json "error" "PostgreSQL connection failed" "Check credentials and network connectivity. Try: psql -h $DB_HOST -U $DB_USER -d $DB_NAME"
            fi
            log "${GREEN}✓${NC} Connected successfully"
            local has_pg_stat=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null || echo "0")
            if [[ "$has_pg_stat" == "0" ]]; then
                exit_with_json "error" "pg_stat_statements extension not enabled" "Enable with: CREATE EXTENSION IF NOT EXISTS pg_stat_statements; (requires superuser)"
            fi
            log "${GREEN}✓${NC} pg_stat_statements enabled"
            ;;
        mysql|mariadb)
            DB_TYPE="mysql"
            DB_PORT=${DB_PORT:-3306}
            log ""
            log "Testing MySQL connection..."
            if ! mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -D "$DB_NAME" -e "SELECT VERSION();" > /dev/null 2>&1; then
                exit_with_json "error" "MySQL connection failed" "Check credentials and network connectivity"
            fi
            log "${GREEN}✓${NC} Connected successfully"
            ;;
        *)
            exit_with_json "error" "Unsupported database type: $DB_TYPE" "Supported types: postgresql, mysql"
            ;;
    esac

    if [[ "$SECTION" == "detect" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "detect",
  "next_action": "display_summary",
  "message": "Database connection verified",
  "database_type": "$DB_TYPE",
  "database_host": "$DB_HOST",
  "database_name": "$DB_NAME",
  "database_port": "$DB_PORT",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Detection complete"
}

section_collect() {
    log "${BLUE}Collecting Performance Statistics${NC}"

    case "$DB_TYPE" in
        postgresql)
            log ""
            log "Analyzing slow queries..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" > "$SLOW_QUERIES" 2>&1 << 'SQL'
SELECT
  calls,
  total_exec_time::numeric(10,2) as total_time_ms,
  mean_exec_time::numeric(10,2) as avg_time_ms,
  max_exec_time::numeric(10,2) as max_time_ms,
  stddev_exec_time::numeric(10,2) as stddev_time_ms,
  LEFT(query, 100) as query_start
FROM pg_stat_statements
WHERE mean_exec_time > 100
ORDER BY mean_exec_time DESC
LIMIT 25;
SQL
            local slow_count=$(grep -c "^" "$SLOW_QUERIES" 2>/dev/null || echo "0")
            log "${GREEN}✓${NC} Found $slow_count slow queries"

            log ""
            log "Checking for missing indexes..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" > "$MISSING_INDEXES" 2>&1 << 'SQL'
SELECT
  schemaname,
  tablename,
  seq_scan,
  seq_tup_read,
  idx_scan,
  CASE WHEN seq_scan > 0 THEN seq_tup_read / seq_scan ELSE 0 END as avg_seq_read,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as table_size
FROM pg_stat_user_tables
WHERE seq_scan > 100
  AND schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY seq_tup_read DESC
LIMIT 15;
SQL

            log ""
            log "Analyzing index usage..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" > "$INDEX_USAGE" 2>&1 << 'SQL'
SELECT
  schemaname,
  tablename,
  indexname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY idx_scan ASC
LIMIT 20;
SQL
            local unused_indexes=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM pg_stat_user_indexes WHERE idx_scan = 0 AND schemaname NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null || echo "0")
            echo "$unused_indexes" > "$TMP_DIR/unused_count.txt"
            log "${YELLOW}⚠${NC}  Found $unused_indexes unused indexes"

            log ""
            log "Getting table sizes..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" > "$TABLE_SIZES" 2>&1 << 'SQL'
SELECT
  schemaname || '.' || tablename as table,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) as indexes_size,
  n_live_tup as estimated_rows
FROM pg_stat_user_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 15;
SQL

            log ""
            log "Checking for table bloat..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" > "$TABLE_BLOAT" 2>&1 << 'SQL'
SELECT
  schemaname || '.' || tablename as table,
  n_live_tup,
  n_dead_tup,
  ROUND(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_pct,
  last_autovacuum,
  last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 10;
SQL
            local bloated_tables=$(grep -c "^" "$TABLE_BLOAT" 2>/dev/null || echo "0")
            echo "$bloated_tables" > "$TMP_DIR/bloated_count.txt"
            if [[ $bloated_tables -gt 1 ]]; then
                log "${YELLOW}⚠${NC}  Found $bloated_tables tables with significant dead tuples"
            fi
            ;;

        mysql)
            log ""
            log "Analyzing MySQL performance schema..."
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -D "$DB_NAME" > "$SLOW_QUERIES" 2>&1 << 'SQL'
SELECT
  DIGEST_TEXT as query,
  COUNT_STAR as executions,
  AVG_TIMER_WAIT/1000000000 as avg_time_ms,
  MAX_TIMER_WAIT/1000000000 as max_time_ms,
  SUM_ROWS_EXAMINED as rows_examined
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = DATABASE()
ORDER BY AVG_TIMER_WAIT DESC
LIMIT 25;
SQL
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -D "$DB_NAME" > "$MISSING_INDEXES" 2>&1 << 'SQL'
SELECT
  OBJECT_SCHEMA as schema_name,
  OBJECT_NAME as table_name,
  COUNT_READ as total_reads,
  COUNT_FETCH as rows_fetched,
  COUNT_INSERT as inserts,
  COUNT_UPDATE as updates,
  COUNT_DELETE as deletes
FROM performance_schema.table_io_waits_summary_by_table
WHERE OBJECT_SCHEMA = DATABASE()
ORDER BY COUNT_READ DESC
LIMIT 15;
SQL
            ;;
    esac

    if [[ "$SECTION" == "collect" ]]; then
        local slow_count=$(grep -c "^" "$SLOW_QUERIES" 2>/dev/null || echo "0")
        local missing_idx_count=$(grep -c "^" "$MISSING_INDEXES" 2>/dev/null || echo "0")
        local unused_indexes=$(cat "$TMP_DIR/unused_count.txt" 2>/dev/null || echo "0")
        local bloated_tables=$(cat "$TMP_DIR/bloated_count.txt" 2>/dev/null || echo "0")
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "collect",
  "next_action": "display_summary",
  "message": "Performance statistics collected",
  "slow_queries": $slow_count,
  "tables_needing_indexes": $missing_idx_count,
  "unused_indexes": $unused_indexes,
  "bloated_tables": $bloated_tables,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Collection complete"
}

section_analyze() {
    log "${BLUE}Generating Performance Analysis Report${NC}"

    local report_file="docs/database-performance/$(date +%Y-%m-%d)-performance-analysis.md"
    local index_file="docs/database-performance/$(date +%Y-%m-%d)-index-suggestions.sql"

    mkdir -p docs/database-performance

    local slow_count=$(grep -c "^" "$SLOW_QUERIES" 2>/dev/null || echo "0")
    local missing_idx_count=$(grep -c "^" "$MISSING_INDEXES" 2>/dev/null || echo "0")
    local unused_indexes=$(cat "$TMP_DIR/unused_count.txt" 2>/dev/null || echo "0")
    local bloated_tables=$(cat "$TMP_DIR/bloated_count.txt" 2>/dev/null || echo "0")

    cat > "$report_file" << EOF
# Database Performance Analysis

**Date**: $(date -Iseconds)
**Database**: $DB_TYPE
**Host**: $DB_HOST
**Database**: $DB_NAME

---

## Executive Summary

- Slow queries analyzed: $slow_count
- Tables with sequential scans: $missing_idx_count
- Unused indexes: $unused_indexes
- Bloated tables: $bloated_tables

---

## Top Slow Queries

\`\`\`
$(cat "$SLOW_QUERIES" 2>/dev/null || echo "No slow query data available")
\`\`\`

---

## Tables Needing Indexes

\`\`\`
$(cat "$MISSING_INDEXES" 2>/dev/null || echo "No sequential scan data available")
\`\`\`

---

## Index Usage Statistics

\`\`\`
$(cat "$INDEX_USAGE" 2>/dev/null || echo "No index usage data available")
\`\`\`

---

## Table Sizes and Growth

\`\`\`
$(cat "$TABLE_SIZES" 2>/dev/null || echo "No table size data available")
\`\`\`

---

## Table Bloat and Maintenance

\`\`\`
$(cat "$TABLE_BLOAT" 2>/dev/null || echo "No bloat data available")
\`\`\`

---

## Query Optimization Checklist

- [ ] Add indexes for columns in WHERE clauses
- [ ] Create composite indexes for multi-column filters
- [ ] Use EXPLAIN ANALYZE to verify query plans
- [ ] Eliminate N+1 queries in application code
- [ ] Add connection pooling (PgBouncer, ProxySQL)
- [ ] Implement query result caching
- [ ] Use prepared statements
- [ ] Review and optimize JOINs
- [ ] Consider materialized views for complex queries
- [ ] Partition large tables

EOF

    cat > "$index_file" << 'EOF'
-- Index Suggestions
-- Generated from performance analysis
-- Review and test each index before applying to production

-- IMPORTANT: Run EXPLAIN ANALYZE before and after to verify improvement

-- For tables with high sequential scans:
-- CREATE INDEX CONCURRENTLY idx_users_email ON users(email);
-- CREATE INDEX CONCURRENTLY idx_orders_user_id ON orders(user_id);

-- For composite WHERE clauses:
-- CREATE INDEX CONCURRENTLY idx_orders_user_status ON orders(user_id, status);

-- Partial indexes for filtered queries:
-- CREATE INDEX CONCURRENTLY idx_orders_active ON orders(user_id) WHERE status = 'active';

-- TODO: Fill in actual table/column names from slow query analysis
EOF

    log "${GREEN}✓${NC} Performance report: $report_file"
    log "${GREEN}✓${NC} Index suggestions template: $index_file"

    if [[ "$SECTION" == "analyze" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "analyze",
  "next_action": "display_summary",
  "message": "Performance analysis complete",
  "report_file": "$report_file",
  "index_file": "$index_file",
  "slow_queries": $slow_count,
  "tables_needing_indexes": $missing_idx_count,
  "unused_indexes": $unused_indexes,
  "bloated_tables": $bloated_tables,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Analysis complete"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --detect) SECTION="detect"; shift ;;
            --collect) SECTION="collect"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done

    case "$SECTION" in
        detect)
            section_detect
            ;;
        collect)
            section_detect
            section_collect
            ;;
        analyze)
            section_analyze
            ;;
        full)
            section_detect
            section_collect
            section_analyze

            local slow_count=$(grep -c "^" "$SLOW_QUERIES" 2>/dev/null || echo "0")
            local missing_idx_count=$(grep -c "^" "$MISSING_INDEXES" 2>/dev/null || echo "0")
            local unused_indexes=$(cat "$TMP_DIR/unused_count.txt" 2>/dev/null || echo "0")
            local bloated_tables=$(cat "$TMP_DIR/bloated_count.txt" 2>/dev/null || echo "0")
            local report_file="docs/database-performance/$(date +%Y-%m-%d)-performance-analysis.md"
            local index_file="docs/database-performance/$(date +%Y-%m-%d)-index-suggestions.sql"

            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Database performance analysis complete",
  "database_type": "$DB_TYPE",
  "database_host": "$DB_HOST",
  "database_name": "$DB_NAME",
  "slow_queries": $slow_count,
  "tables_needing_indexes": $missing_idx_count,
  "unused_indexes": $unused_indexes,
  "bloated_tables": $bloated_tables,
  "report_file": "$report_file",
  "index_file": "$index_file",
  "recommendations": [
    "Add indexes for top 5 slow queries",
    "Fix N+1 query patterns in app code",
    "Enable connection pooling",
    "Vacuum bloated tables",
    "Remove unused indexes"
  ],
  "sections_completed": ["detect", "collect", "analyze"],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

main "$@"
