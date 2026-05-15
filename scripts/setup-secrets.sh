#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/setup-secrets.sh [--json|--raw] [--full|--section] [options]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output
#
# Section Flags:
#   --validate:       Check existing setup
#   --create-project: Create Infisical project (home only)
#   --create-folders: Create folders/buckets in secrets manager
#   --populate:       Check secret population status
#   --local-setup:    Create .secrets/ directory (home) or verify IAM (work)
#   --verify:         Verify docker-compose + connectivity
#   --full:           Run all sections end-to-end (default)

#------------------------------------------------------------------------------
# Config
#------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Source shared library
source "${SCRIPT_DIR}/lib/project-config.sh" 2>/dev/null || true

# Global state
OUTPUT_MODE="json"
SECTION="full"
INFISICAL_DIR="${HOME}/.infisical"
SECRETS_BACKEND=""
PROJECT_NAME=""
PROJECT_ID=""
TOKEN=""
INFISICAL_URL=""
CLIENT_ID=""
CLIENT_SECRET=""
ORG_ID=""
AWS_REGION=""

# Required buckets from PROJECT.yaml (populated by load_project_config)
declare -a REQUIRED_BUCKETS=()

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)  echo "display_summary" ;;
        warning)  echo "fix_compose" ;;
        *)        echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Wrapper to include backend/project context in all exit_with_json calls
_exit_with_context() {
    local status="$1"
    local message="$2"
    local details="${3:-}"
    shift 3
    local extra="${1:-}"

    local context="\"backend\": $(echo "$SECRETS_BACKEND" | jq -Rs .), \"project_name\": $(echo "$PROJECT_NAME" | jq -Rs .), \"project_id\": $(echo "$PROJECT_ID" | jq -Rs .)"
    if [[ -n "$extra" ]]; then
        context="${context}, ${extra}"
    fi

    exit_with_json "$status" "$message" "$details" "$context"
}

#------------------------------------------------------------------------------
# Flag Parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --validate) SECTION="validate"; shift ;;
        --create-project) SECTION="create-project"; shift ;;
        --create-folders) SECTION="create-folders"; shift ;;
        --populate) SECTION="populate"; shift ;;
        --local-setup) SECTION="local-setup"; shift ;;
        --verify) SECTION="verify"; shift ;;
        *) break ;;
    esac
done

#------------------------------------------------------------------------------
# Load PROJECT.yaml (using shared library)
#------------------------------------------------------------------------------

load_project_config() {
    if [[ ! -f "${PROJECT_ROOT}/PROJECT.yaml" ]]; then
        _exit_with_context "error" "PROJECT.yaml not found. Run /project-config init first."
    fi

    local config
    config=$(get_project_config \
        name=.name \
        backend=.secrets.backend \
        project_id=.secrets.project_id \
        region=.deployment.region)

    PROJECT_NAME=$(echo "$config" | jq -r '.name')
    SECRETS_BACKEND=$(echo "$config" | jq -r '.backend')
    PROJECT_ID=$(echo "$config" | jq -r '.project_id')
    AWS_REGION=$(echo "$config" | jq -r '.region')

    # Fix special values
    [[ "$PROJECT_NAME" == "__MISSING__" || "$PROJECT_NAME" == "__INVALID__" || "$PROJECT_NAME" == "__BLANK__" ]] && \
        _exit_with_context "error" "PROJECT.yaml missing 'name' field."

    # Auto-detect backend
    if [[ "$SECRETS_BACKEND" == "__MISSING__" || "$SECRETS_BACKEND" == "__INVALID__" || "$SECRETS_BACKEND" == "__BLANK__" ]]; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            SECRETS_BACKEND="aws"
        else
            SECRETS_BACKEND="infisical"
        fi
    fi

    # Fix project_id
    [[ "$PROJECT_ID" == "__MISSING__" || "$PROJECT_ID" == "__INVALID__" || "$PROJECT_ID" == "__BLANK__" ]] && PROJECT_ID=""

    # Fix region
    [[ "$AWS_REGION" == "__MISSING__" || "$AWS_REGION" == "__INVALID__" || "$AWS_REGION" == "__BLANK__" ]] && AWS_REGION="us-east-1"

    # Load required buckets (yq outputs JSON array, pipe through jq)
    local buckets_raw
    buckets_raw=$(cd "$PROJECT_ROOT" && yq '.secrets.required' PROJECT.yaml 2>/dev/null || echo "null")
    if [[ "$buckets_raw" != "null" && -n "$buckets_raw" ]]; then
        while IFS= read -r bucket; do
            [[ -n "$bucket" && "$bucket" != "null" ]] && REQUIRED_BUCKETS+=("$bucket")
        done < <(echo "$buckets_raw" | jq -r '.[]' 2>/dev/null || echo "$buckets_raw" | sed 's/^- //' | tr -d '"' | tr -d ' ')
    fi

    log "Project: ${PROJECT_NAME}, Backend: ${SECRETS_BACKEND}, Project ID: ${PROJECT_ID:-not set}"
    log "Required buckets: ${REQUIRED_BUCKETS[*]:-none}"
}

#------------------------------------------------------------------------------
# Backend: Infisical Authentication
#------------------------------------------------------------------------------

authenticate_infisical() {
    if [[ ! -d "$INFISICAL_DIR" ]]; then
        _exit_with_context "error" "Infisical credentials directory not found at ${INFISICAL_DIR}"
    fi

    INFISICAL_URL=$(jq -r '.domains[0] // ""' "${INFISICAL_DIR}/infisical-config.json" 2>/dev/null || echo "")
    CLIENT_ID=$(cat "${INFISICAL_DIR}/client-id" 2>/dev/null | tr -d '\n' || echo "")
    CLIENT_SECRET=$(cat "${INFISICAL_DIR}/client-secret" 2>/dev/null | tr -d '\n' || echo "")

    if [[ -z "$INFISICAL_URL" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
        _exit_with_context "error" "Missing Infisical credentials in ${INFISICAL_DIR}. Need: infisical-config.json, client-id, client-secret"
    fi

    log "Authenticating with Infisical at ${INFISICAL_URL}..."

    local response
    response=$(curl -sf -X POST "${INFISICAL_URL}/api/v1/auth/universal-auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"clientId\":\"${CLIENT_ID}\",\"clientSecret\":\"${CLIENT_SECRET}\"}" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        _exit_with_context "error" "Failed to connect to Infisical at ${INFISICAL_URL}"
    fi

    TOKEN=$(echo "$response" | jq -r '.accessToken // ""' 2>/dev/null || echo "")

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        _exit_with_context "error" "Failed to authenticate with Infisical. Check credentials in ${INFISICAL_DIR}"
    fi

    log "Authenticated successfully"
}

#------------------------------------------------------------------------------
# Backend: AWS Authentication
#------------------------------------------------------------------------------

authenticate_aws() {
    if ! command -v aws &>/dev/null; then
        _exit_with_context "error" "AWS CLI not installed. Install: brew install awscli"
    fi

    local identity
    identity=$(aws sts get-caller-identity --region "${AWS_REGION}" 2>/dev/null || echo "")

    if [[ -z "$identity" ]]; then
        _exit_with_context "error" "AWS authentication failed. Check IAM credentials or SSO login."
    fi

    local account
    account=$(echo "$identity" | jq -r '.Account // ""')
    log "Authenticated with AWS account: ${account}"
}

#------------------------------------------------------------------------------
# Authenticate (dispatches to backend)
#------------------------------------------------------------------------------

authenticate() {
    case "$SECRETS_BACKEND" in
        infisical) authenticate_infisical ;;
        aws) authenticate_aws ;;
        *) _exit_with_context "error" "Unknown secrets backend: ${SECRETS_BACKEND}" ;;
    esac
}

#------------------------------------------------------------------------------
# Section: Validate
#------------------------------------------------------------------------------

run_validate() {
    log "=== Validating secrets setup ==="

    local issues=()
    local checks_passed=0
    local checks_total=0

    # Check PROJECT.yaml project_id
    checks_total=$((checks_total + 1))
    if [[ -n "$PROJECT_ID" ]]; then
        checks_passed=$((checks_passed + 1))
        log "  ✓ PROJECT.yaml has project_id: ${PROJECT_ID}"
    else
        issues+=("\"PROJECT.yaml missing secrets.project_id\"")
        log "  ✗ PROJECT.yaml missing secrets.project_id"
    fi

    # Check required buckets
    checks_total=$((checks_total + 1))
    if [[ ${#REQUIRED_BUCKETS[@]} -gt 0 ]]; then
        checks_passed=$((checks_passed + 1))
        log "  ✓ Required buckets: ${REQUIRED_BUCKETS[*]}"
    else
        issues+=("\"PROJECT.yaml missing secrets.required list\"")
        log "  ✗ No required buckets defined"
    fi

    # Backend-specific checks
    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        # Check .secrets/ directory
        checks_total=$((checks_total + 1))
        if [[ -d "${PROJECT_ROOT}/.secrets" ]]; then
            local secret_files
            secret_files=$(ls -1 "${PROJECT_ROOT}/.secrets/" 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$secret_files" -ge 4 ]]; then
                checks_passed=$((checks_passed + 1))
                log "  ✓ .secrets/ directory: ${secret_files} files"
            else
                issues+=("\"'.secrets/' has ${secret_files} files (need >= 4: infisical_url, client_id, client_secret, project_id)\"")
            fi
        else
            issues+=("\"'.secrets/' directory not found\"")
        fi

        # Check .gitignore
        checks_total=$((checks_total + 1))
        if grep -q '\.secrets' "${PROJECT_ROOT}/.gitignore" 2>/dev/null; then
            checks_passed=$((checks_passed + 1))
            log "  ✓ .gitignore includes .secrets/"
        else
            issues+=("\".gitignore missing .secrets/ entry\"")
        fi

        # Check docker-compose uses file-based secrets
        checks_total=$((checks_total + 1))
        if [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
            if grep -q 'SECRETS_PATH:-.secrets' "${PROJECT_ROOT}/docker-compose.yml" 2>/dev/null; then
                checks_passed=$((checks_passed + 1))
                log "  ✓ docker-compose.yml uses SECRETS_PATH pattern"
            else
                issues+=("\"docker-compose.yml not using \${SECRETS_PATH:-.secrets} pattern\"")
            fi
        fi

        # Check for env var bootstrap anti-pattern
        checks_total=$((checks_total + 1))
        if [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]] && grep -q 'x-infisical-bootstrap' "${PROJECT_ROOT}/docker-compose.yml" 2>/dev/null; then
            issues+=("\"docker-compose.yml uses YAML anchor env vars for bootstrap — should use Docker secret files\"")
        else
            checks_passed=$((checks_passed + 1))
            log "  ✓ No env var bootstrap anti-pattern"
        fi

        # Check Infisical folders exist
        if [[ -n "$PROJECT_ID" && -n "$TOKEN" ]]; then
            for bucket in "${REQUIRED_BUCKETS[@]}"; do
                checks_total=$((checks_total + 1))
                local folder_check
                folder_check=$(curl -sf "${INFISICAL_URL}/api/v1/folders?workspaceId=${PROJECT_ID}&environment=dev&path=/" \
                    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
                local has_folder
                has_folder=$(echo "$folder_check" | jq -r ".folders[] | select(.name == \"${bucket}\") | .name" 2>/dev/null || echo "")
                if [[ -n "$has_folder" ]]; then
                    local sec_resp
                    sec_resp=$(curl -sf "${INFISICAL_URL}/api/v3/secrets/raw?workspaceId=${PROJECT_ID}&environment=dev&secretPath=/${bucket}" \
                        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
                    local sc
                    sc=$(echo "$sec_resp" | jq '.secrets | length' 2>/dev/null || echo "0")
                    checks_passed=$((checks_passed + 1))
                    log "  ✓ /${bucket}: ${sc} secrets"
                else
                    issues+=("\"Infisical folder '/${bucket}' not found in dev\"")
                fi
            done
        fi

    elif [[ "$SECRETS_BACKEND" == "aws" ]]; then
        # Check IAM access
        checks_total=$((checks_total + 1))
        local identity
        identity=$(aws sts get-caller-identity --region "${AWS_REGION}" 2>/dev/null || echo "")
        if [[ -n "$identity" ]]; then
            checks_passed=$((checks_passed + 1))
            log "  ✓ AWS IAM authenticated"
        else
            issues+=("\"AWS IAM authentication failed\"")
        fi

        # Check each bucket exists in AWS
        for bucket in "${REQUIRED_BUCKETS[@]}"; do
            checks_total=$((checks_total + 1))
            local secret_exists
            secret_exists=$(aws secretsmanager describe-secret \
                --secret-id "${PROJECT_NAME}/development/${bucket}" \
                --region "${AWS_REGION}" 2>/dev/null || echo "")
            if [[ -n "$secret_exists" ]]; then
                checks_passed=$((checks_passed + 1))
                log "  ✓ ${PROJECT_NAME}/development/${bucket} exists"
            else
                issues+=("\"AWS secret '${PROJECT_NAME}/development/${bucket}' not found\"")
            fi
        done

        # Check docker-compose has only ENVIRONMENT + REGION
        checks_total=$((checks_total + 1))
        if [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
            if ! grep -q 'INFISICAL' "${PROJECT_ROOT}/docker-compose.yml" 2>/dev/null; then
                checks_passed=$((checks_passed + 1))
                log "  ✓ docker-compose.yml has no Infisical references"
            else
                issues+=("\"docker-compose.yml has Infisical references but backend is AWS\"")
            fi
        fi
    fi

    # Common checks
    checks_total=$((checks_total + 1))
    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        local extra_vars
        extra_vars=$(grep -v '^#' "${PROJECT_ROOT}/.env" | grep -v '^$' | grep -v '^ENVIRONMENT=' | grep -v '^REGION=' | grep -v '^SECRETS_PATH=' || true)
        if [[ -z "$extra_vars" ]]; then
            checks_passed=$((checks_passed + 1))
            log "  ✓ .env has only allowed variables"
        else
            issues+=("\"'.env' has extra variables: $(echo "$extra_vars" | tr '\n' ', ')\"")
        fi
    else
        issues+=("\"'.env' file not found\"")
    fi

    local issues_json="[]"
    if [[ ${#issues[@]} -gt 0 ]]; then
        issues_json="[$(IFS=,; echo "${issues[*]}")]"
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        _exit_with_context "success" "All ${checks_passed}/${checks_total} checks passed" "" \
            "\"checks_passed\": ${checks_passed}, \"checks_total\": ${checks_total}, \"issues\": ${issues_json}"
    else
        _exit_with_context "warning" "${#issues[@]} issues found (${checks_passed}/${checks_total} passed)" "" \
            "\"checks_passed\": ${checks_passed}, \"checks_total\": ${checks_total}, \"issues\": ${issues_json}"
    fi
}

#------------------------------------------------------------------------------
# Section: Create Project (Infisical only)
#------------------------------------------------------------------------------

run_create_project() {
    if [[ "$SECRETS_BACKEND" == "aws" ]]; then
        _exit_with_context "success" "AWS does not require project creation. Secrets are created per-bucket."
    fi

    log "=== Creating Infisical project ==="

    # Check if project already exists
    if [[ -n "$PROJECT_ID" ]]; then
        local existing
        existing=$(curl -sf "${INFISICAL_URL}/api/v1/workspace/${PROJECT_ID}" \
            -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
        if [[ -n "$existing" ]]; then
            local existing_name
            existing_name=$(echo "$existing" | jq -r '.workspace.name // ""' 2>/dev/null || echo "")
            _exit_with_context "success" "Project '${existing_name}' already exists: ${PROJECT_ID}" "" \
                "\"project_exists\": true"
        fi
    fi

    # Check projects.json
    local existing_id=""
    if [[ -f "${INFISICAL_DIR}/projects.json" ]]; then
        existing_id=$(jq -r ".\"${PROJECT_NAME}\" // \"\"" "${INFISICAL_DIR}/projects.json" 2>/dev/null || echo "")
    fi

    if [[ -n "$existing_id" ]]; then
        PROJECT_ID="$existing_id"
        _exit_with_context "success" "Project '${PROJECT_NAME}' found in projects.json: ${PROJECT_ID}" "" \
            "\"project_exists\": true"
    fi

    # Get org ID from an existing project
    local ref_project_id
    ref_project_id=$(jq -r 'to_entries[0].value // ""' "${INFISICAL_DIR}/projects.json" 2>/dev/null || echo "")
    if [[ -z "$ref_project_id" ]]; then
        _exit_with_context "error" "No existing projects in projects.json to derive org ID"
    fi

    ORG_ID=$(curl -sf "${INFISICAL_URL}/api/v1/workspace/${ref_project_id}" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | jq -r '.workspace.orgId // ""' || echo "")
    if [[ -z "$ORG_ID" || "$ORG_ID" == "null" ]]; then
        _exit_with_context "error" "Could not determine organization ID"
    fi

    log "Creating project '${PROJECT_NAME}' in org ${ORG_ID}..."

    local create_response
    create_response=$(curl -sf -X POST "${INFISICAL_URL}/api/v2/workspace" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"projectName\":\"${PROJECT_NAME}\",\"organizationId\":\"${ORG_ID}\"}" 2>/dev/null || echo "")

    PROJECT_ID=$(echo "$create_response" | jq -r '.project.id // ""' 2>/dev/null || echo "")
    if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
        local err_msg
        err_msg=$(echo "$create_response" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "Unknown error")
        _exit_with_context "error" "Failed to create project: ${err_msg}"
    fi

    # Update projects.json
    local tmp_file
    tmp_file=$(mktemp)
    jq ". + {\"${PROJECT_NAME}\": \"${PROJECT_ID}\"}" "${INFISICAL_DIR}/projects.json" > "$tmp_file" 2>/dev/null
    mv "$tmp_file" "${INFISICAL_DIR}/projects.json"

    # Add machine identities
    local identities
    identities=$(curl -sf "${INFISICAL_URL}/api/v2/organizations/${ORG_ID}/identity-memberships" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")

    local identity_names=""
    if [[ -n "$identities" ]]; then
        while IFS= read -r line; do
            local id name
            id=$(echo "$line" | jq -r '.identity.id' 2>/dev/null || echo "")
            name=$(echo "$line" | jq -r '.identity.name' 2>/dev/null || echo "")
            if [[ -n "$id" && "$id" != "null" ]]; then
                curl -sf -X POST "${INFISICAL_URL}/api/v2/workspace/${PROJECT_ID}/identity-memberships/${id}" \
                    -H "Authorization: Bearer ${TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d '{"role":"member"}' >/dev/null 2>&1 || true
                identity_names="${identity_names}\"${name}\","
                log "  Added identity: ${name}"
            fi
        done < <(echo "$identities" | jq -c '.identityMemberships[]' 2>/dev/null)
    fi
    identity_names="${identity_names%,}"

    local environments
    environments=$(echo "$create_response" | jq -r '.project.environments[] | .slug' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')

    _exit_with_context "success" "Project '${PROJECT_NAME}' created: ${PROJECT_ID}" "" \
        "\"project_exists\": false, \"environments\": \"${environments}\", \"identities_added\": [${identity_names}]"
}

#------------------------------------------------------------------------------
# Section: Create Folders
#------------------------------------------------------------------------------

run_create_folders() {
    log "=== Creating secret folders/buckets ==="

    if [[ ${#REQUIRED_BUCKETS[@]} -eq 0 ]]; then
        _exit_with_context "error" "No required buckets defined in PROJECT.yaml secrets.required"
    fi

    local created=()
    local existing=()

    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        if [[ -z "$PROJECT_ID" ]]; then
            _exit_with_context "error" "No project ID. Run --create-project first or set secrets.project_id in PROJECT.yaml"
        fi

        for env in dev prod; do
            for bucket in "${REQUIRED_BUCKETS[@]}"; do
                local result
                result=$(curl -sf -X POST "${INFISICAL_URL}/api/v1/folders" \
                    -H "Authorization: Bearer ${TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d "{\"workspaceId\":\"${PROJECT_ID}\",\"environment\":\"${env}\",\"name\":\"${bucket}\",\"path\":\"/\"}" 2>/dev/null || echo "")

                local folder_name
                folder_name=$(echo "$result" | jq -r '.folder.name // ""' 2>/dev/null || echo "")
                if [[ -n "$folder_name" && "$folder_name" != "null" ]]; then
                    created+=("${env}/${bucket}")
                else
                    existing+=("${env}/${bucket}")
                fi
            done
        done

    elif [[ "$SECRETS_BACKEND" == "aws" ]]; then
        for env in development staging production; do
            for bucket in "${REQUIRED_BUCKETS[@]}"; do
                local secret_exists
                secret_exists=$(aws secretsmanager describe-secret \
                    --secret-id "${PROJECT_NAME}/${env}/${bucket}" \
                    --region "${AWS_REGION}" 2>/dev/null || echo "")
                if [[ -z "$secret_exists" ]]; then
                    aws secretsmanager create-secret \
                        --name "${PROJECT_NAME}/${env}/${bucket}" \
                        --description "${bucket} for ${PROJECT_NAME} (${env})" \
                        --secret-string '{}' \
                        --region "${AWS_REGION}" >/dev/null 2>&1 || true
                    created+=("${env}/${bucket}")
                else
                    existing+=("${env}/${bucket}")
                fi
            done
        done
    fi

    _exit_with_context "success" "Folders ready. Created: ${#created[@]}, existing: ${#existing[@]}" "" \
        "\"created\": [$(printf '\"%s\",' "${created[@]}" | sed 's/,$//')], \"existing\": [$(printf '\"%s\",' "${existing[@]}" | sed 's/,$//')]"
}

#------------------------------------------------------------------------------
# Section: Populate (check status)
#------------------------------------------------------------------------------

run_populate() {
    log "=== Checking secret population ==="

    local populated=()
    local missing=()

    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        if [[ -z "$PROJECT_ID" ]]; then
            _exit_with_context "error" "No project ID set"
        fi

        for bucket in "${REQUIRED_BUCKETS[@]}"; do
            local secrets_response
            secrets_response=$(curl -sf "${INFISICAL_URL}/api/v3/secrets/raw?workspaceId=${PROJECT_ID}&environment=dev&secretPath=/${bucket}" \
                -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
            local secret_count
            secret_count=$(echo "$secrets_response" | jq '.secrets | length' 2>/dev/null || echo "0")

            if [[ "$secret_count" -gt 0 ]]; then
                local keys
                keys=$(echo "$secrets_response" | jq -r '.secrets[].secretKey' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
                populated+=("{\"folder\": \"${bucket}\", \"count\": ${secret_count}, \"keys\": \"${keys}\"}")
                log "  ✓ /${bucket}: ${secret_count} secrets (${keys})"
            else
                missing+=("\"${bucket}\"")
                log "  ✗ /${bucket}: empty"
            fi
        done

    elif [[ "$SECRETS_BACKEND" == "aws" ]]; then
        for bucket in "${REQUIRED_BUCKETS[@]}"; do
            local secret_value
            secret_value=$(aws secretsmanager get-secret-value \
                --secret-id "${PROJECT_NAME}/development/${bucket}" \
                --region "${AWS_REGION}" \
                --query SecretString --output text 2>/dev/null || echo "")

            if [[ -n "$secret_value" && "$secret_value" != "{}" ]]; then
                local keys
                keys=$(echo "$secret_value" | jq -r 'keys | join(", ")' 2>/dev/null || echo "")
                local kc
                kc=$(echo "$secret_value" | jq 'length' 2>/dev/null || echo "0")
                populated+=("{\"folder\": \"${bucket}\", \"count\": ${kc}, \"keys\": \"${keys}\"}")
                log "  ✓ ${bucket}: ${kc} keys (${keys})"
            else
                missing+=("\"${bucket}\"")
                log "  ✗ ${bucket}: empty or not found"
            fi
        done
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        _exit_with_context "warning" "${#missing[@]} folders need secrets populated" "" \
            "\"populated\": [$(IFS=,; echo "${populated[*]}")], \"missing_folders\": [$(IFS=,; echo "${missing[*]}")]"
    else
        _exit_with_context "success" "All ${#populated[@]} folders have secrets" "" \
            "\"populated\": [$(IFS=,; echo "${populated[*]}")]"
    fi
}

#------------------------------------------------------------------------------
# Section: Local Setup
#------------------------------------------------------------------------------

run_local_setup() {
    log "=== Setting up local environment ==="

    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        local secrets_dir="${PROJECT_ROOT}/.secrets"
        local created_files=()
        local existing_files=()

        mkdir -p "$secrets_dir"

        # Bootstrap files
        local -A files=(
            ["infisical_url"]="$INFISICAL_URL"
            ["infisical_client_id"]="$CLIENT_ID"
            ["infisical_client_secret"]="$CLIENT_SECRET"
            ["infisical_project_id"]="$PROJECT_ID"
        )

        for filename in "${!files[@]}"; do
            local value="${files[$filename]}"
            if [[ -f "${secrets_dir}/${filename}" ]]; then
                local current
                current=$(cat "${secrets_dir}/${filename}" 2>/dev/null || echo "")
                if [[ "$current" == "$value" ]]; then
                    existing_files+=("$filename")
                else
                    echo -n "$value" > "${secrets_dir}/${filename}"
                    created_files+=("$filename")
                fi
            else
                echo -n "$value" > "${secrets_dir}/${filename}"
                created_files+=("$filename")
            fi
        done

        # Generate mysql_root_password if missing
        if [[ ! -f "${secrets_dir}/mysql_root_password" ]]; then
            openssl rand -base64 24 | tr -d '\n' > "${secrets_dir}/mysql_root_password"
            created_files+=("mysql_root_password")
        else
            existing_files+=("mysql_root_password")
        fi

        # Check .gitignore
        local gitignore_ok=false
        grep -q '\.secrets' "${PROJECT_ROOT}/.gitignore" 2>/dev/null && gitignore_ok=true

        # Create .env if missing
        local env_created=false
        if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
            echo "ENVIRONMENT=dev" > "${PROJECT_ROOT}/.env"
            env_created=true
        fi

        _exit_with_context "success" "Local setup complete. Created: ${#created_files[@]}, existing: ${#existing_files[@]}" "" \
            "\"created_files\": [$(printf '\"%s\",' "${created_files[@]}" | sed 's/,$//')], \"existing_files\": [$(printf '\"%s\",' "${existing_files[@]}" | sed 's/,$//')], \"gitignore_ok\": ${gitignore_ok}, \"env_created\": ${env_created}"

    elif [[ "$SECRETS_BACKEND" == "aws" ]]; then
        # AWS uses IAM — no local secret files needed
        local env_created=false
        if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
            printf 'ENVIRONMENT=development\nREGION=%s\n' "$AWS_REGION" > "${PROJECT_ROOT}/.env"
            env_created=true
        fi

        _exit_with_context "success" "AWS uses IAM for authentication — no .secrets/ directory needed" "" \
            "\"env_created\": ${env_created}"
    fi
}

#------------------------------------------------------------------------------
# Section: Verify
#------------------------------------------------------------------------------

run_verify() {
    log "=== Verifying docker-compose and connectivity ==="

    local issues=()

    if [[ ! -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
        _exit_with_context "error" "docker-compose.yml not found"
    fi

    local compose_content
    compose_content=$(cat "${PROJECT_ROOT}/docker-compose.yml")

    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        # Check file-based secrets pattern
        echo "$compose_content" | grep -q 'SECRETS_PATH:-.secrets' || \
            issues+=("\"Secrets not using \${SECRETS_PATH:-.secrets} pattern\"")

        # Check for env var bootstrap anti-pattern
        echo "$compose_content" | grep -q 'x-infisical-bootstrap' && \
            issues+=("\"Remove x-infisical-bootstrap YAML anchor — use Docker secret files instead\"")

        # Check all 4 secrets defined
        for secret in infisical_url infisical_client_id infisical_client_secret infisical_project_id; do
            echo "$compose_content" | grep -q "  ${secret}:" || \
                issues+=("\"Missing Docker secret: ${secret}\"")
        done

        # Check services mount secrets
        for service in backend frontend; do
            if echo "$compose_content" | grep -q "  ${service}:"; then
                echo "$compose_content" | grep -A 30 "  ${service}:" | grep -q "infisical_client_secret" || \
                    issues+=("\"Service '${service}' not mounting infisical secrets\"")
            fi
        done

        # Test connectivity
        if [[ -n "$TOKEN" && -n "$PROJECT_ID" ]]; then
            local test_response
            test_response=$(curl -sf "${INFISICAL_URL}/api/v1/workspace/${PROJECT_ID}" \
                -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
            [[ -z "$test_response" ]] && issues+=("\"Cannot connect to Infisical project ${PROJECT_ID}\"")
        fi

    elif [[ "$SECRETS_BACKEND" == "aws" ]]; then
        # Check no Infisical references
        echo "$compose_content" | grep -qi 'infisical' && \
            issues+=("\"docker-compose.yml has Infisical references but backend is AWS\"")

        # Check ENVIRONMENT and REGION are present
        echo "$compose_content" | grep -q 'ENVIRONMENT' || \
            issues+=("\"docker-compose.yml missing ENVIRONMENT variable\"")
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        _exit_with_context "success" "Docker Compose and connectivity verified"
    else
        local issues_json="[$(IFS=,; echo "${issues[*]}")]"
        _exit_with_context "warning" "${#issues[@]} docker-compose issues found" "" \
            "\"issues\": ${issues_json}"
    fi
}

#------------------------------------------------------------------------------
# Section: Full (orchestrate all)
#------------------------------------------------------------------------------

run_full() {
    log "=== Full setup ==="

    if [[ "$SECRETS_BACKEND" == "infisical" ]]; then
        # 1. Create project if needed
        if [[ -z "$PROJECT_ID" ]]; then
            run_create_project
            # exit_with_json exits, so if we're here the project existed
        fi

        # 2. Create folders if needed
        local folders_missing=false
        for bucket in "${REQUIRED_BUCKETS[@]}"; do
            local check
            check=$(curl -sf "${INFISICAL_URL}/api/v1/folders?workspaceId=${PROJECT_ID}&environment=dev&path=/" \
                -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
            local has_it
            has_it=$(echo "$check" | jq -r ".folders[] | select(.name == \"${bucket}\") | .name" 2>/dev/null || echo "")
            if [[ -z "$has_it" ]]; then
                folders_missing=true
                break
            fi
        done

        if [[ "$folders_missing" == "true" ]]; then
            for env in dev prod; do
                for bucket in "${REQUIRED_BUCKETS[@]}"; do
                    curl -sf -X POST "${INFISICAL_URL}/api/v1/folders" \
                        -H "Authorization: Bearer ${TOKEN}" \
                        -H "Content-Type: application/json" \
                        -d "{\"workspaceId\":\"${PROJECT_ID}\",\"environment\":\"${env}\",\"name\":\"${bucket}\",\"path\":\"/\"}" >/dev/null 2>&1 || true
                done
            done
            log "Folders created"
        fi

        # 3. Local setup (inline, don't exit)
        mkdir -p "${PROJECT_ROOT}/.secrets"
        echo -n "${INFISICAL_URL}" > "${PROJECT_ROOT}/.secrets/infisical_url"
        echo -n "${CLIENT_ID}" > "${PROJECT_ROOT}/.secrets/infisical_client_id"
        echo -n "${CLIENT_SECRET}" > "${PROJECT_ROOT}/.secrets/infisical_client_secret"
        echo -n "${PROJECT_ID}" > "${PROJECT_ROOT}/.secrets/infisical_project_id"
        [[ ! -f "${PROJECT_ROOT}/.secrets/mysql_root_password" ]] && \
            openssl rand -base64 24 | tr -d '\n' > "${PROJECT_ROOT}/.secrets/mysql_root_password"
        [[ ! -f "${PROJECT_ROOT}/.env" ]] && echo "ENVIRONMENT=dev" > "${PROJECT_ROOT}/.env"
        log "Local setup done"

    elif [[ "$SECRETS_BACKEND" == "aws" ]]; then
        # Create buckets if needed
        for env in development staging production; do
            for bucket in "${REQUIRED_BUCKETS[@]}"; do
                aws secretsmanager describe-secret \
                    --secret-id "${PROJECT_NAME}/${env}/${bucket}" \
                    --region "${AWS_REGION}" >/dev/null 2>&1 || \
                aws secretsmanager create-secret \
                    --name "${PROJECT_NAME}/${env}/${bucket}" \
                    --description "${bucket} for ${PROJECT_NAME} (${env})" \
                    --secret-string '{}' \
                    --region "${AWS_REGION}" >/dev/null 2>&1 || true
            done
        done

        [[ ! -f "${PROJECT_ROOT}/.env" ]] && \
            printf 'ENVIRONMENT=development\nREGION=%s\n' "$AWS_REGION" > "${PROJECT_ROOT}/.env"
        log "AWS setup done"
    fi

    # 4. Run validate for final status
    run_validate
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

load_project_config
authenticate

case "$SECTION" in
    validate)       run_validate ;;
    create-project) run_create_project ;;
    create-folders) run_create_folders ;;
    populate)       run_populate ;;
    local-setup)    run_local_setup ;;
    verify)         run_verify ;;
    full)           run_full ;;
esac
