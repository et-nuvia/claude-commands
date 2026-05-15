#!/usr/bin/env bash
# Database backup verification script
# Verifies backup integrity and tests restoration procedures

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FORMAT="json"
OUTPUT_MODE="json"
SECTION="full"
SECTIONS=()

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        error)   echo "fix_error" ;;
        *)       echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# ============================================================================
# Helper Functions
# ============================================================================

log_raw() {
  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*" >&2
  fi
}

# ============================================================================
# Section: Configuration
# ============================================================================

section_config() {
  log_raw "Loading database configuration..."

  local db_type=""
  local backup_dir=""
  local retention_days=""
  local connection_string=""

  # Try to load from PROJECT.yaml
  if [[ -f "PROJECT.yaml" ]]; then
    db_type=$(yaml_get '.database.type' PROJECT.yaml)
    backup_dir=$(yaml_get '.database.backup.directory' PROJECT.yaml)
    retention_days=$(yaml_get '.database.backup.retention_days' PROJECT.yaml)
    connection_string=$(yaml_get '.database.connection_string' PROJECT.yaml)
  fi

  # Validate required configuration
  if [[ -z "$db_type" ]] || [[ "$db_type" == "null" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"config\",\"message\":\"Database type not configured\",\"next_action\":\"fix_error\",\"details\":\"Set database.type in PROJECT.yaml (postgresql, mysql)\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  if [[ -z "$backup_dir" ]] || [[ "$backup_dir" == "null" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"config\",\"message\":\"Backup directory not configured\",\"next_action\":\"fix_error\",\"details\":\"Set database.backup.directory in PROJECT.yaml\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  if [[ ! -d "$backup_dir" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"config\",\"message\":\"Backup directory does not exist\",\"next_action\":\"fix_error\",\"details\":\"Directory: $backup_dir\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  log_success "Configuration loaded: $db_type, backups in $backup_dir"

  # Export for other sections
  export DB_TYPE="$db_type"
  export BACKUP_DIR="$backup_dir"
  export RETENTION_DAYS="${retention_days:-30}"
  export CONNECTION_STRING="$connection_string"

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    log_json "{\"status\":\"success\",\"section\":\"config\",\"message\":\"Configuration loaded\",\"next_action\":\"display_summary\",\"timestamp\":\"$(date -Iseconds)\",\"db_type\":\"$db_type\",\"backup_dir\":\"$backup_dir\",\"retention_days\":$RETENTION_DAYS}"
  fi

  return 0
}

# ============================================================================
# Section: List Backups
# ============================================================================

section_list() {
  log_raw "Listing available backups..."

  if [[ -z "${BACKUP_DIR:-}" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"list\",\"message\":\"BACKUP_DIR not set\",\"next_action\":\"fix_error\",\"details\":\"Run --config first\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  local backup_files=()
  local backup_count=0

  case "$DB_TYPE" in
    postgresql)
      mapfile -t backup_files < <(find "$BACKUP_DIR" -name "*.sql" -o -name "*.sql.gz" -o -name "*.dump" | sort -r)
      ;;
    mysql)
      mapfile -t backup_files < <(find "$BACKUP_DIR" -name "*.sql" -o -name "*.sql.gz" | sort -r)
      ;;
    *)
      log_json "{\"status\":\"error\",\"section\":\"list\",\"message\":\"Unsupported database type\",\"next_action\":\"fix_error\",\"details\":\"Type: $DB_TYPE\",\"timestamp\":\"$(date -Iseconds)\"}"
      return 1
      ;;
  esac

  backup_count="${#backup_files[@]}"

  if [[ $backup_count -eq 0 ]]; then
    log_warning "No backup files found in $BACKUP_DIR"
    log_json "{\"status\":\"success\",\"section\":\"list\",\"message\":\"No backups found\",\"next_action\":\"display_summary\",\"timestamp\":\"$(date -Iseconds)\",\"backup_count\":0,\"backup_dir\":\"$BACKUP_DIR\"}"
    return 0
  fi

  log_success "Found $backup_count backup file(s)"

  # Build JSON array of backups
  local backups_json="["
  local first=true

  for backup_file in "${backup_files[@]}"; do
    local filename=$(basename "$backup_file")
    local size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
    local modified=$(stat -f%m "$backup_file" 2>/dev/null || stat -c%Y "$backup_file" 2>/dev/null || echo "0")
    local modified_date=$(date -r "$modified" -Iseconds 2>/dev/null || date -d "@$modified" -Iseconds 2>/dev/null || echo "unknown")

    if [[ "$first" == "true" ]]; then
      first=false
    else
      backups_json="$backups_json,"
    fi

    backups_json="$backups_json{\"filename\":\"$filename\",\"path\":\"$backup_file\",\"size\":$size,\"modified\":\"$modified_date\"}"

    if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
      echo "  $filename ($(numfmt --to=iec-i --suffix=B $size 2>/dev/null || echo "${size}B"), modified: $modified_date)"
    fi
  done

  backups_json="$backups_json]"

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    log_json "{\"status\":\"success\",\"section\":\"list\",\"message\":\"Backups listed\",\"next_action\":\"display_summary\",\"timestamp\":\"$(date -Iseconds)\",\"backup_count\":$backup_count,\"backups\":$backups_json}"
  fi

  return 0
}

# ============================================================================
# Section: Verify Integrity
# ============================================================================

section_verify() {
  log_raw "Verifying backup integrity..."

  if [[ -z "${BACKUP_DIR:-}" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"verify\",\"message\":\"BACKUP_DIR not set\",\"next_action\":\"fix_error\",\"details\":\"Run --config first\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  # Get latest backup
  local latest_backup=""
  case "$DB_TYPE" in
    postgresql)
      latest_backup=$(find "$BACKUP_DIR" -name "*.sql" -o -name "*.sql.gz" -o -name "*.dump" | sort -r | head -1)
      ;;
    mysql)
      latest_backup=$(find "$BACKUP_DIR" -name "*.sql" -o -name "*.sql.gz" | sort -r | head -1)
      ;;
  esac

  if [[ -z "$latest_backup" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"verify\",\"message\":\"No backup files found\",\"next_action\":\"fix_error\",\"details\":\"Directory: $BACKUP_DIR\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  log_raw "Verifying: $(basename "$latest_backup")"

  local verification_results=()
  local passed=0
  local failed=0

  # Check 1: File exists and is readable
  if [[ -r "$latest_backup" ]]; then
    verification_results+=("file_readable:true")
    ((passed++))
    log_success "File is readable"
  else
    verification_results+=("file_readable:false")
    ((failed++))
    log_error "File is not readable"
  fi

  # Check 2: File size > 0
  local file_size=$(stat -f%z "$latest_backup" 2>/dev/null || stat -c%s "$latest_backup" 2>/dev/null || echo "0")
  if [[ $file_size -gt 0 ]]; then
    verification_results+=("file_size_valid:true")
    ((passed++))
    log_success "File size valid: $(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "${file_size}B")"
  else
    verification_results+=("file_size_valid:false")
    ((failed++))
    log_error "File is empty"
  fi

  # Check 3: Verify compression (if gzipped)
  if [[ "$latest_backup" == *.gz ]]; then
    if gzip -t "$latest_backup" 2>/dev/null; then
      verification_results+=("compression_valid:true")
      ((passed++))
      log_success "Compression valid"
    else
      verification_results+=("compression_valid:false")
      ((failed++))
      log_error "Compression corrupted"
    fi
  else
    verification_results+=("compression_valid:null")
    log_raw "Not compressed, skipping compression check"
  fi

  # Check 4: Basic SQL syntax check
  local temp_file="/tmp/backup_verify_$$.sql"
  if [[ "$latest_backup" == *.gz ]]; then
    gunzip -c "$latest_backup" | head -100 > "$temp_file"
  else
    head -100 "$latest_backup" > "$temp_file"
  fi

  if grep -q "CREATE\|INSERT\|UPDATE" "$temp_file"; then
    verification_results+=("sql_syntax_valid:true")
    ((passed++))
    log_success "SQL syntax appears valid"
  else
    verification_results+=("sql_syntax_valid:false")
    ((failed++))
    log_error "No SQL statements found"
  fi

  rm -f "$temp_file"

  # Check 5: Age check
  local modified=$(stat -f%m "$latest_backup" 2>/dev/null || stat -c%Y "$latest_backup" 2>/dev/null || echo "0")
  local now=$(date +%s)
  local age_hours=$(( (now - modified) / 3600 ))

  if [[ $age_hours -lt 48 ]]; then
    verification_results+=("age_recent:true")
    ((passed++))
    log_success "Backup is recent (${age_hours}h old)"
  else
    verification_results+=("age_recent:false")
    ((failed++))
    log_warning "Backup is old (${age_hours}h old)"
  fi

  # Build results JSON
  local results_json="{"
  local first=true
  for result in "${verification_results[@]}"; do
    local key="${result%%:*}"
    local value="${result#*:}"

    if [[ "$first" == "true" ]]; then
      first=false
    else
      results_json="$results_json,"
    fi

    results_json="$results_json\"$key\":$value"
  done
  results_json="$results_json}"

  local status="success"
  if [[ $failed -gt 0 ]]; then
    status="error"
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    log_json "{\"status\":\"$status\",\"section\":\"verify\",\"message\":\"Verification complete\",\"next_action\":\"$(map_status_to_action "$status")\",\"timestamp\":\"$(date -Iseconds)\",\"backup_file\":\"$(basename "$latest_backup")\",\"checks_passed\":$passed,\"checks_failed\":$failed,\"results\":$results_json}"
  fi

  [[ $failed -eq 0 ]]
  return $?
}

# ============================================================================
# Section: Test Restore
# ============================================================================

section_test_restore() {
  log_raw "Testing restore procedure..."

  if [[ -z "${BACKUP_DIR:-}" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"test-restore\",\"message\":\"BACKUP_DIR not set\",\"next_action\":\"fix_error\",\"details\":\"Run --config first\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  # Get latest backup
  local latest_backup=""
  case "$DB_TYPE" in
    postgresql)
      latest_backup=$(find "$BACKUP_DIR" -name "*.sql" -o -name "*.sql.gz" -o -name "*.dump" | sort -r | head -1)
      ;;
    mysql)
      latest_backup=$(find "$BACKUP_DIR" -name "*.sql" -o -name "*.sql.gz" | sort -r | head -1)
      ;;
  esac

  if [[ -z "$latest_backup" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"test-restore\",\"message\":\"No backup files found\",\"next_action\":\"fix_error\",\"details\":\"Directory: $BACKUP_DIR\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  log_raw "Testing restore from: $(basename "$latest_backup")"

  # Create temporary test database name
  local test_db="backup_verify_test_$(date +%s)"

  log_raw "Creating test database: $test_db"

  local restore_success=false
  local error_message=""

  case "$DB_TYPE" in
    postgresql)
      # Create test database
      if psql -c "CREATE DATABASE $test_db;" 2>/dev/null; then
        log_success "Test database created"

        # Attempt restore
        if [[ "$latest_backup" == *.gz ]]; then
          if gunzip -c "$latest_backup" | psql -d "$test_db" >/dev/null 2>&1; then
            restore_success=true
            log_success "Restore successful"
          else
            error_message="Restore failed"
            log_error "Restore failed"
          fi
        else
          if psql -d "$test_db" -f "$latest_backup" >/dev/null 2>&1; then
            restore_success=true
            log_success "Restore successful"
          else
            error_message="Restore failed"
            log_error "Restore failed"
          fi
        fi

        # Drop test database
        psql -c "DROP DATABASE $test_db;" 2>/dev/null
        log_raw "Test database dropped"
      else
        error_message="Failed to create test database - PostgreSQL may not be accessible"
        log_error "$error_message"
      fi
      ;;

    mysql)
      # Create test database
      if mysql -e "CREATE DATABASE $test_db;" 2>/dev/null; then
        log_success "Test database created"

        # Attempt restore
        if [[ "$latest_backup" == *.gz ]]; then
          if gunzip -c "$latest_backup" | mysql "$test_db" 2>/dev/null; then
            restore_success=true
            log_success "Restore successful"
          else
            error_message="Restore failed"
            log_error "Restore failed"
          fi
        else
          if mysql "$test_db" < "$latest_backup" 2>/dev/null; then
            restore_success=true
            log_success "Restore successful"
          else
            error_message="Restore failed"
            log_error "Restore failed"
          fi
        fi

        # Drop test database
        mysql -e "DROP DATABASE $test_db;" 2>/dev/null
        log_raw "Test database dropped"
      else
        error_message="Failed to create test database - MySQL may not be accessible"
        log_error "$error_message"
      fi
      ;;
  esac

  if [[ "$restore_success" == "true" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      log_json "{\"status\":\"success\",\"section\":\"test-restore\",\"message\":\"Restore test passed\",\"next_action\":\"display_summary\",\"timestamp\":\"$(date -Iseconds)\",\"backup_file\":\"$(basename "$latest_backup")\",\"test_database\":\"$test_db\"}"
    fi
    return 0
  else
    log_json "{\"status\":\"error\",\"section\":\"test-restore\",\"message\":\"Restore test failed\",\"next_action\":\"fix_error\",\"details\":\"$error_message\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi
}

# ============================================================================
# Section: Check Retention
# ============================================================================

section_retention() {
  log_raw "Checking backup retention policy..."

  if [[ -z "${BACKUP_DIR:-}" ]]; then
    log_json "{\"status\":\"error\",\"section\":\"retention\",\"message\":\"BACKUP_DIR not set\",\"next_action\":\"fix_error\",\"details\":\"Run --config first\",\"timestamp\":\"$(date -Iseconds)\"}"
    return 1
  fi

  local retention_days="${RETENTION_DAYS:-30}"
  local cutoff_date=$(date -d "$retention_days days ago" +%s 2>/dev/null || date -v-${retention_days}d +%s 2>/dev/null)

  local total_backups=0
  local old_backups=0
  local old_backup_files=()

  while IFS= read -r backup_file; do
    ((total_backups++))

    local modified=$(stat -f%m "$backup_file" 2>/dev/null || stat -c%Y "$backup_file" 2>/dev/null || echo "0")

    if [[ $modified -lt $cutoff_date ]]; then
      ((old_backups++))
      old_backup_files+=("$(basename "$backup_file")")

      if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
        local age_days=$(( ($(date +%s) - modified) / 86400 ))
        echo "  Old backup: $(basename "$backup_file") (${age_days} days old)"
      fi
    fi
  done < <(find "$BACKUP_DIR" -type f \( -name "*.sql" -o -name "*.sql.gz" -o -name "*.dump" \))

  log_raw "Total backups: $total_backups"
  log_raw "Backups older than $retention_days days: $old_backups"

  # Build old backups JSON array
  local old_backups_json="["
  local first=true
  for file in "${old_backup_files[@]}"; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      old_backups_json="$old_backups_json,"
    fi
    old_backups_json="$old_backups_json\"$file\""
  done
  old_backups_json="$old_backups_json]"

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    log_json "{\"status\":\"success\",\"section\":\"retention\",\"message\":\"Retention check complete\",\"next_action\":\"display_summary\",\"timestamp\":\"$(date -Iseconds)\",\"total_backups\":$total_backups,\"old_backups\":$old_backups,\"retention_days\":$retention_days,\"old_backup_files\":$old_backups_json}"
  fi

  return 0
}

# ============================================================================
# Main Execution
# ============================================================================

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Database backup verification script.

OPTIONS:
  --json              Output in JSON format (default)
  --raw               Output in human-readable format with colors

  --full              Run all sections (config, list, verify, test-restore, retention)
  --config            Load database configuration
  --list              List available backups
  --verify            Verify backup integrity
  --test-restore      Test restore procedure (creates temporary database)
  --retention         Check backup retention policy

  -h, --help          Show this help message

EXAMPLES:
  # Run full verification
  $0 --json --full

  # Just verify integrity
  $0 --json --verify

  # Interactive mode with detailed output
  $0 --raw --full

WORKFLOW:
  1. Loads config from PROJECT.yaml
  2. Lists available backups
  3. Verifies latest backup integrity
  4. Tests restore procedure (optional)
  5. Checks retention policy compliance

JSON OUTPUT:
  {
    "status": "success|error",
    "section": "config|list|verify|test-restore|retention",
    "message": "Human-readable message",
    "timestamp": "ISO 8601 datetime",
    ...additional fields...
  }

EOF
}

main() {
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        OUTPUT_FORMAT="json"
        OUTPUT_MODE="json"
        shift
        ;;
      --raw)
        OUTPUT_FORMAT="raw"
        OUTPUT_MODE="raw"
        shift
        ;;
      --full)
        SECTIONS=("config" "list" "verify" "test-restore" "retention")
        shift
        ;;
      --config)
        SECTIONS+=("config")
        shift
        ;;
      --list)
        SECTIONS+=("list")
        shift
        ;;
      --verify)
        SECTIONS+=("verify")
        shift
        ;;
      --test-restore)
        SECTIONS+=("test-restore")
        shift
        ;;
      --retention)
        SECTIONS+=("retention")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  # Default to full if no sections specified
  if [[ ${#SECTIONS[@]} -eq 0 ]]; then
    SECTIONS=("config" "list" "verify" "retention")
  fi

  # Execute sections
  for section in "${SECTIONS[@]}"; do
    case "$section" in
      config)
        section_config || exit 1
        ;;
      list)
        section_list || exit 1
        ;;
      verify)
        section_verify || exit 1
        ;;
      test-restore)
        section_test_restore || exit 1
        ;;
      retention)
        section_retention || exit 1
        ;;
      *)
        exit_with_json "error" "Unknown section: $section"
        ;;
    esac
  done

  # If we got here and using JSON, output final success
  if [[ "$OUTPUT_FORMAT" == "json" ]] && [[ ${#SECTIONS[@]} -gt 1 ]]; then
    exit_with_json "success" "All verification checks complete" "" "\"sections_run\":${#SECTIONS[@]}"
  fi
}

main "$@"
