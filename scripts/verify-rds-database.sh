#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# verify-rds-database.sh
#
# Verifies that a MySQL database is correctly provisioned:
#   - AWS Secrets Manager secret exists and has required keys
#   - App user can connect and execute DML
#   - Migrations user can connect and execute DDL (CREATE TABLE IF NOT EXISTS)
#   - Expected tables exist (optional)
#
# Does NOT print secret values — only reports on structure and connectivity.
#
# Usage:
#   verify-rds-database.sh --secret nuvia/intake-form/staging/analytics-db
#   verify-rds-database.sh --secret nuvia/intake-form/production/analytics-db \
#     --region us-west-1 \
#     --expected-tables s3_folder_manifest
#
##############################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

SECRET_NAME=""
REGION="${AWS_REGION:-us-west-1}"
EXPECTED_TABLES=()
EXIT_CODE=0

PASS=0
FAIL=0
WARN=0

usage() {
  cat <<'USAGE'
Usage: verify-rds-database.sh [OPTIONS]

Required:
  --secret NAME           AWS Secrets Manager secret name to verify

Optional:
  --region REGION         AWS region (default: us-west-1)
  --expected-tables T..   Space-separated list of tables that must exist
  -h, --help              Show this help

Example:
  verify-rds-database.sh \
    --secret nuvia/intake-form/production/analytics-db \
    --expected-tables s3_folder_manifest
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --secret)           SECRET_NAME="$2";   shift 2 ;;
    --region)           REGION="$2";        shift 2 ;;
    --expected-tables)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
        EXPECTED_TABLES+=("$1")
        shift
      done
      ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${SECRET_NAME}" ]] && { echo "ERROR: --secret is required" >&2; exit 1; }

##############################################################################
# Helpers
##############################################################################
check_pass() { echo -e "  ${GREEN}✓${RESET} $1"; (( PASS++ )) || true; }
check_fail() { echo -e "  ${RED}✗${RESET} $1"; (( FAIL++ )) || true; EXIT_CODE=1; }
check_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; (( WARN++ )) || true; }
section()    { echo ""; echo -e "${BOLD}${CYAN}── $1${RESET}"; }

##############################################################################
# 1. Secret existence and structure
##############################################################################
section "Secret: ${SECRET_NAME}"

SECRET_JSON=""
if SECRET_JSON=$(aws secretsmanager get-secret-value \
    --region "${REGION}" \
    --secret-id "${SECRET_NAME}" \
    --query SecretString \
    --output text 2>/dev/null); then
  check_pass "Secret exists in ${REGION}"
else
  check_fail "Secret not found: ${SECRET_NAME} (region: ${REGION})"
  echo ""
  echo -e "${RED}Cannot continue — secret is missing.${RESET}"
  exit 1
fi

# Required keys
REQUIRED_KEYS=("host" "port" "database" "username" "password" "migrations_user" "migrations_password")
for key in "${REQUIRED_KEYS[@]}"; do
  val=$(echo "${SECRET_JSON}" | jq -r ".${key} // empty" 2>/dev/null)
  if [[ -n "${val}" ]]; then
    check_pass "Key '${key}' is present"
  else
    check_fail "Key '${key}' is missing or empty"
  fi
done

# Extract values (for connectivity checks only — never printed)
DB_HOST=$(echo "${SECRET_JSON}" | jq -r '.host')
DB_PORT=$(echo "${SECRET_JSON}" | jq -r '.port // "3306"')
DB_NAME=$(echo "${SECRET_JSON}" | jq -r '.database')
APP_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
APP_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')
MIGR_USER=$(echo "${SECRET_JSON}" | jq -r '.migrations_user')
MIGR_PASS=$(echo "${SECRET_JSON}" | jq -r '.migrations_password')

# Print non-sensitive config
echo ""
echo -e "  ${BOLD}Host:${RESET}       ${DB_HOST}"
echo -e "  ${BOLD}Port:${RESET}       ${DB_PORT}"
echo -e "  ${BOLD}Database:${RESET}   ${DB_NAME}"
echo -e "  ${BOLD}App user:${RESET}   ${APP_USER}"
echo -e "  ${BOLD}Migr user:${RESET}  ${MIGR_USER}"

##############################################################################
# 2. App user — DML connectivity
##############################################################################
section "App user connectivity (DML)"

mysql_exec() {
  local user="$1" pass="$2" sql="$3"
  mysql \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --user="${user}" \
    --password="${pass}" \
    --ssl-mode=REQUIRED \
    --connect-timeout=15 \
    --silent \
    --execute="${sql}" \
    "${DB_NAME}" 2>&1
}

if mysql_exec "${APP_USER}" "${APP_PASS}" "SELECT 1" >/dev/null 2>&1; then
  check_pass "App user can connect to ${DB_NAME}"
else
  check_fail "App user cannot connect to ${DB_NAME}"
fi

# Verify DML grants
for grant in "SELECT" "INSERT" "UPDATE" "DELETE"; do
  if mysql_exec "${APP_USER}" "${APP_PASS}" \
      "SHOW GRANTS FOR CURRENT_USER()" 2>/dev/null \
      | grep -qi "${grant}"; then
    check_pass "App user has ${grant} privilege"
  else
    check_warn "Could not verify ${grant} privilege (SHOW GRANTS may be restricted)"
  fi
done

# Verify app user cannot CREATE TABLE (should be DML-only)
TEST_TABLE="verify_app_user_$(date +%s)"
if mysql_exec "${APP_USER}" "${APP_PASS}" \
    "CREATE TABLE ${TEST_TABLE} (id INT)" >/dev/null 2>&1; then
  # If it succeeded, clean up and warn
  mysql_exec "${APP_USER}" "${APP_PASS}" "DROP TABLE IF EXISTS ${TEST_TABLE}" >/dev/null 2>&1 || true
  check_warn "App user has DDL privileges (CREATE TABLE succeeded — expected DML-only)"
else
  check_pass "App user correctly denied DDL (CREATE TABLE)"
fi

##############################################################################
# 3. Migrations user — DDL connectivity
##############################################################################
section "Migrations user connectivity (DDL)"

if mysql_exec "${MIGR_USER}" "${MIGR_PASS}" "SELECT 1" >/dev/null 2>&1; then
  check_pass "Migrations user can connect to ${DB_NAME}"
else
  check_fail "Migrations user cannot connect to ${DB_NAME}"
fi

# Verify DDL: create and drop a test table
TEST_TABLE="verify_migr_$(date +%s)"
if mysql_exec "${MIGR_USER}" "${MIGR_PASS}" \
    "CREATE TABLE IF NOT EXISTS ${TEST_TABLE} (id INT PRIMARY KEY)" >/dev/null 2>&1; then
  check_pass "Migrations user can CREATE TABLE"
  mysql_exec "${MIGR_USER}" "${MIGR_PASS}" "DROP TABLE IF EXISTS ${TEST_TABLE}" >/dev/null 2>&1 \
    && check_pass "Migrations user can DROP TABLE" \
    || check_warn "Migrations user cannot DROP TABLE"
else
  check_fail "Migrations user cannot CREATE TABLE (DDL failed)"
fi

##############################################################################
# 4. Expected tables
##############################################################################
if [[ ${#EXPECTED_TABLES[@]} -gt 0 ]]; then
  section "Expected tables in ${DB_NAME}"

  for table in "${EXPECTED_TABLES[@]}"; do
    result=$(mysql_exec "${APP_USER}" "${APP_PASS}" \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='${table}'" \
      2>/dev/null | tail -1)
    if [[ "${result}" == "1" ]]; then
      check_pass "Table '${table}' exists"
    else
      check_fail "Table '${table}' does not exist"
    fi
  done
fi

##############################################################################
# Summary
##############################################################################
echo ""
echo -e "${BOLD}──────────────────────────────────${RESET}"
echo -e "  ${GREEN}Passed:${RESET} ${PASS}  ${RED}Failed:${RESET} ${FAIL}  ${YELLOW}Warnings:${RESET} ${WARN}"
echo -e "${BOLD}──────────────────────────────────${RESET}"
echo ""

if [[ ${EXIT_CODE} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}✓ All checks passed${RESET}"
else
  echo -e "${RED}${BOLD}✗ ${FAIL} check(s) failed${RESET}"
fi

exit ${EXIT_CODE}
