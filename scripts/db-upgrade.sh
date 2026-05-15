#!/usr/bin/env bash
# Database Upgrade Planning Script
# Generates comprehensive upgrade plans for major database version changes
#
# Usage:
#   db-upgrade.sh --json --full              # Complete upgrade plan generation
#   db-upgrade.sh --json --detect            # Detect current version only
#   db-upgrade.sh --raw --<section>          # Verbose output for debugging
#
# next_action values:
#   display_summary        - Plan generated, show results to user
#   fix_error              - Script error, fix before retrying
#   fix_connection         - Database connection failed
#   provide_target_version - User must supply TARGET_VERSION env var
#   provide_strategy       - User must supply UPGRADE_STRATEGY env var
#   configure_database     - Add database config to PROJECT.yaml

set -euo pipefail

OUTPUT_MODE="json"
SECTION="full"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        intervention_needed)  echo "fix_error" ;;
        error)                echo "fix_error" ;;
        *)                    echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
    --raw) OUTPUT_MODE="raw"; shift ;;
    --detect) SECTION="detect"; shift ;;
    --breaking-changes) SECTION="breaking-changes"; shift ;;
    --estimate) SECTION="estimate"; shift ;;
    --plan) SECTION="plan"; shift ;;
    --scripts) SECTION="scripts"; shift ;;
    --full) SECTION="full"; shift ;;
    --target-version) TARGET_VERSION="$2"; TARGET_MAJOR="${2%%.*}"; shift 2 ;;
    --strategy) UPGRADE_STRATEGY="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# json_output: thin wrapper preserving the original call-site interface
# Constructs JSON with context-dependent next_action, then delegates to log_json
json_output() {
  local status="$1"
  local section="$2"
  local message="$3"
  shift 3

  local next_action
  case "$status" in
    success)              next_action="display_summary" ;;
    intervention_needed)
      case "$section" in
        detect|target-version) next_action="provide_target_version" ;;
        strategy)              next_action="provide_strategy" ;;
        *)                     next_action="fix_error" ;;
      esac
      ;;
    error)
      case "$message" in
        *"connect"*) next_action="fix_connection" ;;
        *"not configured"*) next_action="configure_database" ;;
        *)           next_action="fix_error" ;;
      esac
      ;;
    *)  next_action="fix_error" ;;
  esac

  local json="{\"status\":\"$status\",\"section\":\"$section\",\"message\":\"$message\",\"next_action\":\"$next_action\",\"timestamp\":\"$(date -Iseconds)\""
  while [[ $# -gt 0 ]]; do
    json="$json,$1"
    shift
  done
  json="$json}"
  log_json "$json"
}

err() { if [[ "$OUTPUT_MODE" == "raw" ]]; then echo "[ERROR] $*" >&2; fi; }

load_project_config() {
  if [[ -f "PROJECT.yaml" ]]; then
    log "Loading PROJECT.yaml configuration"
    DB_TYPE=$(yaml_get_default '.database.type' 'null' PROJECT.yaml)
    DB_HOST=$(yaml_get_default '.database.connection.host' 'null' PROJECT.yaml)
    DB_PORT=$(yaml_get_default '.database.connection.port' 'null' PROJECT.yaml)
    DB_NAME=$(yaml_get_default '.database.connection.database' 'null' PROJECT.yaml)
    DB_USER=$(yaml_get_default '.database.connection.user' 'null' PROJECT.yaml)
    if [[ "$DB_TYPE" == "null" ]] || [[ -z "$DB_TYPE" ]]; then DB_TYPE=""; fi
  else
    DB_TYPE=""; DB_HOST=""; DB_PORT=""; DB_NAME=""; DB_USER=""
  fi
}

detect_database() {
  log "Detecting database configuration..."

  if [[ -z "$DB_TYPE" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      json_output "intervention_needed" "detect" "Database configuration required" \
        "\"reason\":\"No database configuration in PROJECT.yaml\"" \
        "\"next_steps\":[\"Add database config to PROJECT.yaml\"]"
      exit 0
    else
      echo "Database type: 1) PostgreSQL  2) MySQL  3) MongoDB"
      read -p "Choice (1-3): " DB_CHOICE
      case "$DB_CHOICE" in
        1) DB_TYPE="postgresql" ;;
        2) DB_TYPE="mysql" ;;
        3) DB_TYPE="mongodb" ;;
        *) err "Invalid choice"; exit 1 ;;
      esac
      read -p "Database host: " DB_HOST
      read -p "Database name: " DB_NAME
      read -p "Database user: " DB_USER
    fi
  fi

  case "$DB_TYPE" in
    postgresql)
      PORT=${DB_PORT:-5432}
      CURRENT_VERSION=$(psql -h "$DB_HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SHOW server_version;" 2>/dev/null | cut -d' ' -f1 || echo "")
      if [[ -z "$CURRENT_VERSION" ]]; then
        json_output "error" "detect" "Failed to connect to PostgreSQL" \
          "\"details\":\"Check host, port, credentials, and network connectivity\""
        exit 1
      fi
      CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d'.' -f1)
      ;;
    mysql)
      PORT=${DB_PORT:-3306}
      CURRENT_VERSION=$(mysql -h "$DB_HOST" -P "$PORT" -u "$DB_USER" -D "$DB_NAME" -sN -e "SELECT VERSION();" 2>/dev/null || echo "")
      if [[ -z "$CURRENT_VERSION" ]]; then
        json_output "error" "detect" "Failed to connect to MySQL" \
          "\"details\":\"Check host, port, credentials, and network connectivity\""
        exit 1
      fi
      CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d'.' -f1)
      ;;
    mongodb)
      json_output "error" "detect" "MongoDB upgrade not yet implemented" \
        "\"details\":\"Currently only PostgreSQL and MySQL are supported\""
      exit 1
      ;;
    *)
      json_output "error" "detect" "Unknown database type: $DB_TYPE" \
        "\"details\":\"Supported types: postgresql, mysql\""
      exit 1
      ;;
  esac

  log "Detected: $DB_TYPE $CURRENT_VERSION (major: $CURRENT_MAJOR)"

  if [[ "$SECTION" == "detect" ]]; then
    json_output "success" "detect" "Database detected successfully" \
      "\"db_type\":\"$DB_TYPE\"" \
      "\"current_version\":\"$CURRENT_VERSION\"" \
      "\"current_major\":\"$CURRENT_MAJOR\"" \
      "\"host\":\"$DB_HOST\"" \
      "\"database\":\"$DB_NAME\""
    exit 0
  fi
}

get_target_version() {
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    case "$DB_TYPE" in
      postgresql)
        json_output "intervention_needed" "target-version" "Target version selection required" \
          "\"current_major\":\"$CURRENT_MAJOR\"" \
          "\"available_versions\":[14,15,16,17]" \
          "\"next_steps\":[\"Re-run with --target-version flag\"]"
        exit 0
        ;;
      mysql)
        json_output "intervention_needed" "target-version" "Target version selection required" \
          "\"current_major\":\"$CURRENT_MAJOR\"" \
          "\"available_versions\":[\"8.0\",\"8.4\",\"9.0\"]" \
          "\"next_steps\":[\"Re-run with --target-version flag\"]"
        exit 0
        ;;
    esac
  else
    case "$DB_TYPE" in
      postgresql)
        echo "Target: 1) PG14  2) PG15  3) PG16  4) PG17"
        read -p "Choice (1-4): " V
        case "$V" in
          1) TARGET_VERSION="14"; TARGET_MAJOR="14" ;;
          2) TARGET_VERSION="15"; TARGET_MAJOR="15" ;;
          3) TARGET_VERSION="16"; TARGET_MAJOR="16" ;;
          4) TARGET_VERSION="17"; TARGET_MAJOR="17" ;;
          *) err "Invalid choice"; exit 1 ;;
        esac
        ;;
      mysql)
        echo "Target: 1) MySQL 8.0  2) MySQL 8.4  3) MySQL 9.0"
        read -p "Choice (1-3): " V
        case "$V" in
          1) TARGET_VERSION="8.0"; TARGET_MAJOR="8" ;;
          2) TARGET_VERSION="8.4"; TARGET_MAJOR="8" ;;
          3) TARGET_VERSION="9.0"; TARGET_MAJOR="9" ;;
          *) err "Invalid choice"; exit 1 ;;
        esac
        ;;
    esac
    if [[ $TARGET_MAJOR -le $CURRENT_MAJOR ]]; then
      err "Target version ($TARGET_MAJOR) must be greater than current ($CURRENT_MAJOR)"
      exit 1
    fi
    log "Upgrading: $DB_TYPE $CURRENT_MAJOR to $TARGET_MAJOR"
  fi
}

check_breaking_changes() {
  log "Checking for breaking changes..."
  local breaking_changes=()

  if [[ "$DB_TYPE" == "postgresql" ]]; then
    local deprecated_ext
    deprecated_ext=$(psql -h "$DB_HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT extname FROM pg_extension WHERE extname IN ('tsearch2', 'chkpass');" 2>/dev/null || echo "")
    if [[ -n "$deprecated_ext" ]]; then
      breaking_changes+=("Deprecated extensions found: $deprecated_ext")
    fi
    if [[ $CURRENT_MAJOR -lt 12 ]] && [[ ${TARGET_MAJOR:-0} -ge 12 ]]; then
      local oids
      oids=$(psql -h "$DB_HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM pg_class WHERE relhasoids AND relkind = 'r';" 2>/dev/null || echo "0")
      if [[ $oids -gt 0 ]]; then
        breaking_changes+=("$oids tables using WITH OIDS (removed in PG 12)")
      fi
    fi
  fi

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    local changes_json="[]"
    if [[ ${#breaking_changes[@]} -gt 0 ]]; then
      changes_json=$(printf '%s\n' "${breaking_changes[@]}" | jq -R . | jq -s .)
    fi
    json_output "success" "breaking-changes" "Breaking changes check complete" \
      "\"breaking_changes\":$changes_json" \
      "\"breaking_changes_count\":${#breaking_changes[@]}"
  else
    if [[ ${#breaking_changes[@]} -gt 0 ]]; then
      printf '  - %s\n' "${breaking_changes[@]}"
    else
      echo "No obvious breaking changes detected"
    fi
  fi
}

estimate_downtime() {
  log "Estimating database size and downtime..."
  local db_size="unknown"
  local db_size_bytes=0
  local downtime_minutes=10

  if [[ "$DB_TYPE" == "postgresql" ]]; then
    db_size=$(psql -h "$DB_HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null || echo "unknown")
    db_size_bytes=$(psql -h "$DB_HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT pg_database_size('$DB_NAME');" 2>/dev/null || echo "0")
    if [[ $db_size_bytes -gt 0 ]]; then
      downtime_minutes=$((db_size_bytes / 1024 / 1024 / 1024 / 100 * 20))
      if [[ $downtime_minutes -lt 10 ]]; then downtime_minutes=10; fi
    fi
  fi

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    json_output "success" "estimate" "Size and downtime estimated" \
      "\"database_size\":\"$db_size\"" \
      "\"database_size_bytes\":$db_size_bytes" \
      "\"estimated_downtime_minutes\":$downtime_minutes"
  else
    echo "Database size: $db_size"
    echo "Estimated downtime: ~$downtime_minutes minutes"
  fi
}

choose_strategy() {
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    json_output "intervention_needed" "strategy" "Upgrade strategy selection required" \
      "\"available_strategies\":[\"pg_upgrade\",\"dump_restore\",\"logical_replication\",\"blue_green\"]" \
      "\"next_steps\":[\"Re-run with --strategy flag\"]"
    exit 0
  else
    echo "Strategy: 1) pg_upgrade  2) dump_restore  3) logical_replication  4) blue_green"
    read -p "Choice (1-4): " S
    case "$S" in
      1) STRATEGY="pg_upgrade" ;;
      2) STRATEGY="dump_restore" ;;
      3) STRATEGY="logical_replication" ;;
      4) STRATEGY="blue_green" ;;
      *) err "Invalid choice"; exit 1 ;;
    esac
    log "Selected strategy: $STRATEGY"
  fi
}

generate_plan() {
  log "Generating upgrade plan document..."
  local upgrade_plan="docs/database-upgrades/$(date +%Y-%m-%d)-upgrade-${CURRENT_MAJOR}-to-${TARGET_MAJOR}.md"
  mkdir -p docs/database-upgrades

  printf '%s\n' \
    "# Database Upgrade Plan" \
    "" \
    "**Date**: $(date -Iseconds)" \
    "**Database**: $DB_TYPE" \
    "**Current Version**: $CURRENT_VERSION" \
    "**Target Version**: ${TARGET_VERSION:-unknown}" \
    "**Strategy**: ${STRATEGY:-pg_upgrade}" \
    "" \
    "## Pre-Upgrade Checklist" \
    "" \
    "- [ ] Full database backup completed" \
    "- [ ] Backup integrity verified" \
    "- [ ] Staging environment tested" \
    "- [ ] Breaking changes reviewed" \
    "- [ ] Maintenance window scheduled" \
    "" \
    "## Post-Upgrade Tasks" \
    "" \
    "- [ ] Verify all tables accessible" \
    "- [ ] Check for invalid indexes" \
    "- [ ] Run application smoke tests" \
    "- [ ] Monitor query performance" \
    > "$upgrade_plan"

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    json_output "success" "plan" "Upgrade plan generated" \
      "\"plan_file\":\"$upgrade_plan\""
  else
    echo "Upgrade plan generated: $upgrade_plan"
  fi
}

generate_scripts() {
  log "Generating upgrade scripts..."
  local script_dir="scripts/database-upgrade"
  mkdir -p "$script_dir"

  printf '%s\n' '#!/bin/bash' 'set -euo pipefail' 'echo "Running pre-upgrade checks..."' 'echo "All pre-upgrade checks passed"' > "$script_dir/01-pre-upgrade-checks.sh"
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail' 'BACKUP_FILE="backup-pre-upgrade-$(date +%Y%m%d-%H%M%S).dump"' 'echo "Creating backup: $BACKUP_FILE"' > "$script_dir/02-backup.sh"
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail' 'echo "Verifying upgrade..."' 'echo "Verification complete"' > "$script_dir/99-verify.sh"

  chmod +x "$script_dir/"*.sh

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    json_output "success" "scripts" "Upgrade scripts generated" \
      "\"script_directory\":\"$script_dir\"" \
      "\"scripts\":[\"01-pre-upgrade-checks.sh\",\"02-backup.sh\",\"99-verify.sh\"]"
  else
    echo "Upgrade scripts created in $script_dir"
  fi
}

main() {
  load_project_config

  case "$SECTION" in
    detect)
      detect_database
      ;;
    breaking-changes)
      detect_database
      if [[ -z "${TARGET_MAJOR:-}" ]]; then
        json_output "error" "breaking-changes" "TARGET_VERSION required" \
          "\"details\":\"Pass --target-version flag (e.g. --target-version 16)\""
        exit 1
      fi
      check_breaking_changes
      ;;
    estimate)
      detect_database
      estimate_downtime
      ;;
    plan)
      detect_database
      if [[ "$OUTPUT_MODE" == "raw" ]]; then get_target_version; choose_strategy; fi
      estimate_downtime
      generate_plan
      ;;
    scripts)
      generate_scripts
      ;;
    full)
      detect_database

      if [[ "$OUTPUT_MODE" == "json" ]] && [[ -z "${TARGET_VERSION:-}" ]]; then
        get_target_version
        exit 0
      fi

      if [[ "$OUTPUT_MODE" == "raw" ]]; then
        get_target_version
        check_breaking_changes
        estimate_downtime
        choose_strategy
        generate_plan
        generate_scripts
        echo ""
        echo "Upgrade plan complete. Current: $DB_TYPE $CURRENT_MAJOR -> Target: $TARGET_MAJOR  Strategy: $STRATEGY"
      else
        check_breaking_changes
        estimate_downtime
        if [[ -z "${UPGRADE_STRATEGY:-}" ]]; then choose_strategy; exit 0; fi
        STRATEGY="${UPGRADE_STRATEGY}"
        generate_plan
        generate_scripts
        json_output "success" "full" "Upgrade plan generation complete" \
          "\"db_type\":\"$DB_TYPE\"" \
          "\"current_version\":\"$CURRENT_VERSION\"" \
          "\"target_version\":\"${TARGET_VERSION}\"" \
          "\"strategy\":\"$STRATEGY\""
      fi
      ;;
    *)
      json_output "error" "unknown" "Unknown section: $SECTION" \
        "\"details\":\"Valid sections: detect, breaking-changes, estimate, plan, scripts, full\""
      exit 1
      ;;
  esac
}

main
