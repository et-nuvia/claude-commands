#!/usr/bin/env bash
# get-config.sh - Single entry point for PROJECT.yaml values
#
# Philosophy: one call, all business logic inside, action-ready output.
# Callers never need to inspect strategy or topology — the script handles it.
#
# Usage: get-config.sh --FIELD [OPTIONS]
#
# ── Deploy fields ─────────────────────────────────────────────────────────────
#   --deploy-ip          IP address for deployment target
#   --deploy-instance    EC2 instance ID
#   --deploy-method      ssm | ssh | script | pipeline
#   --deploy-region      AWS region (3-level fallback: server → env → top-level)
#   --deploy-rds-host    RDS hostname
#   --deploy-containers  Container names (newline-separated)
#   --deploy-firebase    Firebase project ID
#
# ── Database secret fields ────────────────────────────────────────────────────
#   --db-host            Database hostname (fetched from secrets backend)
#   --db-port            Database port (fetched from secrets backend)
#   --db-name            Database name (fetched from secrets backend)
#   --db-username        Database username (fetched from secrets backend)
#   --db-password        Database password (fetched from secrets backend)
#
#   DB secret lookup reads PROJECT.yaml for the secret_bucket + key name,
#   then fetches the actual value from AWS Secrets Manager or Infisical.
#   Secret path (AWS): {app-name}/{env}/{secret_bucket}
#   Secret path (Infisical): env={env}, path=/{secret_bucket}, key={secret_key}
#
# ── Other fields ──────────────────────────────────────────────────────────────
#   --app-name           Application name
#   --secrets-backend    aws | infisical (auto-detected if not set)
#   --test-command       Primary test command
#   --coverage-command   Coverage command
#   --e2e-command        E2E test command
#   --ci-platform        github | gitlab (auto-detected if not set)
#   --dev-branch         Branch used for development (ci.branches.dev)
#   --staging-branch     Branch that deploys to staging
#   --production-branch  Branch that deploys to production
#   --git-repo           owner/repo or group/project
#   --asana-workspace    Asana workspace GID
#   --asana-project      Asana project GID
#   --docs-dir           Documentation directory (default: "docs")
#
# ── Options ──────────────────────────────────────────────────────────────────
#   --env staging|production         Target environment (default: production)
#   --color active|inactive|blue|green  Server color for blue-green (default: active)
#   --ip-type public|private         Override ip_access setting
#   --db application|analytics|primary|metrics  Which database (default: application)
#   --user app|migration             Which DB user type (default: app)
#   --file PATH                      Path to PROJECT.yaml (default: ./PROJECT.yaml)
#
# ── Return values ─────────────────────────────────────────────────────────────
#   Value on stdout on success.
#   "pipeline" when strategy is none — deployment is complete on git push.
#   Error on stderr + non-zero exit when field missing, misconfigured, or not found in secrets.
#
# ── Exit codes ────────────────────────────────────────────────────────────────
#   0  Value printed to stdout (including "pipeline")
#   1  Field not configured or secret not found
#   2  PROJECT.yaml not found
#   3  Invalid arguments
#   4  Strategy mismatch

set -euo pipefail

# shellcheck source=lib/load-profile.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/load-profile.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────

FIELD=""
ENV="production"
COLOR="active"
IP_TYPE=""
DB="application"
DB_EXPLICIT=false
DB_USER="app"
PROJECT_FILE="PROJECT.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-ip|--deploy-instance|--deploy-method|--deploy-region|\
    --deploy-rds-host|--deploy-containers|--deploy-firebase|\
    --db-host|--db-port|--db-name|--db-username|--db-password|\
    --app-name|--secrets-backend|--test-command|--coverage-command|\
    --e2e-command|--ci-platform|--dev-branch|--staging-branch|--production-branch|\
    --git-repo|--asana-workspace|--asana-project|--docs-dir)
      FIELD="${1#--}"; shift ;;
    --env)      ENV="$2";          shift 2 ;;
    --color)    COLOR="$2";        shift 2 ;;
    --ip-type)  IP_TYPE="$2";      shift 2 ;;
    --db)       DB="$2"; DB_EXPLICIT=true; shift 2 ;;
    --user)     DB_USER="$2";      shift 2 ;;
    --file)     PROJECT_FILE="$2"; shift 2 ;;
    --help|-h)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "ERROR: Unknown argument: $1 — run $(basename "$0") --help" >&2
      exit 3 ;;
  esac
done

[[ -z "$FIELD" ]] && { echo "ERROR: No field specified — run $(basename "$0") --help" >&2; exit 3; }

# ── Validation ────────────────────────────────────────────────────────────────

[[ ! -f "$PROJECT_FILE" ]] && { echo "ERROR: $PROJECT_FILE not found — run: /project-config init" >&2; exit 2; }
command -v yq &>/dev/null    || { echo "ERROR: yq not installed — brew install yq" >&2; exit 3; }

[[ "$ENV" != "staging" && "$ENV" != "production" ]] && {
  echo "ERROR: --env must be staging or production, got: $ENV" >&2; exit 3; }

[[ "$COLOR" != "active" && "$COLOR" != "inactive" && "$COLOR" != "blue" && "$COLOR" != "green" ]] && {
  echo "ERROR: --color must be active, inactive, blue, or green, got: $COLOR" >&2; exit 3; }

# Normalize --db aliases (metrics/analytics are truly synonymous; primary is NOT aliased
# because a project may literally name their DB "primary" — use the fallback for that)
case "$DB" in
  metrics)  DB="analytics" ;;
esac

[[ "$DB_USER" != "app" && "$DB_USER" != "migration" ]] && {
  echo "ERROR: --user must be app or migration, got: $DB_USER" >&2; exit 3; }

# ── Core helpers ──────────────────────────────────────────────────────────────

yq_get() {
  local val
  val=$(yq "$1" "$PROJECT_FILE" 2>/dev/null || true)
  [[ "$val" == "null" || -z "$val" ]] && echo "" || echo "$val"
}

env_type() {
  profile_active_environment
}

# Returns: blue-green | standard | single | none
get_strategy() {
  local s
  s=$(yq_get ".deployment.strategy")
  if [[ -n "$s" ]]; then echo "$s"; return; fi
  # Auto-detect from structure
  local et
  et=$(env_type)
  # Blue-green is detected from STRUCTURE (a blue/green pair, or the roving
  # domain that fronts them), not from a stored `active:` key. A project that
  # correctly lets DNS decide which side is live has no `active:` to find, and
  # keying detection on it classified exactly those projects as "standard".
  if   [[ -n "$(yq_get ".deployment.${et}.staging.blue.instance_id")" ]] \
    || [[ -n "$(yq_get ".deployment.${et}.staging.roving_domain")" ]] \
    || [[ -n "$(yq_get ".deployment.${et}.staging.active")" ]];       then echo "blue-green"
  elif [[ -n "$(yq_get ".deployment.${et}.staging.instance_id")" ]];  then echo "standard"
  elif [[ -n "$(yq_get ".deployment.${et}.server.instance_id")" ]];   then echo "single"
  else echo "none"
  fi
}

# Which color is live, according to DNS.
#
# DNS IS THE SOURCE OF TRUTH for blue-green. A cutover repoints the roving
# domain; nothing writes the result back into PROJECT.yaml, so a stored
# `active:` key is only ever as fresh as the last person who remembered to
# edit it. Reading it would hand callers a stale color after every cutover —
# and the caller most likely to ask is a deploy, which would then target the
# live side. lib/deployment-config.sh already resolves this way; this keeps
# get-config.sh from being a second, disagreeing source of truth.
#
# Echoes "blue" or "green". Returns 1 when DNS cannot settle it (no dig, no
# roving_domain, unconfigured IPs, resolution failure, or an address matching
# neither color) so the caller can fall back and say so.
#
# Both layouts are accepted: this script's environment-scoped tree
# (.deployment.<env_type>.<env>.*) and the flat one deployment-config.sh reads
# (.deployment.<env>.*).
dns_active_color() {
  local et="$1" env="$2"
  command -v dig >/dev/null 2>&1 || return 1

  local roving blue_ip green_ip resolved
  roving=$(yq_get ".deployment.${et}.${env}.roving_domain")
  [[ -z "$roving" ]] && roving=$(yq_get ".deployment.${env}.roving_domain")
  blue_ip=$(yq_get ".deployment.${et}.${env}.blue.public_ip")
  [[ -z "$blue_ip" ]] && blue_ip=$(yq_get ".deployment.${env}.blue.public_ip")
  green_ip=$(yq_get ".deployment.${et}.${env}.green.public_ip")
  [[ -z "$green_ip" ]] && green_ip=$(yq_get ".deployment.${env}.green.public_ip")

  [[ -z "$roving" || -z "$blue_ip" || -z "$green_ip" ]] && return 1

  # Public resolver, so a local cache lagging a cutover cannot answer for us.
  resolved=$(dig +short "$roving" @1.1.1.1 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
  [[ -z "$resolved" ]] && return 1

  if   [[ "$resolved" == "$blue_ip" ]];  then echo "blue"
  elif [[ "$resolved" == "$green_ip" ]]; then echo "green"
  else return 1
  fi
}

# Resolve "active"/"inactive" to "blue" or "green"
resolve_color() {
  local strat="$1"
  [[ "$strat" != "blue-green" ]] && return  # color only matters for blue-green
  local et
  et=$(env_type)

  case "$COLOR" in
    blue|green) echo "$COLOR"; return ;;
  esac

  local live
  if ! live=$(dns_active_color "$et" "$ENV"); then
    # Fall back to the stored key ONLY so a project that has not configured
    # roving_domain/public_ip still works. It is explicitly a fallback: name it
    # as one, so a stale answer is never mistaken for a resolved one.
    live=$(yq_get ".deployment.${et}.${ENV}.active")
    [[ -z "$live" ]] && live=$(yq_get ".deployment.${ENV}.active")
    if [[ -z "$live" ]]; then
      echo "ERROR: cannot determine the active color for ${ENV}." >&2
      echo "  DNS is the source of truth — set deployment.${ENV}.roving_domain plus" >&2
      echo "  blue.public_ip and green.public_ip in $PROJECT_FILE (and install dig)." >&2
      exit 1
    fi
    echo "WARN: DNS could not resolve the active color for ${ENV}; falling back to the stored deployment.${ENV}.active=${live}, which is only as current as the last manual edit" >&2
  fi

  case "$COLOR" in
    active)   echo "$live" ;;
    inactive) [[ "$live" == "green" ]] && echo "blue" || echo "green" ;;
  esac
}

# Preferred IP key from --ip-type or ip_access setting
ip_key() {
  local t="${IP_TYPE}"
  if [[ -z "$t" ]]; then
    t=$(yq_get ".deployment.ip_access")
    [[ -z "$t" ]] && t="private"
  fi
  [[ "$t" == "public" ]] && echo "public_ip" || echo "private_ip"
}

# Resolve a value through: server-level → env-level → top-level → error
# Args: $1=field_name $2=color(optional) $3=error_label
resolve_with_fallback() {
  local field="$1"
  local color="$2"
  local label="$3"
  local et
  et=$(env_type)
  local v=""

  # Level 1: server-specific (blue-green with color, or single server)
  if [[ -n "$color" ]]; then
    v=$(yq_get ".deployment.${et}.${ENV}.${color}.${field}")
  fi

  # Level 2: env-level
  if [[ -z "$v" ]]; then
    v=$(yq_get ".deployment.${et}.${ENV}.${field}")
  fi

  # Level 3: top-level default
  if [[ -z "$v" ]]; then
    v=$(yq_get ".deployment.${field}")
  fi

  if [[ -z "$v" ]]; then
    echo "ERROR: ${label} not configured — set deployment.${field} as a top-level default in $PROJECT_FILE" >&2
    exit 1
  fi
  echo "$v"
}

# ── Deploy field handlers ─────────────────────────────────────────────────────

handle_deploy_ip() {
  local strat
  strat=$(get_strategy)
  [[ "$strat" == "none" ]] && { echo "pipeline"; return; }

  local et
  et=$(env_type)
  local key
  key=$(ip_key)
  local v=""

  case "$strat" in
    blue-green)
      local color
      color=$(resolve_color "$strat")
      v=$(yq_get ".deployment.${et}.${ENV}.${color}.${key}") ;;
    standard)
      v=$(yq_get ".deployment.${et}.${ENV}.${key}") ;;
    single)
      v=$(yq_get ".deployment.${et}.server.${key}") ;;
  esac

  if [[ -z "$v" ]]; then
    local ip_type="${IP_TYPE:-$(yq_get ".deployment.ip_access")}"
    [[ -z "$ip_type" ]] && ip_type="private"
    echo "ERROR: ${ip_type}_ip not configured for $ENV (strategy: $strat)" >&2
    exit 1
  fi
  echo "$v"
}

handle_deploy_instance() {
  local strat
  strat=$(get_strategy)
  [[ "$strat" == "none" ]] && { echo "pipeline"; return; }

  local et
  et=$(env_type)
  local v=""

  case "$strat" in
    blue-green)
      local color
      color=$(resolve_color "$strat")
      v=$(yq_get ".deployment.${et}.${ENV}.${color}.instance_id") ;;
    standard)
      v=$(yq_get ".deployment.${et}.${ENV}.instance_id") ;;
    single)
      v=$(yq_get ".deployment.${et}.server.instance_id") ;;
  esac

  [[ -z "$v" ]] && { echo "ERROR: instance_id not configured for $ENV (strategy: $strat)" >&2; exit 1; }
  echo "$v"
}

handle_deploy_region() {
  local strat
  strat=$(get_strategy)
  [[ "$strat" == "none" ]] && { echo "pipeline"; return; }

  local color=""
  [[ "$strat" == "blue-green" ]] && color=$(resolve_color "$strat")

  # single uses server path, not env path — normalize for resolve_with_fallback
  if [[ "$strat" == "single" ]]; then
    local et
    et=$(env_type)
    local v
    v=$(yq_get ".deployment.${et}.server.region")
    [[ -z "$v" ]] && v=$(yq_get ".deployment.region")
    [[ -z "$v" ]] && { echo "ERROR: region not configured — set deployment.region as top-level default in $PROJECT_FILE" >&2; exit 1; }
    echo "$v"
    return
  fi

  resolve_with_fallback "region" "$color" "region"
}

handle_deploy_method() {
  local strat
  strat=$(get_strategy)
  [[ "$strat" == "none" ]] && { echo "pipeline"; return; }

  local color=""
  [[ "$strat" == "blue-green" ]] && color=$(resolve_color "$strat")

  if [[ "$strat" == "single" ]]; then
    local et
    et=$(env_type)
    local v
    v=$(yq_get ".deployment.${et}.server.method")
    [[ -z "$v" ]] && v=$(yq_get ".deployment.method")
    [[ -z "$v" ]] && v="pipeline"
    echo "$v"
    return
  fi

  local v
  v=$(resolve_with_fallback "method" "$color" "method") 2>/dev/null || v="pipeline"
  echo "$v"
}

handle_deploy_rds_host() {
  local strat
  strat=$(get_strategy)
  [[ "$strat" == "none" ]] && { echo "pipeline"; return; }

  local et
  et=$(env_type)
  local v=""
  case "$strat" in
    blue-green|standard) v=$(yq_get ".deployment.${et}.${ENV}.rds_host") ;;
    single)              v=$(yq_get ".deployment.${et}.server.rds_host") ;;
  esac
  # Top-level fallback
  [[ -z "$v" ]] && v=$(yq_get ".deployment.rds_host")
  [[ -z "$v" ]] && { echo "ERROR: rds_host not configured for $ENV (strategy: $strat)" >&2; exit 1; }
  echo "$v"
}

handle_deploy_containers() {
  local strat
  strat=$(get_strategy)
  [[ "$strat" == "none" ]] && { echo "pipeline"; return; }

  local et
  et=$(env_type)
  local path
  case "$strat" in
    blue-green|standard) path=".deployment.${et}.${ENV}.containers[]" ;;
    single)              path=".deployment.${et}.server.containers[]" ;;
  esac
  local v
  v=$(yq "$path" "$PROJECT_FILE" 2>/dev/null || true)
  # Top-level fallback
  if [[ -z "$v" || "$v" == "null" ]]; then
    v=$(yq ".deployment.containers[]" "$PROJECT_FILE" 2>/dev/null || true)
  fi
  [[ -z "$v" || "$v" == "null" ]] && { echo "ERROR: containers not configured for $ENV (strategy: $strat)" >&2; exit 1; }
  echo "$v"
}

handle_deploy_firebase() {
  local strat
  strat=$(get_strategy)
  [[ "$strat" == "none" ]] && { echo "pipeline"; return; }

  local et
  et=$(env_type)
  local v=""
  case "$strat" in
    blue-green|standard) v=$(yq_get ".deployment.${et}.${ENV}.firebase_project") ;;
    single)              v=$(yq_get ".deployment.${et}.server.firebase_project") ;;
  esac
  [[ -z "$v" ]] && v=$(yq_get ".deployment.firebase_project")
  [[ -z "$v" ]] && { echo "ERROR: firebase_project not configured for $ENV (strategy: $strat)" >&2; exit 1; }
  echo "$v"
}

# ── Database secret handlers ──────────────────────────────────────────────────

# Map --db-* flag to the key name inside secret_keys
field_to_db_key() {
  case "$1" in
    db-host)     echo "host" ;;
    db-port)     echo "port" ;;
    db-name)     echo "database" ;;
    db-username) echo "username" ;;
    db-password) echo "password" ;;
    *)           echo "" ;;
  esac
}

# Look up the AWS region for secret fetching (best effort; falls back to AWS CLI default)
secrets_region() {
  local region=""
  # Try to get region from deployment config (suppress errors for strategy=none projects)
  region=$(handle_deploy_region 2>/dev/null || true)
  [[ "$region" == "pipeline" || -z "$region" ]] && region="${AWS_DEFAULT_REGION:-}"
  echo "$region"
}

handle_db_secret() {
  local field="$1"  # e.g. db-host, db-username, db-password

  # Resolve which secret_keys field name we're looking for
  local key_field
  key_field=$(field_to_db_key "$field")
  [[ -z "$key_field" ]] && { echo "ERROR: Unknown DB field: --${field}" >&2; exit 3; }

  # Find the database entry by name — if not explicit, fall back application → primary
  local db_count
  db_count=$(yq ".databases | length" "$PROJECT_FILE" 2>/dev/null || echo "0")
  if [[ "$db_count" == "0" || "$db_count" == "null" ]]; then
    echo "ERROR: No databases configured in $PROJECT_FILE" >&2
    exit 1
  fi

  # Auto-resolve DB name when not explicitly provided
  if [[ "$DB_EXPLICIT" == "false" ]]; then
    local app_exists primary_exists
    app_exists=$(yq ".databases[] | select(.name == \"application\") | .name" "$PROJECT_FILE" 2>/dev/null || true)
    if [[ -z "$app_exists" || "$app_exists" == "null" ]]; then
      primary_exists=$(yq ".databases[] | select(.name == \"primary\") | .name" "$PROJECT_FILE" 2>/dev/null || true)
      if [[ -n "$primary_exists" && "$primary_exists" != "null" ]]; then
        DB="primary"
      fi
    fi
  fi

  # Check if this database is configured
  local db_exists
  db_exists=$(yq ".databases[] | select(.name == \"${DB}\") | .name" "$PROJECT_FILE" 2>/dev/null || true)
  if [[ -z "$db_exists" || "$db_exists" == "null" ]]; then
    echo "ERROR: Database '${DB}' not found in $PROJECT_FILE — available: $(yq '.databases[].name' "$PROJECT_FILE" 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi

  # Get the secret_bucket for this db/user combination
  local bucket
  bucket=$(yq ".databases[] | select(.name == \"${DB}\") | .users.${DB_USER}.secret_bucket" "$PROJECT_FILE" 2>/dev/null || true)
  [[ "$bucket" == "null" ]] && bucket=""

  if [[ -z "$bucket" ]]; then
    echo "ERROR: Database '${DB}' has no secret_bucket configured for user '${DB_USER}' in $PROJECT_FILE — check .databases[name=${DB}].users.${DB_USER}.secret_bucket" >&2
    exit 1
  fi

  # Get the key name constant within the secret (e.g. "DB_APP_PASSWORD")
  local key_name
  key_name=$(yq ".databases[] | select(.name == \"${DB}\") | .users.${DB_USER}.secret_keys.${key_field}" "$PROJECT_FILE" 2>/dev/null || true)
  [[ "$key_name" == "null" ]] && key_name=""

  if [[ -z "$key_name" ]]; then
    echo "ERROR: Database '${DB}' secret key '${key_field}' not configured for user '${DB_USER}' in $PROJECT_FILE — add .databases[name=${DB}].users.${DB_USER}.secret_keys.${key_field}" >&2
    exit 1
  fi

  # Determine secrets backend
  local backend
  backend=$(handle_secrets_backend)

  # Get app name (required for secret path construction)
  local app_name
  app_name=$(yq_get ".name")
  [[ -z "$app_name" ]] && { echo "ERROR: name not set in $PROJECT_FILE — required for secret path construction" >&2; exit 1; }

  # Fetch from backend
  local value=""
  case "$backend" in
    aws)
      command -v aws &>/dev/null || { echo "ERROR: aws CLI not installed — cannot fetch secret from AWS Secrets Manager" >&2; exit 1; }
      command -v jq &>/dev/null  || { echo "ERROR: jq not installed — brew install jq" >&2; exit 1; }

      local secret_path="${app_name}/${ENV}/${bucket}"
      local region
      region=$(secrets_region)
      local region_arg=""
      [[ -n "$region" ]] && region_arg="--region ${region}"

      local secret_json
      # shellcheck disable=SC2086
      secret_json=$(aws secretsmanager get-secret-value \
        --secret-id "${secret_path}" \
        ${region_arg} \
        --query SecretString \
        --output text 2>/dev/null) || {
        echo "ERROR: Secret not found in AWS Secrets Manager: '${secret_path}'${region:+ (region: ${region})} — verify the secret exists for env '${ENV}'" >&2
        exit 1
      }

      value=$(echo "${secret_json}" | jq -r ".${key_name} // empty" 2>/dev/null || true)

      if [[ -z "$value" ]]; then
        echo "ERROR: Key '${key_name}' missing or null in AWS secret '${secret_path}' — verify the key exists in the secret JSON" >&2
        exit 1
      fi
      ;;

    infisical)
      command -v infisical &>/dev/null || { echo "ERROR: infisical CLI not installed — cannot fetch secret" >&2; exit 1; }

      value=$(infisical secrets get "${key_name}" \
        --env="${ENV}" \
        --path="/${bucket}" \
        --plain 2>/dev/null) || {
        echo "ERROR: Secret not found in Infisical: key='${key_name}', path='/${bucket}', env='${ENV}' — verify the secret exists" >&2
        exit 1
      }

      if [[ -z "$value" ]]; then
        echo "ERROR: Key '${key_name}' is empty in Infisical path='/${bucket}' env='${ENV}'" >&2
        exit 1
      fi
      ;;

    *)
      echo "ERROR: Unknown secrets backend: '${backend}' — set secrets.backend to 'aws' or 'infisical' in $PROJECT_FILE" >&2
      exit 1
      ;;
  esac

  echo "$value"
}

# ── Non-deploy field handlers ─────────────────────────────────────────────────

handle_app_name() {
  local v; v=$(yq_get ".name")
  [[ -z "$v" ]] && { echo "ERROR: name not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_secrets_backend() {
  local v; v=$(yq_get ".secrets.backend")
  # PROJECT.yaml wins; otherwise the active profile's environment declares the
  # backend. Never guess from the OS — which secrets manager a team uses is a
  # policy choice, not a kernel capability.
  if [[ -z "$v" ]]; then
    v=$(profile_env_get .secrets.backend 2>/dev/null || true)
    [[ -z "$v" || "$v" == "null" ]] && v="none"
  fi
  echo "$v"
}

handle_test_command() {
  local v; v=$(yq_get ".testing.command")
  [[ -z "$v" ]] && { echo "ERROR: testing.command not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_coverage_command() {
  local v; v=$(yq_get ".testing.coverage_command")
  [[ -z "$v" ]] && { echo "ERROR: testing.coverage_command not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_e2e_command() {
  local v; v=$(yq_get ".testing.e2e_command")
  [[ -z "$v" ]] && { echo "ERROR: testing.e2e_command not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_ci_platform() {
  local v; v=$(yq_get ".ci.platform")
  if [[ -z "$v" ]]; then
    local remote; remote=$(git config --get remote.origin.url 2>/dev/null || echo "")
    [[ "$remote" == *"github.com"* ]] && echo "github" || echo "gitlab"
  else
    echo "$v"
  fi
}

handle_dev_branch() {
  local v; v=$(yq_get ".ci.branches.dev")
  [[ -z "$v" ]] && { echo "ERROR: ci.branches.dev not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_staging_branch() {
  local v; v=$(yq_get ".ci.branches.staging")
  [[ -z "$v" ]] && { echo "ERROR: ci.branches.staging not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_production_branch() {
  local v; v=$(yq_get ".ci.branches.production")
  [[ -z "$v" ]] && { echo "ERROR: ci.branches.production not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_git_repo() {
  local v; v=$(yq_get ".git.repo")
  [[ -z "$v" ]] && { echo "ERROR: git.repo not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_asana_workspace() {
  local v; v=$(yq_get ".task_management.asana.workspace_id")
  [[ -z "$v" ]] && { echo "ERROR: task_management.asana.workspace_id not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_asana_project() {
  local v; v=$(yq_get ".task_management.asana.project_id")
  [[ -z "$v" ]] && { echo "ERROR: task_management.asana.project_id not set in $PROJECT_FILE" >&2; exit 1; }
  echo "$v"
}

handle_docs_dir() {
  local v; v=$(yq_get ".docs_dir")
  [[ -z "$v" ]] && echo "docs" || echo "$v"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$FIELD" in
  deploy-ip)          handle_deploy_ip ;;
  deploy-instance)    handle_deploy_instance ;;
  deploy-method)      handle_deploy_method ;;
  deploy-region)      handle_deploy_region ;;
  deploy-rds-host)    handle_deploy_rds_host ;;
  deploy-containers)  handle_deploy_containers ;;
  deploy-firebase)    handle_deploy_firebase ;;
  db-host|db-port|db-name|db-username|db-password)
                      handle_db_secret "$FIELD" ;;
  app-name)           handle_app_name ;;
  secrets-backend)    handle_secrets_backend ;;
  test-command)       handle_test_command ;;
  coverage-command)   handle_coverage_command ;;
  e2e-command)        handle_e2e_command ;;
  ci-platform)        handle_ci_platform ;;
  dev-branch)         handle_dev_branch ;;
  staging-branch)     handle_staging_branch ;;
  production-branch)  handle_production_branch ;;
  git-repo)           handle_git_repo ;;
  asana-workspace)    handle_asana_workspace ;;
  asana-project)      handle_asana_project ;;
  docs-dir)           handle_docs_dir ;;
  *)
    echo "ERROR: Unknown field: --$FIELD — run $(basename "$0") --help" >&2
    exit 3 ;;
esac
