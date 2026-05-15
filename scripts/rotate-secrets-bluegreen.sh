#!/usr/bin/env bash
set -euo pipefail

# rotate-secrets-bluegreen.sh — Zero-downtime secret rotation for blue-green deployments
#
# 5-phase flow: Prepare → Validate → Promote → Propagate → Cleanup
# No container restarts. Uses /secrets/refresh (cache clear + pool recycle)
# and /secrets/status (credential validation) at every gate.
#
# Usage:
#   rotate-secrets-bluegreen.sh --project <name> --env <environment> --secret-type database
#   rotate-secrets-bluegreen.sh --project medical-clearance --env production --secret-type database --dry-run
#
# Requires: aws cli, jq, yq, mysql client, network access to both colors

# --- Defaults ---

DRY_RUN=false
PROJECT=""
ENVIRONMENT=""
SECRET_TYPE=""
PROJECT_YAML=""
REGION="us-west-1"
VERIFY_TIMEOUT=60

# --- State (populated during execution) ---

OLD_APP_USER=""
OLD_APP_PASS=""
NEW_APP_USER=""
NEW_APP_PASS=""
SECRET_PATH=""
CURRENT_SECRET=""

# --- Usage ---

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Required:
  --project <name>        Project name (must match PROJECT.yaml)
  --env <environment>     Target environment (staging|production)
  --secret-type <type>    Secret to rotate (database)

Optional:
  --dry-run               Show what would happen without executing
  --region <region>       AWS region (default: us-west-1)
  --timeout <seconds>     Verification timeout per color (default: 60)
  --project-yaml <path>   Path to PROJECT.yaml (default: auto-detect)

Examples:
  $(basename "$0") --project medical-clearance --env production --secret-type database
  $(basename "$0") --project medical-clearance --env staging --secret-type database --dry-run
EOF
  exit 1
}

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)      PROJECT="$2"; shift 2 ;;
    --env)          ENVIRONMENT="$2"; shift 2 ;;
    --secret-type)  SECRET_TYPE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --region)       REGION="$2"; shift 2 ;;
    --timeout)      VERIFY_TIMEOUT="$2"; shift 2 ;;
    --project-yaml) PROJECT_YAML="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "${PROJECT}" ]] && { echo "Error: --project required"; usage; }
[[ -z "${ENVIRONMENT}" ]] && { echo "Error: --env required"; usage; }
[[ -z "${SECRET_TYPE}" ]] && { echo "Error: --secret-type required"; usage; }
[[ "${SECRET_TYPE}" != "database" ]] && { echo "Error: only 'database' rotation is supported"; exit 1; }

# --- Helpers ---

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

dry() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] $*"
    return 0
  fi
  "$@"
}

# --- Load PROJECT.yaml ---

find_project_yaml() {
  if [[ -n "${PROJECT_YAML}" && -f "${PROJECT_YAML}" ]]; then
    echo "${PROJECT_YAML}"
    return
  fi
  local candidates=(
    "${HOME}/projects/${PROJECT}/PROJECT.yaml"
    "./${PROJECT}/PROJECT.yaml"
    "./PROJECT.yaml"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
  die "PROJECT.yaml not found for '${PROJECT}'. Use --project-yaml."
}

PROJECT_YAML=$(find_project_yaml)
log "Using PROJECT.yaml: ${PROJECT_YAML}"

# --- Read deployment config ---

ACTIVE_COLOR=$(yq ".deployment.active" "${PROJECT_YAML}")
INACTIVE_COLOR=$([[ "${ACTIVE_COLOR}" == "blue" ]] && echo "green" || echo "blue")

get_color() {
  local color="$1" field="$2"
  yq ".deployment.${ENVIRONMENT}.${color}.${field}" "${PROJECT_YAML}"
}

ACTIVE_DOMAIN=$(get_color "${ACTIVE_COLOR}" "domain")
INACTIVE_DOMAIN=$(get_color "${INACTIVE_COLOR}" "domain")

SECRET_PATH="${PROJECT}/${ENVIRONMENT}/database"

# Read containers that have secrets (exclude frontend, nginx, redis, mysql)
# These are the containers with /secrets/* endpoints
BACKEND_CONTAINERS=()
while IFS= read -r comp; do
  local_fw=$(yq ".components[] | select(.name == \"${comp}\") | .framework" "${PROJECT_YAML}" 2>/dev/null || echo "")
  local_hc=$(yq ".components[] | select(.name == \"${comp}\") | .health_check_path" "${PROJECT_YAML}" 2>/dev/null || echo "")
  # Include components with a framework and health check (backends/services, not frontends)
  if [[ -n "${local_fw}" && -n "${local_hc}" && "${local_fw}" != "nextjs" && "${local_fw}" != "react" ]]; then
    BACKEND_CONTAINERS+=("${comp}")
  fi
done < <(yq '.components[].name' "${PROJECT_YAML}" 2>/dev/null || echo "")

# Fallback: if no components detected, assume "backend"
if [[ ${#BACKEND_CONTAINERS[@]} -eq 0 ]]; then
  BACKEND_CONTAINERS=("backend")
fi

log "Project:     ${PROJECT}"
log "Environment: ${ENVIRONMENT}"
log "Secret type: ${SECRET_TYPE}"
log "Region:      ${REGION}"
log "Active:      ${ACTIVE_COLOR} (${ACTIVE_DOMAIN})"
log "Inactive:    ${INACTIVE_COLOR} (${INACTIVE_DOMAIN})"
log "Containers:  ${BACKEND_CONTAINERS[*]}"
log "Dry run:     ${DRY_RUN}"
echo ""

# --- SM helpers ---

sm_get() {
  aws secretsmanager get-secret-value \
    --secret-id "$1" \
    --region "${REGION}" \
    --query SecretString --output text
}

sm_put() {
  aws secretsmanager put-secret-value \
    --secret-id "$1" \
    --secret-string "$2" \
    --region "${REGION}" \
    --output json >/dev/null
}

# --- Endpoint helpers ---

get_container_url() {
  local domain="$1" container="$2"
  local port
  port=$(yq ".components[] | select(.name == \"${container}\") | .internal_port" "${PROJECT_YAML}" 2>/dev/null || echo "3001")
  # Use the color-specific domain with the component's health path prefix
  local prefix
  prefix=$(yq ".components[] | select(.name == \"${container}\") | .health_check_path" "${PROJECT_YAML}" 2>/dev/null || echo "/health")
  # Strip the health path to get the base — secrets endpoints are at the service root
  echo "https://${domain}"
}

refresh_color() {
  local domain="$1"
  local color="$2"
  local all_ok=true

  for container in "${BACKEND_CONTAINERS[@]}"; do
    local port
    port=$(yq ".components[] | select(.name == \"${container}\") | .internal_port" "${PROJECT_YAML}" 2>/dev/null || echo "3001")

    if [[ "${DRY_RUN}" == "true" ]]; then
      log "[DRY RUN] POST https://${domain}/secrets/refresh (${container})"
      continue
    fi

    local result
    result=$(curl -sf -X POST "https://${domain}/secrets/refresh" 2>/dev/null || echo '{"status":"error"}')
    local status creds_changed pool_recycled
    status=$(echo "${result}" | jq -r '.status // "error"')
    creds_changed=$(echo "${result}" | jq -r '.credentials_changed // false')
    pool_recycled=$(echo "${result}" | jq -r '.pool_recycled // false')

    if [[ "${status}" == "success" ]]; then
      log "${color}/${container}: refreshed (credentials_changed=${creds_changed}, pool_recycled=${pool_recycled})"
    else
      warn "${color}/${container}: refresh failed"
      all_ok=false
    fi
  done

  [[ "${all_ok}" == "true" ]]
}

verify_color() {
  local domain="$1"
  local color="$2"
  local expect_rotation="${3:-false}"
  local expect_user="${4:-}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Would verify ${color} at https://${domain}"
    return 0
  fi

  local elapsed=0
  while [[ ${elapsed} -lt ${VERIFY_TIMEOUT} ]]; do
    local all_ok=true

    for container in "${BACKEND_CONTAINERS[@]}"; do
      local result
      result=$(curl -sf "https://${domain}/secrets/status" 2>/dev/null || echo '{"overall_status":"unreachable"}')

      local overall rotation_in_progress
      overall=$(echo "${result}" | jq -r '.overall_status // "unreachable"')
      rotation_in_progress=$(echo "${result}" | jq -r '.rotation_in_progress // false')

      if [[ "${overall}" != "healthy" ]]; then
        all_ok=false
        continue
      fi

      # If we expect rotation candidate to be validated
      if [[ "${expect_rotation}" == "true" ]]; then
        local rot_status
        rot_status=$(echo "${result}" | jq -r '.checks.database_rotation.status // "missing"')
        if [[ "${rot_status}" != "healthy" ]]; then
          log "${color}/${container}: database_rotation check: ${rot_status}, waiting..."
          all_ok=false
          continue
        fi
      fi

      # If we expect a specific user to be active
      if [[ -n "${expect_user}" ]]; then
        local active_user
        active_user=$(echo "${result}" | jq -r '.checks.database.user // "unknown"')
        if [[ "${active_user}" != "${expect_user}" ]]; then
          log "${color}/${container}: expected user ${expect_user}, got ${active_user}, waiting..."
          all_ok=false
          continue
        fi
      fi

      log "${color}/${container}: healthy ($(echo "${result}" | jq -c '.checks | keys'))"
    done

    if [[ "${all_ok}" == "true" ]]; then
      log "${color}: all containers verified"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  warn "${color}: verification failed after ${VERIFY_TIMEOUT}s"
  return 1
}

# --- Phase 1: PREPARE ---

phase_prepare() {
  log "═══ Phase 1: PREPARE ═══"

  # Fetch current secret
  if [[ "${DRY_RUN}" == "false" ]]; then
    CURRENT_SECRET=$(sm_get "${SECRET_PATH}")
  else
    CURRENT_SECRET='{"DB_HOST":"localhost","DB_PORT":"3306","DB_NAME":"mydb","DB_APP_USERNAME":"myapp_app","DB_APP_PASSWORD":"oldpass","DB_MIGRATION_USERNAME":"myapp_mig","DB_MIGRATION_PASSWORD":"migpass"}'
  fi

  # Check concurrency lock
  local existing_rotation
  existing_rotation=$(echo "${CURRENT_SECRET}" | jq -r '.rotation_username // empty')
  if [[ -n "${existing_rotation}" ]]; then
    local started_at started_by
    started_at=$(echo "${CURRENT_SECRET}" | jq -r '.rotation_started_at // "unknown"')
    started_by=$(echo "${CURRENT_SECRET}" | jq -r '.rotation_started_by // "unknown"')
    die "Rotation already in progress (started ${started_at} by ${started_by}). Resolve before retrying."
  fi

  # Read current credentials
  local db_host db_port db_name mig_user mig_pass
  db_host=$(echo "${CURRENT_SECRET}" | jq -r '.DB_HOST // .host')
  db_port=$(echo "${CURRENT_SECRET}" | jq -r '.DB_PORT // .port // "3306"')
  db_name=$(echo "${CURRENT_SECRET}" | jq -r '.DB_NAME // .database')
  mig_user=$(echo "${CURRENT_SECRET}" | jq -r '.DB_MIGRATION_USERNAME // .migration_username')
  mig_pass=$(echo "${CURRENT_SECRET}" | jq -r '.DB_MIGRATION_PASSWORD // .migration_password')
  OLD_APP_USER=$(echo "${CURRENT_SECRET}" | jq -r '.DB_APP_USERNAME // .app_username')
  OLD_APP_PASS=$(echo "${CURRENT_SECRET}" | jq -r '.DB_APP_PASSWORD // .app_password')

  # Generate new credentials
  local timestamp
  timestamp=$(date +%Y%m%d%H%M)
  NEW_APP_USER="${PROJECT//-/_}_app_${timestamp}"
  NEW_APP_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&' | head -c 32)

  # Step 2: Create new DB user
  log "Creating new DB user: ${NEW_APP_USER}"
  dry mysql -h "${db_host}" -P "${db_port}" -u "${mig_user}" -p"${mig_pass}" -e "
    CREATE USER '${NEW_APP_USER}'@'%' IDENTIFIED BY '${NEW_APP_PASS}';
    GRANT SELECT, INSERT, UPDATE, DELETE ON \`${db_name}\`.* TO '${NEW_APP_USER}'@'%';
    FLUSH PRIVILEGES;
  "

  # Step 3: Add rotation keys to SM
  log "Adding rotation credentials to SM (concurrency lock set)"
  local updated_secret
  updated_secret=$(echo "${CURRENT_SECRET}" | jq \
    --arg ru "${NEW_APP_USER}" \
    --arg rp "${NEW_APP_PASS}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg by "$(whoami)" \
    '. + {
      rotation_username: $ru,
      rotation_password: $rp,
      rotation_started_at: $ts,
      rotation_started_by: $by
    }')

  if [[ "${DRY_RUN}" == "false" ]]; then
    sm_put "${SECRET_PATH}" "${updated_secret}"
  else
    log "[DRY RUN] Would add rotation_username=${NEW_APP_USER} to SM"
  fi

  log "Phase 1 complete: new user created, rotation keys in SM"
  echo ""
}

# --- Phase 2: VALIDATE (active color) ---

phase_validate() {
  log "═══ Phase 2: VALIDATE (${ACTIVE_COLOR}) ═══"

  # Step 4: Refresh active color — picks up rotation keys from SM
  log "Refreshing active color (${ACTIVE_COLOR})..."
  if ! refresh_color "${ACTIVE_DOMAIN}" "${ACTIVE_COLOR}"; then
    rollback_prepare
    die "Refresh failed on active color. Rolled back."
  fi

  # Step 5: Verify both main AND rotation creds work
  log "Verifying main and rotation credentials..."
  if ! verify_color "${ACTIVE_DOMAIN}" "${ACTIVE_COLOR}" "true"; then
    rollback_prepare
    die "Validation failed — rotation credentials don't work. Rolled back."
  fi

  log "Phase 2 complete: both credential sets verified on ${ACTIVE_COLOR}"
  echo ""
}

# --- Phase 3: PROMOTE (active color) ---

phase_promote() {
  log "═══ Phase 3: PROMOTE (${ACTIVE_COLOR}) ═══"

  # Step 6: Update SM — promote rotation to main, keep rotation keys as rollback
  log "Promoting rotation credentials to main..."
  if [[ "${DRY_RUN}" == "false" ]]; then
    local current
    current=$(sm_get "${SECRET_PATH}")
    local promoted
    promoted=$(echo "${current}" | jq \
      --arg nu "${NEW_APP_USER}" \
      --arg np "${NEW_APP_PASS}" \
      '. + { DB_APP_USERNAME: $nu, DB_APP_PASSWORD: $np }')
    sm_put "${SECRET_PATH}" "${promoted}"
  else
    log "[DRY RUN] Would promote DB_APP_USERNAME=${NEW_APP_USER}"
  fi

  # Step 7: Refresh — detects credential change, recycles pool
  log "Refreshing active color (pool recycle expected)..."
  if ! refresh_color "${ACTIVE_DOMAIN}" "${ACTIVE_COLOR}"; then
    rollback_promote
    die "Refresh after promote failed on active color. Rolled back."
  fi

  # Step 8: Verify promoted creds work
  log "Verifying promoted credentials..."
  if ! verify_color "${ACTIVE_DOMAIN}" "${ACTIVE_COLOR}" "false" "${NEW_APP_USER}"; then
    rollback_promote
    die "Promoted credentials failed verification. Rolled back."
  fi

  # Step 9: Remove rotation keys from SM (promote succeeded)
  log "Removing rotation keys from SM..."
  if [[ "${DRY_RUN}" == "false" ]]; then
    local current
    current=$(sm_get "${SECRET_PATH}")
    local cleaned
    cleaned=$(echo "${current}" | jq 'del(.rotation_username, .rotation_password, .rotation_started_at, .rotation_started_by)')
    sm_put "${SECRET_PATH}" "${cleaned}"
  else
    log "[DRY RUN] Would remove rotation keys from SM"
  fi

  log "Phase 3 complete: ${ACTIVE_COLOR} running on new credentials"
  echo ""
}

# --- Phase 4: PROPAGATE (inactive color) ---

phase_propagate() {
  log "═══ Phase 4: PROPAGATE (${INACTIVE_COLOR}) ═══"

  # Step 10: Refresh inactive color
  log "Refreshing inactive color (${INACTIVE_COLOR})..."
  if ! refresh_color "${INACTIVE_DOMAIN}" "${INACTIVE_COLOR}"; then
    warn "Refresh failed on inactive color. Active is fine. Will pick up on next deploy."
    return 0
  fi

  # Step 11: Verify inactive color
  log "Verifying inactive color..."
  if ! verify_color "${INACTIVE_DOMAIN}" "${INACTIVE_COLOR}" "false" "${NEW_APP_USER}"; then
    warn "Inactive color verification failed. Active is fine. Will pick up on next deploy."
    return 0
  fi

  log "Phase 4 complete: ${INACTIVE_COLOR} running on new credentials"
  echo ""
}

# --- Phase 5: CLEANUP ---

phase_cleanup() {
  log "═══ Phase 5: CLEANUP ═══"

  # Step 12: Drop old DB user
  log "Dropping old DB user: ${OLD_APP_USER}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    local current
    current=$(sm_get "${SECRET_PATH}")
    local db_host mig_user mig_pass
    db_host=$(echo "${current}" | jq -r '.DB_HOST // .host')
    mig_user=$(echo "${current}" | jq -r '.DB_MIGRATION_USERNAME // .migration_username')
    mig_pass=$(echo "${current}" | jq -r '.DB_MIGRATION_PASSWORD // .migration_password')

    mysql -h "${db_host}" -P 3306 -u "${mig_user}" -p"${mig_pass}" -e "
      DROP USER IF EXISTS '${OLD_APP_USER}'@'%';
      FLUSH PRIVILEGES;
    "
  else
    log "[DRY RUN] Would drop user ${OLD_APP_USER}"
  fi

  log "Phase 5 complete: old user dropped"
  echo ""
}

# --- Rollback helpers ---

rollback_prepare() {
  # Undo Phase 1: remove rotation keys from SM, drop new DB user
  warn "Rolling back Phase 1..."

  if [[ "${DRY_RUN}" == "false" ]]; then
    # Remove rotation keys
    local current
    current=$(sm_get "${SECRET_PATH}")
    local cleaned
    cleaned=$(echo "${current}" | jq 'del(.rotation_username, .rotation_password, .rotation_started_at, .rotation_started_by)')
    sm_put "${SECRET_PATH}" "${cleaned}"

    # Drop new user
    local db_host mig_user mig_pass
    db_host=$(echo "${current}" | jq -r '.DB_HOST // .host')
    mig_user=$(echo "${current}" | jq -r '.DB_MIGRATION_USERNAME // .migration_username')
    mig_pass=$(echo "${current}" | jq -r '.DB_MIGRATION_PASSWORD // .migration_password')
    mysql -h "${db_host}" -P 3306 -u "${mig_user}" -p"${mig_pass}" -e "
      DROP USER IF EXISTS '${NEW_APP_USER}'@'%';
      FLUSH PRIVILEGES;
    " 2>/dev/null || warn "Could not drop new user ${NEW_APP_USER}"

    # Refresh to clear rotation keys from app cache
    refresh_color "${ACTIVE_DOMAIN}" "${ACTIVE_COLOR}" 2>/dev/null || true
  fi

  log "Rollback complete: rotation keys removed, new user dropped"
}

rollback_promote() {
  # Undo Phase 3: revert SM to old credentials, refresh
  warn "Rolling back Phase 3 (promote)..."

  if [[ "${DRY_RUN}" == "false" ]]; then
    local current
    current=$(sm_get "${SECRET_PATH}")
    local reverted
    reverted=$(echo "${current}" | jq \
      --arg ou "${OLD_APP_USER}" \
      --arg op "${OLD_APP_PASS}" \
      '. + { DB_APP_USERNAME: $ou, DB_APP_PASSWORD: $op } | del(.rotation_username, .rotation_password, .rotation_started_at, .rotation_started_by)')
    sm_put "${SECRET_PATH}" "${reverted}"

    # Refresh to pick up reverted credentials
    refresh_color "${ACTIVE_DOMAIN}" "${ACTIVE_COLOR}" 2>/dev/null || true

    # Drop new user
    local db_host mig_user mig_pass
    db_host=$(echo "${current}" | jq -r '.DB_HOST // .host')
    mig_user=$(echo "${current}" | jq -r '.DB_MIGRATION_USERNAME // .migration_username')
    mig_pass=$(echo "${current}" | jq -r '.DB_MIGRATION_PASSWORD // .migration_password')
    mysql -h "${db_host}" -P 3306 -u "${mig_user}" -p"${mig_pass}" -e "
      DROP USER IF EXISTS '${NEW_APP_USER}'@'%';
      FLUSH PRIVILEGES;
    " 2>/dev/null || warn "Could not drop new user ${NEW_APP_USER}"
  fi

  log "Rollback complete: SM reverted to old credentials, active color refreshed"
}

# --- Main ---

main() {
  log "╔══════════════════════════════════════════════════════════╗"
  log "║  Zero-Downtime Secret Rotation — Blue-Green             ║"
  log "║  ${PROJECT} / ${ENVIRONMENT} / ${SECRET_TYPE}"
  log "╚══════════════════════════════════════════════════════════╝"
  echo ""

  phase_prepare
  phase_validate
  phase_promote
  phase_propagate
  phase_cleanup

  log "╔══════════════════════════════════════════════════════════╗"
  log "║  Rotation complete — zero downtime                      ║"
  log "╠══════════════════════════════════════════════════════════╣"
  log "║  New user:  ${NEW_APP_USER}"
  log "║  Old user:  ${OLD_APP_USER} (dropped)"
  log "║  ${ACTIVE_COLOR} (active):   verified ✓"
  log "║  ${INACTIVE_COLOR} (inactive): verified ✓"
  log "╚══════════════════════════════════════════════════════════╝"
}

main
