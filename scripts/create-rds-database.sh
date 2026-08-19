#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# create-rds-database.sh
#
# Generic script to create a MySQL database + app/migrations users on RDS,
# generate strong passwords, and store credentials in AWS Secrets Manager.
#
# Admin credentials can come from:
#   1. Direct flags: --admin-user / --admin-password / --host
#   2. AWS Secrets Manager: --admin-secret with --admin-key-* mappings
#
# Usage examples:
#
#   # Admin creds from flags
#   create-rds-database.sh \
#     --database analytics \
#     --host mydb.us-west-1.rds.amazonaws.com \
#     --admin-user admin \
#     --admin-password 'secret' \
#     --target-secret nuvia/intake-form/production/analytics-db \
#     --app-user intake_analytics_app \
#     --migrations-user intake_analytics_migrations
#
#   # Admin creds from AWS Secrets Manager
#   create-rds-database.sh \
#     --database analytics \
#     --admin-secret nuvia/intake-form/production/database \
#     --admin-key-host DB_HOST \
#     --admin-key-user DB_USER \
#     --admin-key-password DB_PASSWORD \
#     --target-secret nuvia/intake-form/production/analytics-db
#
#   # Dry run (show SQL + secret JSON without executing)
#   create-rds-database.sh --dry-run \
#     --database analytics \
#     --host mydb.rds.amazonaws.com \
#     --admin-user admin --admin-password 'secret' \
#     --target-secret nuvia/intake-form/staging/analytics-db
#
##############################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Defaults
PORT="3306"
REGION="${AWS_REGION:-us-west-1}"
SSL_MODE="rds"
DRY_RUN=false
DATABASE=""
HOST=""
ADMIN_USER=""
ADMIN_PASSWORD=""
ADMIN_SECRET=""
ADMIN_KEY_HOST="host"
ADMIN_KEY_USER="username"
ADMIN_KEY_PASSWORD="password"
ADMIN_KEY_PORT="port"
TARGET_SECRET=""
APP_USER=""
MIGRATIONS_USER=""

usage() {
  cat <<'USAGE'
Usage: create-rds-database.sh [OPTIONS]

Required:
  --database NAME           Database name to create
  --target-secret NAME      AWS Secrets Manager name for new credentials

Admin connection (pick one):
  Direct:
    --host HOSTNAME         RDS endpoint
    --admin-user USER       Admin username
    --admin-password PASS   Admin password

  From AWS Secret:
    --admin-secret NAME     Secret name containing admin credentials
    --admin-key-host KEY    JSON key for host        (default: host)
    --admin-key-user KEY    JSON key for username     (default: username)
    --admin-key-password KEY JSON key for password    (default: password)
    --admin-key-port KEY    JSON key for port         (default: port)

Optional:
  --app-user USER           App user name       (default: {database}_app)
  --migrations-user USER    Migrations user name (default: {database}_migrations)
  --port PORT               MySQL port           (default: 3306)
  --region REGION           AWS region           (default: us-west-1)
  --ssl MODE                SSL mode for secret  (default: rds)
  --dry-run                 Show plan without executing
  -h, --help                Show this help
USAGE
  exit 0
}

die() { echo -e "${RED}ERROR: $1${RESET}" >&2; exit 1; }
info() { echo -e "${CYAN}→${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET} $1"; }

##############################################################################
# Parse arguments
##############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --database)         DATABASE="$2";          shift 2 ;;
    --host)             HOST="$2";              shift 2 ;;
    --port)             PORT="$2";              shift 2 ;;
    --admin-user)       ADMIN_USER="$2";        shift 2 ;;
    --admin-password)   ADMIN_PASSWORD="$2";    shift 2 ;;
    --admin-secret)     ADMIN_SECRET="$2";      shift 2 ;;
    --admin-key-host)     ADMIN_KEY_HOST="$2";     shift 2 ;;
    --admin-key-user)     ADMIN_KEY_USER="$2";     shift 2 ;;
    --admin-key-password) ADMIN_KEY_PASSWORD="$2"; shift 2 ;;
    --admin-key-port)     ADMIN_KEY_PORT="$2";     shift 2 ;;
    --target-secret)    TARGET_SECRET="$2";     shift 2 ;;
    --app-user)         APP_USER="$2";          shift 2 ;;
    --migrations-user)  MIGRATIONS_USER="$2";   shift 2 ;;
    --region)           REGION="$2";            shift 2 ;;
    --ssl)              SSL_MODE="$2";          shift 2 ;;
    --dry-run)          DRY_RUN=true;           shift ;;
    -h|--help)          usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

##############################################################################
# Validate inputs
##############################################################################
[[ -z "${DATABASE}" ]] && die "--database is required"
[[ -z "${TARGET_SECRET}" ]] && die "--target-secret is required"

# Default user names from database name
[[ -z "${APP_USER}" ]] && APP_USER="${DATABASE}_app"
[[ -z "${MIGRATIONS_USER}" ]] && MIGRATIONS_USER="${DATABASE}_migrations"

##############################################################################
# Resolve admin credentials
##############################################################################
if [[ -n "${ADMIN_SECRET}" ]]; then
  info "Loading admin credentials from AWS secret: ${BOLD}${ADMIN_SECRET}${RESET}"

  if [[ "${DRY_RUN}" == true ]]; then
    warn "Dry run: would fetch secret ${ADMIN_SECRET} from region ${REGION}"
    # Need placeholder values for dry-run display
    [[ -z "${HOST}" ]] && HOST="<from-secret:${ADMIN_KEY_HOST}>"
    [[ -z "${ADMIN_USER}" ]] && ADMIN_USER="<from-secret:${ADMIN_KEY_USER}>"
    [[ -z "${ADMIN_PASSWORD}" ]] && ADMIN_PASSWORD="<from-secret:${ADMIN_KEY_PASSWORD}>"
  else
    ADMIN_JSON=$(aws --cli-read-timeout 30 --cli-connect-timeout 10 secretsmanager get-secret-value \
      --region "${REGION}" \
      --secret-id "${ADMIN_SECRET}" \
      --query SecretString \
      --output text 2>/dev/null) || die "Failed to fetch admin secret: ${ADMIN_SECRET}"

    [[ -z "${HOST}" ]] && HOST=$(echo "${ADMIN_JSON}" | jq -r ".${ADMIN_KEY_HOST} // empty") || true
    [[ -z "${ADMIN_USER}" ]] && ADMIN_USER=$(echo "${ADMIN_JSON}" | jq -r ".${ADMIN_KEY_USER} // empty") || true
    [[ -z "${ADMIN_PASSWORD}" ]] && ADMIN_PASSWORD=$(echo "${ADMIN_JSON}" | jq -r ".${ADMIN_KEY_PASSWORD} // empty") || true

    # Try to get port from admin secret if not overridden
    if [[ "${PORT}" == "3306" ]]; then
      SECRET_PORT=$(echo "${ADMIN_JSON}" | jq -r ".${ADMIN_KEY_PORT} // empty") || true
      [[ -n "${SECRET_PORT}" ]] && PORT="${SECRET_PORT}"
    fi
  fi
fi

[[ -z "${HOST}" ]] && die "--host is required (or provide --admin-secret with --admin-key-host)"
[[ -z "${ADMIN_USER}" ]] && die "--admin-user is required (or provide --admin-secret with --admin-key-user)"
[[ -z "${ADMIN_PASSWORD}" ]] && die "--admin-password is required (or provide --admin-secret with --admin-key-password)"

##############################################################################
# Generate passwords
##############################################################################
generate_password() {
  # 32-char alphanumeric + special chars, safe for MySQL and JSON
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

APP_PASSWORD=$(generate_password)
MIGRATIONS_PASSWORD=$(generate_password)

##############################################################################
# Display plan
##############################################################################
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     RDS Database & User Provisioning         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Host:${RESET}              ${HOST}"
echo -e "  ${BOLD}Port:${RESET}              ${PORT}"
echo -e "  ${BOLD}Admin user:${RESET}        ${ADMIN_USER}"
echo -e "  ${BOLD}Database:${RESET}          ${DATABASE}"
echo -e "  ${BOLD}App user:${RESET}          ${APP_USER}"
echo -e "  ${BOLD}Migrations user:${RESET}   ${MIGRATIONS_USER}"
echo -e "  ${BOLD}Target secret:${RESET}     ${TARGET_SECRET}"
echo -e "  ${BOLD}Region:${RESET}            ${REGION}"
echo -e "  ${BOLD}SSL:${RESET}               ${SSL_MODE}"
echo ""

##############################################################################
# Build SQL
##############################################################################
SQL_COMMANDS=$(cat <<EOSQL
-- 1. Create the database
CREATE DATABASE IF NOT EXISTS \`${DATABASE}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- 2. App user (DML: SELECT, INSERT, UPDATE, DELETE)
CREATE USER IF NOT EXISTS '${APP_USER}'@'%' IDENTIFIED BY '${APP_PASSWORD}';
ALTER USER '${APP_USER}'@'%' IDENTIFIED BY '${APP_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`${DATABASE}\`.* TO '${APP_USER}'@'%';

-- 3. Migrations user (DDL: CREATE, ALTER, DROP, INDEX, etc.)
CREATE USER IF NOT EXISTS '${MIGRATIONS_USER}'@'%' IDENTIFIED BY '${MIGRATIONS_PASSWORD}';
ALTER USER '${MIGRATIONS_USER}'@'%' IDENTIFIED BY '${MIGRATIONS_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES
  ON \`${DATABASE}\`.* TO '${MIGRATIONS_USER}'@'%';

FLUSH PRIVILEGES;
EOSQL
)

# Build the target secret JSON
SECRET_JSON=$(jq -n \
  --arg host "${HOST}" \
  --arg port "${PORT}" \
  --arg database "${DATABASE}" \
  --arg username "${APP_USER}" \
  --arg password "${APP_PASSWORD}" \
  --arg ssl "${SSL_MODE}" \
  --arg migrations_user "${MIGRATIONS_USER}" \
  --arg migrations_password "${MIGRATIONS_PASSWORD}" \
  '{
    host: $host,
    port: $port,
    database: $database,
    username: $username,
    password: $password,
    ssl: $ssl,
    migrations_user: $migrations_user,
    migrations_password: $migrations_password
  }')

##############################################################################
# Dry-run: display and exit
##############################################################################
if [[ "${DRY_RUN}" == true ]]; then
  echo -e "${YELLOW}── DRY RUN ──────────────────────────────────${RESET}"
  echo ""
  echo -e "${BOLD}SQL to execute:${RESET}"
  # Redact passwords in dry-run output
  echo "${SQL_COMMANDS}" \
    | sed "s/${APP_PASSWORD}/<GENERATED_APP_PASSWORD>/g" \
    | sed "s/${MIGRATIONS_PASSWORD}/<GENERATED_MIGRATIONS_PASSWORD>/g"
  echo ""
  echo -e "${BOLD}Secret to create (${TARGET_SECRET}):${RESET}"
  echo "${SECRET_JSON}" | jq '
    .password = "<GENERATED_APP_PASSWORD>" |
    .migrations_password = "<GENERATED_MIGRATIONS_PASSWORD>"
  '
  echo ""
  echo -e "${YELLOW}No changes made (dry run).${RESET}"
  exit 0
fi

##############################################################################
# Execute: Create database and users
##############################################################################
info "Creating database and users on ${HOST}..."

# Build mysql connection args
MYSQL_ARGS=(
  --host="${HOST}"
  --port="${PORT}"
  --user="${ADMIN_USER}"
  --password="${ADMIN_PASSWORD}"
  --ssl-mode=REQUIRED
  --connect-timeout=30
)

echo "${SQL_COMMANDS}" | mysql "${MYSQL_ARGS[@]}" 2>&1 || die "MySQL commands failed. Check admin credentials and network access."

success "Database '${DATABASE}' created"
success "User '${APP_USER}' created with DML privileges"
success "User '${MIGRATIONS_USER}' created with DDL privileges"

##############################################################################
# Execute: Store credentials in AWS Secrets Manager
##############################################################################
info "Storing credentials in AWS Secrets Manager: ${TARGET_SECRET}"

# Check if secret already exists
if aws --cli-read-timeout 30 --cli-connect-timeout 10 secretsmanager describe-secret \
    --region "${REGION}" \
    --secret-id "${TARGET_SECRET}" >/dev/null 2>&1; then
  warn "Secret already exists, updating value..."
  aws --cli-read-timeout 30 --cli-connect-timeout 10 secretsmanager put-secret-value \
    --region "${REGION}" \
    --secret-id "${TARGET_SECRET}" \
    --secret-string "${SECRET_JSON}" || die "Failed to update secret"
  success "Secret updated: ${TARGET_SECRET}"
else
  aws --cli-read-timeout 30 --cli-connect-timeout 10 secretsmanager create-secret \
    --region "${REGION}" \
    --name "${TARGET_SECRET}" \
    --secret-string "${SECRET_JSON}" \
    --description "Database credentials for ${DATABASE} (auto-generated)" || die "Failed to create secret"
  success "Secret created: ${TARGET_SECRET}"
fi

##############################################################################
# Verify
##############################################################################
info "Verifying app user can connect..."
mysql \
  --host="${HOST}" \
  --port="${PORT}" \
  --user="${APP_USER}" \
  --password="${APP_PASSWORD}" \
  --ssl-mode=REQUIRED \
  --connect-timeout=15 \
  --execute="SELECT 1" \
  "${DATABASE}" >/dev/null 2>&1 \
  && success "App user connection verified" \
  || warn "App user connection check failed (may need VPN or security group access)"

info "Verifying migrations user can connect..."
mysql \
  --host="${HOST}" \
  --port="${PORT}" \
  --user="${MIGRATIONS_USER}" \
  --password="${MIGRATIONS_PASSWORD}" \
  --ssl-mode=REQUIRED \
  --connect-timeout=15 \
  --execute="SELECT 1" \
  "${DATABASE}" >/dev/null 2>&1 \
  && success "Migrations user connection verified" \
  || warn "Migrations user connection check failed (may need VPN or security group access)"

echo ""
echo -e "${GREEN}${BOLD}Done!${RESET} Database '${DATABASE}' is ready."
echo -e "  Secret: ${TARGET_SECRET}"
echo -e "  App user: ${APP_USER}"
echo -e "  Migrations user: ${MIGRATIONS_USER}"
echo ""
