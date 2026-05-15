#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Secrets audit with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/secrets-audit.sh [--json|--raw] [--category CATEGORY]
#
# Output Modes:
#   --json: Structured JSON scorecard for LLM (default)
#   --raw:  Verbose debugging output
#
# Categories (optional filter):
#   --category env           Only check .env file
#   --category git           Only check git security
#   --category compose       Only check docker-compose
#   --category entrypoints   Only check entrypoint scripts
#   --category project-yaml  Only check PROJECT.yaml
#   --category hardening     Only check container hardening
#   --category ci            Only check CI/CD deployment
#   (no --category flag runs all)

#------------------------------------------------------------------------------
# Config
#------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Source shared library
source "${SCRIPT_DIR}/lib/project-config.sh" 2>/dev/null || true

# Global state
OUTPUT_MODE="json"
CATEGORY_FILTER=""
SECRETS_BACKEND=""
PROJECT_NAME=""

# Scoring severity weights
SEVERITY_CRITICAL=10
SEVERITY_HIGH=5
SEVERITY_MEDIUM=3
SEVERITY_LOW=1

# Accumulators
declare -a VIOLATIONS=()
TOTAL_SCORE=0
declare -A CATEGORY_SCORES=()
declare -A CATEGORY_CHECKS=()
declare -A CATEGORY_VIOLATIONS=()

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

log() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo -e "$@" >&2
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Record a violation
# Usage: violation "category" "severity" "service" "message"
violation() {
    local category="$1" severity="$2" service="$3" message="$4"
    local points=0

    case "$severity" in
        critical) points=$SEVERITY_CRITICAL ;;
        high)     points=$SEVERITY_HIGH ;;
        medium)   points=$SEVERITY_MEDIUM ;;
        low)      points=$SEVERITY_LOW ;;
    esac

    TOTAL_SCORE=$((TOTAL_SCORE + points))
    CATEGORY_SCORES[$category]=$(( ${CATEGORY_SCORES[$category]:-0} + points ))
    CATEGORY_VIOLATIONS[$category]=$(( ${CATEGORY_VIOLATIONS[$category]:-0} + 1 ))

    local escaped_msg
    escaped_msg=$(json_escape "$message")
    VIOLATIONS+=("{\"category\":\"$category\",\"severity\":\"$severity\",\"service\":\"$(json_escape "$service")\",\"message\":\"$escaped_msg\",\"points\":$points}")

    log "  [$severity] ($service) $message (+$points)"
}

# Track checks per category
check_start() {
    local category="$1"
    CATEGORY_CHECKS[$category]=$(( ${CATEGORY_CHECKS[$category]:-0} + 1 ))
}

# Check if category should run
should_run() {
    local category="$1"
    [[ -z "$CATEGORY_FILTER" || "$CATEGORY_FILTER" == "$category" ]]
}

#------------------------------------------------------------------------------
# Flag Parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --category) CATEGORY_FILTER="$2"; shift 2 ;;
        *) break ;;
    esac
done

#------------------------------------------------------------------------------
# Load PROJECT.yaml
#------------------------------------------------------------------------------

load_project_config() {
    if [[ ! -f "${PROJECT_ROOT}/PROJECT.yaml" ]]; then
        SECRETS_BACKEND=""
        PROJECT_NAME=""
        return
    fi

    if type get_project_config &>/dev/null; then
        local config
        config=$(get_project_config \
            name=.name \
            secrets_backend=".secrets.backend" \
            secrets_project_id=".secrets.project_id" \
            2>/dev/null) || true

        if [[ -n "$config" ]]; then
            PROJECT_NAME=$(echo "$config" | jq -r '.name // ""')
            SECRETS_BACKEND=$(echo "$config" | jq -r '.secrets_backend // ""')
            if is_special_value "$PROJECT_NAME"; then PROJECT_NAME=""; fi
            if is_special_value "$SECRETS_BACKEND"; then SECRETS_BACKEND=""; fi
        fi
    fi

    # Fallback: try yq/python
    if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml, sys
with open('PROJECT.yaml') as f:
    d = yaml.safe_load(f)
print(d.get('name', '') or '')
" 2>/dev/null) || true
    fi
    if [[ -z "$SECRETS_BACKEND" ]]; then
        SECRETS_BACKEND=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml, sys
with open('PROJECT.yaml') as f:
    d = yaml.safe_load(f)
s = d.get('secrets', {}) or {}
print(s.get('backend', '') or '')
" 2>/dev/null) || true
    fi
}

# Get required buckets from PROJECT.yaml
get_required_buckets() {
    if [[ ! -f "${PROJECT_ROOT}/PROJECT.yaml" ]]; then
        echo ""
        return
    fi
    cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('PROJECT.yaml') as f:
    d = yaml.safe_load(f)
s = d.get('secrets', {}) or {}
r = s.get('required', []) or []
for b in r:
    print(b)
" 2>/dev/null || true
}

# Get docker services from PROJECT.yaml
get_docker_services() {
    if [[ ! -f "${PROJECT_ROOT}/PROJECT.yaml" ]]; then
        echo ""
        return
    fi
    cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('PROJECT.yaml') as f:
    d = yaml.safe_load(f)
docker = d.get('docker', {}) or {}
services = docker.get('services', []) or []
for s in services:
    print(s)
" 2>/dev/null || true
}

load_project_config

#------------------------------------------------------------------------------
# Category 1: Environment File (.env)
#------------------------------------------------------------------------------

audit_env() {
    should_run "env" || return 0
    log "\n=== Category: Environment File (.env) ==="

    local env_file="${PROJECT_ROOT}/.env"

    # Check .env exists
    check_start "env"
    if [[ ! -f "$env_file" ]]; then
        violation "env" "medium" "project" ".env file not found"
        return
    fi

    # Read non-comment, non-empty lines
    local lines
    lines=$(grep -v '^\s*#' "$env_file" | grep -v '^\s*$' || true)

    # Check for secret-like values
    check_start "env"
    local secret_patterns="PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY|CLIENT_SECRET|DATABASE_URL|MYSQL_ROOT|REDIS_PASSWORD"
    local found_secrets
    found_secrets=$(echo "$lines" | grep -iE "^[^=]*($secret_patterns)" || true)
    if [[ -n "$found_secrets" ]]; then
        while IFS= read -r line; do
            local var_name="${line%%=*}"
            violation "env" "critical" "project" "Secret value in .env: $var_name"
        done <<< "$found_secrets"
    fi

    # Check allowed variables based on backend
    check_start "env"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local var_name="${line%%=*}"
        var_name=$(echo "$var_name" | xargs)  # trim whitespace

        case "$var_name" in
            ENVIRONMENT) ;; # Always allowed
            REGION)
                if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
                    violation "env" "high" "project" "REGION not allowed in .env for Infisical backend (only ENVIRONMENT)"
                fi
                ;;
            SECRETS_PATH)
                ;; # Allowed for production deployments
            *)
                violation "env" "high" "project" "Unauthorized variable in .env: $var_name (only ENVIRONMENT allowed)"
                ;;
        esac
    done <<< "$lines"

    # Check ENVIRONMENT value for Infisical
    check_start "env"
    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        local env_value
        env_value=$(grep '^ENVIRONMENT=' "$env_file" | head -1 | cut -d= -f2 || true)
        case "$env_value" in
            dev|staging|prod) ;; # Valid Infisical slugs
            development)
                violation "env" "medium" "project" "ENVIRONMENT=development should be 'dev' (Infisical slug)"
                ;;
            production)
                violation "env" "medium" "project" "ENVIRONMENT=production should be 'prod' (Infisical slug)"
                ;;
            "")
                violation "env" "medium" "project" "ENVIRONMENT not set in .env"
                ;;
        esac
    fi
}

#------------------------------------------------------------------------------
# Category 2: Git Security
#------------------------------------------------------------------------------

audit_git() {
    should_run "git" || return 0
    log "\n=== Category: Git Security ==="

    # Check .secrets/ in .gitignore
    check_start "git"
    local gitignore="${PROJECT_ROOT}/.gitignore"
    if [[ -f "$gitignore" ]]; then
        if ! grep -q '\.secrets' "$gitignore"; then
            violation "git" "critical" "project" ".secrets/ not listed in .gitignore"
        fi
    else
        violation "git" "critical" "project" ".gitignore file not found"
    fi

    # Check .secrets/ is not tracked by git
    check_start "git"
    local tracked_secrets
    tracked_secrets=$(cd "$PROJECT_ROOT" && git ls-files -- '.secrets/' '.secrets/*' 2>/dev/null || true)
    if [[ -n "$tracked_secrets" ]]; then
        violation "git" "critical" "project" ".secrets/ directory is tracked by git"
    fi

    # Check for .env files with secrets tracked in git
    check_start "git"
    local tracked_env
    tracked_env=$(cd "$PROJECT_ROOT" && git ls-files -- '.env' '.env.*' '!.env.example' '!.env.template' 2>/dev/null || true)
    if [[ -n "$tracked_env" ]]; then
        while IFS= read -r envfile; do
            [[ -z "$envfile" ]] && continue
            local content
            content=$(cd "$PROJECT_ROOT" && git show "HEAD:$envfile" 2>/dev/null || true)
            if echo "$content" | grep -qiE "PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY"; then
                violation "git" "critical" "project" "Tracked file '$envfile' contains secret-like values"
            fi
        done <<< "$tracked_env"
    fi

    # Scan tracked files for hardcoded credentials
    check_start "git"
    local suspect_files
    suspect_files=$(cd "$PROJECT_ROOT" && grep -rlP \
        '(password|secret|api_key|private_key|client_secret)\s*[:=]\s*["\x27][^"\x27]{8,}' \
        --include='*.yml' --include='*.yaml' --include='*.json' --include='*.ts' \
        --include='*.js' --include='*.sh' --include='*.env' \
        . 2>/dev/null | grep -v node_modules | grep -v '.secrets' | grep -v '.git/' || true)
    if [[ -n "$suspect_files" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            # Exclude known safe patterns (schema definitions, test mocks, template vars)
            local real_secrets
            real_secrets=$(grep -nP '(password|secret|api_key|private_key|client_secret)\s*[:=]\s*["\x27][^"\x27]{8,}' "$PROJECT_ROOT/$file" 2>/dev/null \
                | grep -v 'secretPath\|secretName\|secretKey\|readSecret\|getSecret\|get_secret\|SecretValue\|secretValue\|MYSQL_ROOT_PASSWORD_FILE\|infisical_client_secret\|process\.env\|/run/secrets/\|\$\{' \
                | grep -v 'example\|placeholder\|changeme\|TODO\|FIXME\|mock\|test\|fake\|dummy\|sample' \
                || true)
            if [[ -n "$real_secrets" ]]; then
                local basename="${file#./}"
                violation "git" "critical" "project" "Possible hardcoded credential in $basename"
            fi
        done <<< "$suspect_files"
    fi
}

#------------------------------------------------------------------------------
# Category 3: Docker Compose Secrets Configuration
#------------------------------------------------------------------------------

audit_compose() {
    should_run "compose" || return 0
    log "\n=== Category: Docker Compose Secrets ==="

    # Find compose files
    local compose_file="${PROJECT_ROOT}/docker-compose.yml"
    local compose_override="${PROJECT_ROOT}/docker-compose.override.yml"

    check_start "compose"
    if [[ ! -f "$compose_file" ]]; then
        violation "compose" "critical" "project" "docker-compose.yml not found"
        return
    fi

    local compose_content
    compose_content=$(cat "$compose_file")

    # Backend-specific checks
    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        audit_compose_infisical "$compose_file" "$compose_content"
    elif [[ "$SECRETS_BACKEND" == "aws" ]]; then
        audit_compose_aws "$compose_file" "$compose_content"
    fi

    # Universal: check for secrets/credentials in environment sections
    audit_compose_universal "$compose_file" "$compose_content"

    # Also check override file if it exists
    if [[ -f "$compose_override" ]]; then
        local override_content
        override_content=$(cat "$compose_override")
        audit_compose_universal "$compose_override" "$override_content"
    fi
}

audit_compose_infisical() {
    local file="$1" content="$2"

    # Check top-level secrets section exists
    check_start "compose"
    if ! echo "$content" | grep -q '^secrets:'; then
        violation "compose" "critical" "project" "Missing top-level 'secrets:' section in docker-compose.yml"
    fi

    # Check ${SECRETS_PATH:-.secrets}/ pattern
    check_start "compose"
    local required_secrets=("infisical_url" "infisical_client_id" "infisical_client_secret" "infisical_project_id")
    for secret in "${required_secrets[@]}"; do
        if ! echo "$content" | grep -q "\${SECRETS_PATH:-.secrets}/${secret}"; then
            # Also check without the default pattern
            if echo "$content" | grep -q "file:.*${secret}"; then
                violation "compose" "high" "project" "Secret '$secret' missing \${SECRETS_PATH:-.secrets}/ pattern"
            else
                violation "compose" "critical" "project" "Missing secret definition for '$secret' in secrets section"
            fi
        fi
    done

    # Check each service has secrets mounts
    check_start "compose"
    local services
    services=$(get_docker_services)
    if [[ -n "$services" ]]; then
        while IFS= read -r service; do
            [[ -z "$service" ]] && continue

            # Check service has secrets section
            # Use python to parse YAML properly
            local has_secrets
            has_secrets=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('$file') as f:
    d = yaml.safe_load(f)
svcs = d.get('services', {}) or {}
svc = svcs.get('$service', {}) or {}
secrets = svc.get('secrets', []) or []
print(len(secrets))
" 2>/dev/null || echo "0")

            if [[ "$has_secrets" == "0" ]]; then
                violation "compose" "high" "$service" "Service missing 'secrets:' section (should mount all 4 Infisical secrets)"
            else
                # Check all 4 secrets are mounted
                for secret in "${required_secrets[@]}"; do
                    local has_this
                    has_this=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('$file') as f:
    d = yaml.safe_load(f)
svcs = d.get('services', {}) or {}
svc = svcs.get('$service', {}) or {}
secrets = svc.get('secrets', []) or []
print('yes' if '$secret' in secrets else 'no')
" 2>/dev/null || echo "no")
                    if [[ "$has_this" == "no" ]]; then
                        violation "compose" "high" "$service" "Service missing secret mount: $secret"
                    fi
                done
            fi
        done <<< "$services"
    fi

    # Check YAML anchor pattern is NOT used (old pattern)
    check_start "compose"
    if echo "$content" | grep -q 'x-infisical-bootstrap'; then
        violation "compose" "high" "project" "Using deprecated YAML anchor pattern (x-infisical-bootstrap) — use file-based Docker secrets"
    fi
}

audit_compose_aws() {
    local file="$1" content="$2"

    # AWS: should NOT have Infisical secrets section
    check_start "compose"
    if echo "$content" | grep -q 'infisical_url\|infisical_client'; then
        violation "compose" "high" "project" "AWS backend should not have Infisical secrets configuration"
    fi

    # AWS: check REGION is in environment
    check_start "compose"
    local services
    services=$(get_docker_services)
    if [[ -n "$services" ]]; then
        while IFS= read -r service; do
            [[ -z "$service" ]] && continue
            local has_region
            has_region=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('$file') as f:
    d = yaml.safe_load(f)
svcs = d.get('services', {}) or {}
svc = svcs.get('$service', {}) or {}
env = svc.get('environment', {}) or {}
# Check for REGION in environment
has = any('REGION' in str(k) for k in (env if isinstance(env, dict) else []))
print('yes' if has else 'no')
" 2>/dev/null || echo "no")
            # REGION is expected for AWS services
        done <<< "$services"
    fi
}

audit_compose_universal() {
    local file="$1" content="$2"
    local basename="${file##*/}"
    local is_override=false
    [[ "$basename" == *"override"* ]] && is_override=true

    # Check for credentials in environment sections
    check_start "compose"
    local services
    services=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('$file') as f:
    d = yaml.safe_load(f)
svcs = d.get('services', {}) or {}
for name in svcs:
    print(name)
" 2>/dev/null || true)

    if [[ -n "$services" ]]; then
        while IFS= read -r service; do
            [[ -z "$service" ]] && continue

            # Get environment variables for this service
            local env_vars
            env_vars=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('$file') as f:
    d = yaml.safe_load(f)
svcs = d.get('services', {}) or {}
svc = svcs.get('$service', {}) or {}
env = svc.get('environment', {}) or {}
if isinstance(env, dict):
    for k, v in env.items():
        print(f'{k}={v}')
elif isinstance(env, list):
    for item in env:
        print(item)
" 2>/dev/null || true)

            if [[ -n "$env_vars" ]]; then
                while IFS= read -r var; do
                    [[ -z "$var" ]] && continue
                    local var_name="${var%%=*}"
                    local var_value="${var#*=}"

                    # Check for secret-like env vars (exclude allowed patterns)
                    case "$var_name" in
                        ENVIRONMENT|REGION|NODE_ENV|MYSQL_DATABASE|MYSQL_ROOT_PASSWORD_FILE) continue ;;
                    esac

                    # Check for actual credential values (not variable references)
                    if echo "$var_name" | grep -qiE "PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY|CLIENT_SECRET|DATABASE_URL|REDIS_PASSWORD"; then
                        # Allow if the value is a variable reference like ${VAR}
                        if [[ "$var_value" != *'${'* ]]; then
                            violation "compose" "critical" "$service" "Secret in environment ($basename): $var_name"
                        fi
                    fi

                    # Check for Infisical bootstrap as env vars (old pattern)
                    if echo "$var_name" | grep -qiE "^INFISICAL_"; then
                        violation "compose" "high" "$service" "Infisical bootstrap as env var ($basename): $var_name — should be Docker secret file"
                    fi
                done <<< "$env_vars"
            fi

            # Check for ENVIRONMENT var exists in service
            check_start "compose"
            local has_env
            has_env=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml
with open('$file') as f:
    d = yaml.safe_load(f)
svcs = d.get('services', {}) or {}
svc = svcs.get('$service', {}) or {}
env = svc.get('environment', {}) or {}
if isinstance(env, dict):
    print('yes' if 'ENVIRONMENT' in env else 'no')
elif isinstance(env, list):
    print('yes' if any('ENVIRONMENT' in str(e) for e in env) else 'no')
else:
    print('no')
" 2>/dev/null || echo "no")

            # Only check for app services in the main compose file (not overrides)
            if [[ "$has_env" == "no" && "$is_override" == false ]]; then
                # Check if this is an app service (not a pure infra service without entrypoints)
                local is_app_service=false
                case "$service" in
                    backend|frontend|api|web|app|worker) is_app_service=true ;;
                esac
                if [[ "$is_app_service" == true ]]; then
                    violation "compose" "medium" "$service" "Service missing ENVIRONMENT variable ($basename)"
                fi
            fi
        done <<< "$services"
    fi
}

#------------------------------------------------------------------------------
# Category 4: Entrypoint Scripts
#------------------------------------------------------------------------------

audit_entrypoints() {
    should_run "entrypoints" || return 0
    log "\n=== Category: Entrypoint Scripts ==="

    # Find shell entrypoints
    local entrypoints
    entrypoints=$(find "$PROJECT_ROOT" -maxdepth 3 -name 'entrypoint*.sh' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null || true)

    if [[ -n "$entrypoints" ]]; then
        while IFS= read -r ep; do
            [[ -z "$ep" ]] && continue
            local basename="${ep#$PROJECT_ROOT/}"
            local content
            content=$(cat "$ep")

            if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
                # Should read from /run/secrets/ files
                check_start "entrypoints"
                if ! echo "$content" | grep -q '/run/secrets/'; then
                    violation "entrypoints" "high" "$basename" "Entrypoint does not read from /run/secrets/ files"
                fi

                # Should NOT use env vars for bootstrap
                check_start "entrypoints"
                if echo "$content" | grep -qE '\$\{?INFISICAL_(URL|CLIENT_ID|CLIENT_SECRET|PROJECT_ID)\}?' | grep -v 'cat /run/secrets/'; then
                    # More nuanced: check if they're reading from env vs files
                    if echo "$content" | grep -qE '^\s*INFISICAL_.*=\$\{?INFISICAL_' ; then
                        violation "entrypoints" "high" "$basename" "Reading Infisical bootstrap from env vars instead of /run/secrets/ files"
                    fi
                fi
            fi

            # Universal: fail-fast check
            check_start "entrypoints"
            if echo "$content" | grep -q 'get_secret\|getSecret\|fetch_secret'; then
                if ! echo "$content" | grep -qE 'exit 1|FATAL|die '; then
                    violation "entrypoints" "medium" "$basename" "Fetches secrets but has no fail-fast error handling"
                fi
            fi

            # Universal: no hardcoded credentials
            check_start "entrypoints"
            local hardcoded
            hardcoded=$(echo "$content" | grep -nP '(password|secret|api_key)\s*=\s*["\x27][^"\x27$]{8,}' \
                | grep -vi 'example\|placeholder\|changeme\|TODO\|mock\|test\|fake\|dummy\|template\|get_secret\|getSecret\|readSecret' || true)
            if [[ -n "$hardcoded" ]]; then
                violation "entrypoints" "critical" "$basename" "Possible hardcoded credential in entrypoint"
            fi

            # Universal: no export of secrets to environment
            check_start "entrypoints"
            # This is actually OK in frontend entrypoints that export NEXT_PUBLIC_* etc.
            # Only flag if exporting raw secret values
            if echo "$content" | grep -qE 'export\s+(DATABASE_URL|DB_PASSWORD|JWT_SECRET|API_KEY|CLIENT_SECRET)='; then
                violation "entrypoints" "medium" "$basename" "Exports secret values to environment (hold in memory or pass directly)"
            fi

        done <<< "$entrypoints"
    fi

    # Check database init scripts
    local init_scripts
    init_scripts=$(find "$PROJECT_ROOT" -path '*/init/*' -name '*.sh' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null || true)

    if [[ -n "$init_scripts" ]]; then
        while IFS= read -r script; do
            [[ -z "$script" ]] && continue
            local basename="${script#$PROJECT_ROOT/}"
            local content
            content=$(cat "$script")

            if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
                # DB init should read from /run/secrets/
                check_start "entrypoints"
                if ! echo "$content" | grep -q '/run/secrets/'; then
                    violation "entrypoints" "high" "$basename" "DB init script does not read from /run/secrets/ files"
                fi

                # Should authenticate with Infisical
                check_start "entrypoints"
                if ! echo "$content" | grep -q 'auth/universal-auth/login\|infisical'; then
                    violation "entrypoints" "high" "$basename" "DB init script does not authenticate with Infisical"
                fi
            fi

            # No hardcoded SQL credentials
            check_start "entrypoints"
            local hardcoded_sql
            hardcoded_sql=$(echo "$content" | grep -nE "CREATE USER.*IDENTIFIED BY\s*'[^'\$]+" || true)
            if [[ -n "$hardcoded_sql" ]]; then
                violation "entrypoints" "critical" "$basename" "Hardcoded credentials in SQL user creation"
            fi

        done <<< "$init_scripts"
    fi

    # Check SQL init scripts (should not exist for Infisical - use .sh instead)
    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        local sql_init
        sql_init=$(find "$PROJECT_ROOT" -path '*/init/*' -name '*.sql' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null || true)
        if [[ -n "$sql_init" ]]; then
            while IFS= read -r sqlfile; do
                [[ -z "$sqlfile" ]] && continue
                local basename="${sqlfile#$PROJECT_ROOT/}"
                local content
                content=$(cat "$sqlfile")
                # Check for hardcoded credentials in SQL
                check_start "entrypoints"
                if echo "$content" | grep -qiE "IDENTIFIED BY\s*'[^'\$]+'" ; then
                    violation "entrypoints" "critical" "$basename" "SQL init file with hardcoded credentials — use shell script to fetch from Infisical"
                fi
            done <<< "$sql_init"
        fi
    fi

    # Check backend application code for secrets reading pattern
    local config_files
    config_files=$(find "$PROJECT_ROOT" -maxdepth 5 \
        \( -name 'config.service.ts' -o -name 'config.service.js' -o -name 'config.py' -o -name 'settings.py' \) \
        -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null || true)

    if [[ -n "$config_files" ]]; then
        while IFS= read -r cf; do
            [[ -z "$cf" ]] && continue
            local basename="${cf#$PROJECT_ROOT/}"
            local content
            content=$(cat "$cf")

            if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
                # Should read from /run/secrets/
                check_start "entrypoints"
                if echo "$content" | grep -q 'infisical\|InfisicalSDK\|InfisicalClient'; then
                    if ! echo "$content" | grep -q '/run/secrets/\|readSecret'; then
                        violation "entrypoints" "high" "$basename" "Uses Infisical SDK but does not read bootstrap from /run/secrets/"
                    fi
                fi
            fi

            # No hardcoded connection strings
            check_start "entrypoints"
            if echo "$content" | grep -qE "(mysql|postgres|mongodb|redis)://[^$\"\s]+:[^$\"\s]+@"; then
                violation "entrypoints" "critical" "$basename" "Hardcoded database connection string"
            fi
        done <<< "$config_files"
    fi
}

#------------------------------------------------------------------------------
# Category 5: PROJECT.yaml Configuration
#------------------------------------------------------------------------------

audit_project_yaml() {
    should_run "project-yaml" || return 0
    log "\n=== Category: PROJECT.yaml ==="

    local yaml_file="${PROJECT_ROOT}/PROJECT.yaml"

    check_start "project-yaml"
    if [[ ! -f "$yaml_file" ]]; then
        violation "project-yaml" "high" "project" "PROJECT.yaml not found"
        return
    fi

    # Parse secrets section
    local secrets_config
    secrets_config=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml, json
with open('PROJECT.yaml') as f:
    d = yaml.safe_load(f)
s = d.get('secrets', {}) or {}
print(json.dumps({
    'has_secrets': bool(s),
    'backend': s.get('backend', ''),
    'project_id': s.get('project_id', ''),
    'required': s.get('required', []) or [],
}))
" 2>/dev/null || echo '{"has_secrets":false}')

    # Check secrets section exists
    check_start "project-yaml"
    local has_secrets
    has_secrets=$(echo "$secrets_config" | jq -r '.has_secrets')
    if [[ "$has_secrets" != "true" ]]; then
        violation "project-yaml" "high" "project" "Missing 'secrets:' section in PROJECT.yaml"
        return
    fi

    # Check backend is set
    check_start "project-yaml"
    local backend
    backend=$(echo "$secrets_config" | jq -r '.backend // ""')
    if [[ -z "$backend" ]]; then
        violation "project-yaml" "high" "project" "Missing 'secrets.backend' in PROJECT.yaml"
    elif [[ "$backend" != "infisical" && "$backend" != "aws" ]]; then
        violation "project-yaml" "medium" "project" "Invalid secrets.backend '$backend' — must be 'infisical' or 'aws'"
    fi

    # Check project_id for Infisical
    check_start "project-yaml"
    if [[ "$backend" == "infisical" ]]; then
        local project_id
        project_id=$(echo "$secrets_config" | jq -r '.project_id // ""')
        if [[ -z "$project_id" ]]; then
            violation "project-yaml" "high" "project" "Missing 'secrets.project_id' for Infisical backend"
        fi
    fi

    # Check required buckets
    check_start "project-yaml"
    local required_count
    required_count=$(echo "$secrets_config" | jq -r '.required | length')
    if [[ "$required_count" == "0" ]]; then
        violation "project-yaml" "medium" "project" "No required secret buckets listed in secrets.required"
    fi

    # Cross-check: required buckets should match what services actually use
    # (This is informational — hard to fully automate)
}

#------------------------------------------------------------------------------
# Category 6: Container Hardening
#------------------------------------------------------------------------------

audit_hardening() {
    should_run "hardening" || return 0
    log "\n=== Category: Container Hardening ==="

    local compose_file="${PROJECT_ROOT}/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        return
    fi

    local services
    services=$(get_docker_services)
    [[ -z "$services" ]] && return

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        local svc_config
        svc_config=$(cd "$PROJECT_ROOT" && python3 -c "
import yaml, json
with open('docker-compose.yml') as f:
    d = yaml.safe_load(f)
svcs = d.get('services', {}) or {}
svc = svcs.get('$service', {}) or {}
print(json.dumps({
    'has_user': 'user' in svc,
    'read_only': svc.get('read_only', False),
    'has_cap_drop': 'cap_drop' in svc,
    'cap_drop_all': 'ALL' in (svc.get('cap_drop', []) or []),
    'has_security_opt': 'security_opt' in svc,
    'no_new_privs': 'no-new-privileges:true' in (svc.get('security_opt', []) or []),
    'has_deploy': 'deploy' in svc,
    'has_resource_limits': bool((svc.get('deploy', {}) or {}).get('resources', {}) or {}),
    'privileged': svc.get('privileged', False),
}))
" 2>/dev/null || echo '{}')

        [[ "$svc_config" == "{}" ]] && continue

        # Skip database services for some checks (they need write access)
        local is_db=false
        case "$service" in
            mysql|postgres|postgresql|mariadb|mongo|mongodb|redis) is_db=true ;;
        esac

        # Non-root user
        check_start "hardening"
        local has_user
        has_user=$(echo "$svc_config" | jq -r '.has_user')
        if [[ "$has_user" != "true" && "$is_db" == "false" ]]; then
            violation "hardening" "medium" "$service" "Not running as non-root user (missing 'user:' setting)"
        fi

        # Read-only filesystem
        check_start "hardening"
        local read_only
        read_only=$(echo "$svc_config" | jq -r '.read_only')
        if [[ "$read_only" != "true" && "$is_db" == "false" ]]; then
            violation "hardening" "low" "$service" "Filesystem not read-only (missing 'read_only: true')"
        fi

        # Drop capabilities
        check_start "hardening"
        local cap_drop_all
        cap_drop_all=$(echo "$svc_config" | jq -r '.cap_drop_all')
        if [[ "$cap_drop_all" != "true" && "$is_db" == "false" ]]; then
            violation "hardening" "medium" "$service" "Not dropping all capabilities (missing 'cap_drop: [ALL]')"
        fi

        # no-new-privileges
        check_start "hardening"
        local no_new_privs
        no_new_privs=$(echo "$svc_config" | jq -r '.no_new_privs')
        if [[ "$no_new_privs" != "true" && "$is_db" == "false" ]]; then
            violation "hardening" "low" "$service" "Missing 'no-new-privileges:true' security option"
        fi

        # Resource limits
        check_start "hardening"
        local has_limits
        has_limits=$(echo "$svc_config" | jq -r '.has_resource_limits')
        if [[ "$has_limits" != "true" ]]; then
            violation "hardening" "low" "$service" "No resource limits set (missing deploy.resources.limits)"
        fi

        # Privileged mode
        check_start "hardening"
        local privileged
        privileged=$(echo "$svc_config" | jq -r '.privileged')
        if [[ "$privileged" == "true" ]]; then
            violation "hardening" "critical" "$service" "Running in privileged mode"
        fi

    done <<< "$services"
}

#------------------------------------------------------------------------------
# Category 7: CI/CD Deployment
#------------------------------------------------------------------------------

audit_ci() {
    should_run "ci" || return 0
    log "\n=== Category: CI/CD Deployment ==="

    # Detect CI platform
    local ci_platform=""
    if [[ -f "${PROJECT_ROOT}/.gitlab-ci.yml" ]]; then
        ci_platform="gitlab"
    elif [[ -d "${PROJECT_ROOT}/.github/workflows" ]]; then
        ci_platform="github"
    fi

    if [[ -z "$ci_platform" ]]; then
        check_start "ci"
        # Not necessarily a violation — project may not have CI yet
        log "  No CI configuration found (skipping)"
        return
    fi

    if [[ "$ci_platform" == "gitlab" && "$SECRETS_BACKEND" == "infisical" ]]; then
        local ci_content
        ci_content=$(cat "${PROJECT_ROOT}/.gitlab-ci.yml")

        # Check deploy job writes .secrets/ files
        check_start "ci"
        if echo "$ci_content" | grep -q 'deploy'; then
            if ! echo "$ci_content" | grep -q '\.secrets/infisical_url\|\.secrets\/infisical_url'; then
                violation "ci" "high" "deploy" "Deploy job does not write .secrets/infisical_url on remote host"
            fi

            # Check all 4 bootstrap files are written
            check_start "ci"
            local missing_writes=()
            for secret in infisical_url infisical_client_id infisical_client_secret infisical_project_id; do
                if ! echo "$ci_content" | grep -q "$secret"; then
                    missing_writes+=("$secret")
                fi
            done
            if [[ ${#missing_writes[@]} -gt 0 ]]; then
                for missing in "${missing_writes[@]}"; do
                    violation "ci" "high" "deploy" "Deploy job missing bootstrap file write: $missing"
                done
            fi

            # Check SECRETS_PATH is set in deploy
            check_start "ci"
            if ! echo "$ci_content" | grep -q 'SECRETS_PATH'; then
                violation "ci" "medium" "deploy" "Deploy job does not set SECRETS_PATH in .env"
            fi

            # Check for hardcoded credentials in CI file
            check_start "ci"
            if echo "$ci_content" | grep -qE "(password|secret|token)\s*:\s*['\"][^'\"\$]+['\"]" | grep -v 'INFISICAL\|CI_'; then
                violation "ci" "critical" "deploy" "Possible hardcoded credentials in CI config"
            fi
        fi
    fi

    if [[ "$ci_platform" == "github" && "$SECRETS_BACKEND" == "aws" ]]; then
        # Check GitHub Actions for AWS patterns
        local workflow_files
        workflow_files=$(find "${PROJECT_ROOT}/.github/workflows" -name '*.yml' -o -name '*.yaml' 2>/dev/null || true)

        if [[ -n "$workflow_files" ]]; then
            while IFS= read -r wf; do
                [[ -z "$wf" ]] && continue
                local content
                content=$(cat "$wf")
                local basename="${wf#$PROJECT_ROOT/}"

                # Should use OIDC or IAM roles, not hardcoded keys
                check_start "ci"
                if echo "$content" | grep -qE "AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY" | grep -v '\$\{\{'; then
                    violation "ci" "critical" "$basename" "Hardcoded AWS credentials — use OIDC or IAM roles"
                fi
            done <<< "$workflow_files"
        fi
    fi
}

#------------------------------------------------------------------------------
# Run All Audits
#------------------------------------------------------------------------------

log "Secrets Audit: ${PROJECT_ROOT}"
log "Backend: ${SECRETS_BACKEND:-unknown}"
log "Project: ${PROJECT_NAME:-unknown}"

audit_env
audit_git
audit_compose
audit_entrypoints
audit_project_yaml
audit_hardening
audit_ci

#------------------------------------------------------------------------------
# Generate Output
#------------------------------------------------------------------------------

# Build category scorecard
build_categories_json() {
    local categories=("env" "git" "compose" "entrypoints" "project-yaml" "hardening" "ci")
    local first=true
    echo "["
    for cat in "${categories[@]}"; do
        if ! should_run "$cat"; then continue; fi
        local score=${CATEGORY_SCORES[$cat]:-0}
        local checks=${CATEGORY_CHECKS[$cat]:-0}
        local violations=${CATEGORY_VIOLATIONS[$cat]:-0}
        local grade="A"
        if [[ $score -ge 20 ]]; then grade="F"
        elif [[ $score -ge 15 ]]; then grade="D"
        elif [[ $score -ge 10 ]]; then grade="C"
        elif [[ $score -ge 5 ]]; then grade="B"
        elif [[ $score -gt 0 ]]; then grade="B"
        fi

        if [[ "$first" == true ]]; then first=false; else echo ","; fi
        printf '    {"category":"%s","checks":%d,"violations":%d,"score":%d,"grade":"%s"}' \
            "$cat" "$checks" "$violations" "$score" "$grade"
    done
    echo ""
    echo "  ]"
}

# Build violations JSON array
build_violations_json() {
    echo "["
    local first=true
    for v in "${VIOLATIONS[@]}"; do
        if [[ "$first" == true ]]; then first=false; else echo ","; fi
        printf '    %s' "$v"
    done
    echo ""
    echo "  ]"
}

# Overall grade
overall_grade() {
    if [[ $TOTAL_SCORE -eq 0 ]]; then echo "PERFECT"
    elif [[ $TOTAL_SCORE -le 5 ]]; then echo "A"
    elif [[ $TOTAL_SCORE -le 15 ]]; then echo "B"
    elif [[ $TOTAL_SCORE -le 30 ]]; then echo "C"
    elif [[ $TOTAL_SCORE -le 50 ]]; then echo "D"
    else echo "F"
    fi
}

VIOLATION_COUNT=${#VIOLATIONS[@]}
GRADE=$(overall_grade)

if [[ "$OUTPUT_MODE" == "json" ]]; then
    cat <<EOF
{
  "status": "success",
  "next_action": "display_scorecard",
  "project_name": "$(json_escape "${PROJECT_NAME:-unknown}")",
  "secrets_backend": "$(json_escape "${SECRETS_BACKEND:-unknown}")",
  "total_score": $TOTAL_SCORE,
  "total_violations": $VIOLATION_COUNT,
  "grade": "$GRADE",
  "scoring": {
    "critical": $SEVERITY_CRITICAL,
    "high": $SEVERITY_HIGH,
    "medium": $SEVERITY_MEDIUM,
    "low": $SEVERITY_LOW
  },
  "categories": $(build_categories_json),
  "violations": $(build_violations_json),
  "timestamp": "$(date -Iseconds)"
}
EOF
else
    echo "" >&2
    echo "========================================" >&2
    echo " SECRETS AUDIT SCORECARD" >&2
    echo "========================================" >&2
    echo " Project:    ${PROJECT_NAME:-unknown}" >&2
    echo " Backend:    ${SECRETS_BACKEND:-unknown}" >&2
    echo " Score:      ${TOTAL_SCORE} (lower is better)" >&2
    echo " Grade:      ${GRADE}" >&2
    echo " Violations: ${VIOLATION_COUNT}" >&2
    echo "========================================" >&2

    if [[ $VIOLATION_COUNT -gt 0 ]]; then
        echo "" >&2
        echo "Violations:" >&2
        for v in "${VIOLATIONS[@]}"; do
            local sev cat svc msg pts
            sev=$(echo "$v" | jq -r '.severity')
            cat=$(echo "$v" | jq -r '.category')
            svc=$(echo "$v" | jq -r '.service')
            msg=$(echo "$v" | jq -r '.message')
            pts=$(echo "$v" | jq -r '.points')
            echo "  [${sev^^}] (${cat}/${svc}) ${msg} (+${pts})" >&2
        done
    fi

    echo "" >&2
    if [[ $TOTAL_SCORE -eq 0 ]]; then
        echo "✓ Perfect score — no violations found!" >&2
    fi
fi
