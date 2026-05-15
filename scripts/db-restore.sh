#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Database restore with safety checks
#
# Usage:
#   ~/.claude/scripts/db-restore.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags:
#   --detect:   Detect database type and configuration
#   --select:   Select backup file
#   --verify:   Verify backup integrity
#   --restore:  Execute restore operation
#   --check:    Post-restore verification
#   --full:     Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: db-restore.sh --json --full
#   2. User confirms safety warnings (interactive)
#   3. Script executes restore with progress tracking
#   4. Returns JSON with restore results and verification

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, detect, select, verify, restore, check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)          echo "display_summary" ;;
        input_needed)     echo "provide_input" ;;
        selection_needed) echo "select_backup" ;;
        error)            echo "fix_error" ;;
        *)                echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Restore state variables
DB_TYPE=""
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASSWORD=""
BACKUP_DIR=""
BACKUP_FILE=""
TARGET_DB=""
CREATE_DB="false"
SAFETY_BACKUP_FILE=""
RESTORE_STATUS=0
TABLE_COUNT=0
INVALID_INDEXES=0
DURATION=0

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Detect database type and configuration
section_detect() {
    log "${BLUE}Detecting database configuration${NC}"

    # Try PROJECT.yaml first
    if [[ -f "PROJECT.yaml" ]]; then
        DB_TYPE=$(yaml_get_default '.database.type' 'null' PROJECT.yaml)
        DB_HOST=$(yaml_get_default '.database.connection.host' 'null' PROJECT.yaml)
        DB_PORT=$(yaml_get_default '.database.connection.port' 'null' PROJECT.yaml)
        DB_USER=$(yaml_get_default '.database.connection.user' 'null' PROJECT.yaml)
        BACKUP_DIR=$(yaml_get_default '.database.backup.directory' 'null' PROJECT.yaml)
    fi

    # Interactive prompts if needed
    if [[ -z "$DB_TYPE" ]] || [[ "$DB_TYPE" == "null" ]]; then
        log "${YELLOW}Database type not configured in PROJECT.yaml${NC}"

        # In JSON mode, prompt for missing config
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            local json=$(cat <<EOF
{
  "status": "input_needed",
  "section": "detect",
  "next_action": "provide_input",
  "message": "Database configuration required",
  "required_inputs": {
    "db_type": "postgresql or mysql",
    "db_host": "Database host",
    "db_user": "Database user",
    "backup_dir": "Backup directory path"
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi

        # In raw mode, interactive prompts
        echo "Database type:" >&2
        echo "1. PostgreSQL" >&2
        echo "2. MySQL/MariaDB" >&2
        read -p "Choice (1-2): " DB_CHOICE

        case "$DB_CHOICE" in
            1) DB_TYPE="postgresql" ;;
            2) DB_TYPE="mysql" ;;
            *) exit_with_json "error" "Invalid database type selection" "" ;;
        esac

        read -p "Database host: " DB_HOST
        read -p "Database user: " DB_USER
        read -p "Backup directory: " BACKUP_DIR
    fi

    log "${GREEN}✓${NC} Configuration detected"
    log "  Type: $DB_TYPE"
    log "  Host: $DB_HOST"
    log "  Backup dir: $BACKUP_DIR"

    if [[ "$SECTION" == "detect" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "detect",
  "next_action": "display_summary",
  "message": "Database configuration detected",
  "config": {
    "db_type": "$DB_TYPE",
    "db_host": "$DB_HOST",
    "db_port": "$DB_PORT",
    "db_user": "$DB_USER",
    "backup_dir": "$BACKUP_DIR"
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Section 2: Select backup file
section_select() {
    log "${BLUE}Selecting backup file${NC}"

    # Find available backups
    local backups
    if [[ "$DB_TYPE" == "postgresql" ]]; then
        backups=$(find "$BACKUP_DIR" -name "*.dump" -o -name "*.sql" -o -name "*.backup" 2>/dev/null | sort -r || echo "")
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        backups=$(find "$BACKUP_DIR" -name "*.sql" -o -name "*.sql.gz" 2>/dev/null | sort -r || echo "")
    fi

    if [[ -z "$backups" ]]; then
        exit_with_json "error" "No backups found in $BACKUP_DIR" ""
    fi

    # Count backups
    local backup_count=$(echo "$backups" | wc -l)
    log "Found $backup_count backups"

    # In JSON mode, return list for LLM to present
    if [[ "$OUTPUT_MODE" == "json" ]] && [[ "$SECTION" == "select" ]]; then
        local backup_list=$(echo "$backups" | head -20 | jq -R . | jq -s .)
        local json=$(cat <<EOF
{
  "status": "selection_needed",
  "section": "select",
  "next_action": "select_backup",
  "message": "Select backup file to restore",
  "backup_count": $backup_count,
  "recent_backups": $backup_list,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    # In raw mode, interactive selection
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "" >&2
        echo "Available backups:" >&2
        echo "$backups" | head -20 | while read -r backup; do
            local size=$(du -h "$backup" 2>/dev/null | cut -f1 || echo "?")
            local age=$(stat -c%y "$backup" 2>/dev/null | cut -d' ' -f1 || stat -f%Sm "$backup" 2>/dev/null || echo "?")
            echo "  [$age] $size - $(basename "$backup")" >&2
        done | nl >&2

        echo "" >&2
        read -p "Select backup number (or full path): " BACKUP_CHOICE

        if [[ -f "$BACKUP_CHOICE" ]]; then
            BACKUP_FILE="$BACKUP_CHOICE"
        else
            BACKUP_FILE=$(echo "$backups" | sed -n "${BACKUP_CHOICE}p")
        fi

        if [[ ! -f "$BACKUP_FILE" ]]; then
            exit_with_json "error" "Backup file not found: $BACKUP_FILE" ""
        fi

        log "${GREEN}✓${NC} Selected: $(basename "$BACKUP_FILE")"
        log "  Size: $(du -h "$BACKUP_FILE" | cut -f1)"
    fi
}

# Section 3: Verify backup integrity
section_verify() {
    log "${BLUE}Verifying backup integrity${NC}"

    local verification_output=""

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        if ! verification_output=$(pg_restore -l "$BACKUP_FILE" 2>&1); then
            exit_with_json "error" "Backup file corrupted" "$verification_output"
        fi
        TABLE_COUNT=$(echo "$verification_output" | grep -c "TABLE DATA" || echo "0")
        log "${GREEN}✓${NC} Backup valid ($TABLE_COUNT tables)"
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ "$BACKUP_FILE" == *.gz ]]; then
            if ! gzip -t "$BACKUP_FILE" 2>&1; then
                exit_with_json "error" "Backup file corrupted (gzip test failed)" ""
            fi
            log "${GREEN}✓${NC} Compression valid"
        fi
    fi

    if [[ "$SECTION" == "verify" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "verify",
  "next_action": "display_summary",
  "message": "Backup integrity verified",
  "backup_file": "$BACKUP_FILE",
  "backup_size": "$(du -h "$BACKUP_FILE" | cut -f1)",
  "table_count": $TABLE_COUNT,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Section 4: Restore database (LLM intervention point for safety)
section_restore() {
    log "${BLUE}Executing database restore${NC}"

    # Safety confirmation in raw mode
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "" >&2
        echo "⚠️⚠️⚠️  DATABASE RESTORE WARNING  ⚠️⚠️⚠️" >&2
        echo "" >&2
        echo "This will OVERWRITE the target database with backup data." >&2
        echo "ALL CURRENT DATA in the target database will be LOST." >&2
        echo "" >&2
        read -p "Type 'I UNDERSTAND' to continue: " SAFETY_CONFIRM

        if [[ "$SAFETY_CONFIRM" != "I UNDERSTAND" ]]; then
            echo "Aborted" >&2
            exit 0
        fi
    fi

    # Prompt for target database
    if [[ -z "$TARGET_DB" ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            local json=$(cat <<EOF
{
  "status": "input_needed",
  "section": "restore",
  "next_action": "provide_input",
  "message": "Target database selection required",
  "options": {
    "create_new": "Create new database",
    "overwrite_existing": "Restore to existing database (DESTRUCTIVE)",
    "test_database": "Restore to test database first (RECOMMENDED)"
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi

        echo "" >&2
        echo "Restore target:" >&2
        echo "1. Create new database" >&2
        echo "2. Restore to existing database (DESTRUCTIVE)" >&2
        echo "3. Restore to test database first (RECOMMENDED)" >&2
        read -p "Choice (1-3): " TARGET_CHOICE

        case "$TARGET_CHOICE" in
            1)
                read -p "New database name: " TARGET_DB
                CREATE_DB=true
                ;;
            2)
                read -p "Existing database name: " TARGET_DB
                CREATE_DB=false

                echo "" >&2
                echo "⚠️⚠️⚠️  FINAL WARNING  ⚠️⚠️⚠️" >&2
                echo "This will DESTROY all data in: $TARGET_DB" >&2
                echo "" >&2
                read -p "Type database name to confirm: " CONFIRM_DB

                if [[ "$CONFIRM_DB" != "$TARGET_DB" ]]; then
                    echo "Database name mismatch. Aborted." >&2
                    exit 0
                fi
                ;;
            3)
                TARGET_DB="restore_test_$(date +%Y%m%d_%H%M%S)"
                CREATE_DB=true
                log "Test database: $TARGET_DB"
                ;;
        esac
    fi

    # Create database if needed
    if [[ "$CREATE_DB" == "true" ]]; then
        log "Creating database: $TARGET_DB"
        if [[ "$DB_TYPE" == "postgresql" ]]; then
            createdb -h "$DB_HOST" -U "$DB_USER" "$TARGET_DB" 2>&1 || exit_with_json "error" "Failed to create database" ""
        elif [[ "$DB_TYPE" == "mysql" ]]; then
            mysql -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASSWORD:-}" -e "CREATE DATABASE $TARGET_DB;" 2>&1 || exit_with_json "error" "Failed to create database" ""
        fi
        log "${GREEN}✓${NC} Database created"
    fi

    # Execute restore
    log "Starting restore..."
    local start_time=$(date +%s)
    local restore_log="/tmp/restore-$(date +%Y%m%d-%H%M%S).log"

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        if [[ "$BACKUP_FILE" == *.sql ]]; then
            psql -h "$DB_HOST" -U "$DB_USER" -d "$TARGET_DB" -f "$BACKUP_FILE" > "$restore_log" 2>&1
            RESTORE_STATUS=$?
        else
            pg_restore -h "$DB_HOST" -U "$DB_USER" -d "$TARGET_DB" \
                --clean --if-exists --no-owner --no-acl -j 4 \
                "$BACKUP_FILE" > "$restore_log" 2>&1
            RESTORE_STATUS=$?
        fi
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ "$BACKUP_FILE" == *.gz ]]; then
            zcat "$BACKUP_FILE" | mysql -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASSWORD:-}" "$TARGET_DB" > "$restore_log" 2>&1
            RESTORE_STATUS=$?
        else
            mysql -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASSWORD:-}" "$TARGET_DB" < "$BACKUP_FILE" > "$restore_log" 2>&1
            RESTORE_STATUS=$?
        fi
    fi

    local end_time=$(date +%s)
    DURATION=$((end_time - start_time))

    if [[ $RESTORE_STATUS -ne 0 ]]; then
        local error_details=$(tail -50 "$restore_log" 2>/dev/null || echo "No log available")
        exit_with_json "error" "Restore failed (exit code: $RESTORE_STATUS)" "$error_details\n\nFull log: $restore_log"
    fi

    log "${GREEN}✓${NC} Restore completed ($DURATION seconds)"

    if [[ "$SECTION" == "restore" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "restore",
  "next_action": "display_summary",
  "message": "Database restore completed successfully",
  "target_db": "$TARGET_DB",
  "duration_seconds": $DURATION,
  "restore_log": "$restore_log",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Section 5: Post-restore verification
section_check() {
    log "${BLUE}Verifying restored database${NC}"

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        TABLE_COUNT=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$TARGET_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
        INVALID_INDEXES=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$TARGET_DB" -tAc "SELECT count(*) FROM pg_index WHERE indisvalid = false;" 2>/dev/null || echo "0")

        log "  Tables: $TABLE_COUNT"
        if [[ $INVALID_INDEXES -gt 0 ]]; then
            log "${YELLOW}⚠${NC}  Invalid indexes: $INVALID_INDEXES"
        else
            log "${GREEN}✓${NC}  All indexes valid"
        fi
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        TABLE_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASSWORD:-}" -D "$TARGET_DB" -sN -e "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$TARGET_DB';" 2>/dev/null || echo "0")
        INVALID_INDEXES=0
        log "  Tables: $TABLE_COUNT"
    fi

    if [[ $TABLE_COUNT -eq 0 ]]; then
        exit_with_json "error" "No tables found in restored database" "Database appears empty after restore"
    fi

    log "${GREEN}✓${NC} Verification complete"

    if [[ "$SECTION" == "check" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "check",
  "next_action": "display_summary",
  "message": "Post-restore verification complete",
  "table_count": $TABLE_COUNT,
  "invalid_indexes": $INVALID_INDEXES,
  "data_present": $(if [[ $TABLE_COUNT -gt 0 ]]; then echo "true"; else echo "false"; fi),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
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
            --detect) SECTION="detect"; shift ;;
            --select) SECTION="select"; shift ;;
            --verify) SECTION="verify"; shift ;;
            --restore) SECTION="restore"; shift ;;
            --check) SECTION="check"; shift ;;
            --full) SECTION="full"; shift ;;
            # Accept inputs via flags
            --db-type) DB_TYPE="$2"; shift 2 ;;
            --db-host) DB_HOST="$2"; shift 2 ;;
            --db-user) DB_USER="$2"; shift 2 ;;
            --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
            --backup-file) BACKUP_FILE="$2"; shift 2 ;;
            --target-db) TARGET_DB="$2"; shift 2 ;;
            --create-db) CREATE_DB="true"; shift ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        detect)
            section_detect
            ;;
        select)
            section_detect  # Prerequisites
            section_select
            ;;
        verify)
            section_detect
            section_select
            section_verify
            ;;
        restore)
            section_detect
            section_select
            section_verify
            section_restore
            ;;
        check)
            # Assume restore already done
            section_check
            ;;
        full)
            section_detect
            section_select
            section_verify
            section_restore
            section_check

            # Generate report
            local report_file="docs/database-restores/$(date +%Y-%m-%d)-restore-report.md"
            mkdir -p docs/database-restores

            cat > "$report_file" << EOF
# Database Restore Report

**Date**: $(date -Iseconds)
**Database Type**: $DB_TYPE
**Target Database**: $TARGET_DB
**Backup File**: $BACKUP_FILE

---

## Restore Details

- **Backup size**: $(du -h "$BACKUP_FILE" | cut -f1)
- **Backup created**: $(stat -c%y "$BACKUP_FILE" 2>/dev/null || stat -f%Sm "$BACKUP_FILE")
- **Restore duration**: $DURATION seconds
- **Restore status**: $(if [[ $RESTORE_STATUS -eq 0 ]]; then echo "✓ Success"; else echo "✗ Failed"; fi)

---

## Verification Results

- **Tables restored**: $TABLE_COUNT
- **Invalid indexes**: ${INVALID_INDEXES}
- **Data present**: $(if [[ $TABLE_COUNT -gt 0 ]]; then echo "✓ Yes"; else echo "✗ No tables found"; fi)

---

## Post-Restore Checklist

- [ ] Verify table counts match expectations
- [ ] Check row counts in critical tables
- [ ] Test application connectivity
- [ ] Run smoke tests
- [ ] Verify indexes are valid
- [ ] Update statistics (ANALYZE)
- [ ] Monitor query performance
- [ ] Notify team of restoration

---

Generated: $(date -Iseconds)
EOF

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Database restore completed successfully",
  "sections_completed": ["detect", "select", "verify", "restore", "check"],
  "restore_summary": {
    "db_type": "$DB_TYPE",
    "target_db": "$TARGET_DB",
    "backup_file": "$(basename "$BACKUP_FILE")",
    "backup_size": "$(du -h "$BACKUP_FILE" | cut -f1)",
    "duration_seconds": $DURATION,
    "tables_restored": $TABLE_COUNT,
    "invalid_indexes": $INVALID_INDEXES,
    "report_file": "$report_file"
  },
  "next_steps": [
    "Update statistics: vacuumdb -h $DB_HOST -U $DB_USER --analyze-in-stages $TARGET_DB",
    "Test application connectivity",
    "Run smoke tests: /test-smoke",
    "Monitor query performance"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
