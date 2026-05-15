#!/usr/bin/env bash
# deployment-config.sh - Load and validate PROJECT.yaml deployment configuration
#
# Sourced library — sets global variables for deployment scripts.
# Supports reasonable defaults when PROJECT.yaml is missing.
#
# Provides: ENV_TYPE, DEV_BRANCH, STAGING_BRANCH, PRODUCTION_BRANCH,
#           CI_PLATFORM, DEPLOYMENT_METHOD, HEALTH_CHECK_PATH, VERSION_PATH,
#           E2E_COMMAND, E2E_TIMEOUT, STAGING_URL, PRODUCTION_URL, VERSION, etc.
#
# Usage: source "${SCRIPT_DIR}/lib/deployment-config.sh"

# Guard against double-sourcing
[[ -n "${_DEPLOYMENT_CONFIG_LOADED:-}" ]] && return 0
_DEPLOYMENT_CONFIG_LOADED=1

_DC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source yaml helper if not already loaded
if ! declare -f yaml_get &>/dev/null; then
    source "${_DC_DIR}/yaml.sh"
fi

DEPLOYMENT_WARNINGS=()
HAS_PROJECT_YAML=false

if [[ -f "PROJECT.yaml" ]]; then
    HAS_PROJECT_YAML=true
else
    DEPLOYMENT_WARNINGS+=("PROJECT.yaml not found - using auto-detected defaults")
    DEPLOYMENT_WARNINGS+=("Run '/project-config init' to create proper configuration")
fi

# Detect environment (work vs home)
if [[ "$(uname -s)" == "Darwin" ]]; then
    ENV_TYPE="work"
else
    ENV_TYPE="home"
fi

# =============================================================================
# Detection Functions (fallbacks when PROJECT.yaml values are empty)
# =============================================================================

_dc_detect_default_branch() {
    local remote_head
    remote_head=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "")
    if [[ -n "$remote_head" ]]; then
        echo "$remote_head"
        return 0
    fi

    for branch in main master; do
        if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
            echo "$branch"
            return 0
        fi
    done

    git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"
}

_dc_detect_dev_branch() {
    for branch in dev develop development; do
        if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
            echo "$branch"
            return 0
        fi
    done

    local current
    current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -n "$current" && "$current" != "main" && "$current" != "master" ]]; then
        echo "$current"
        return 0
    fi

    echo "dev"
}

_dc_detect_staging_branch() {
    for branch in staging stage stg; do
        if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
            echo "$branch"
            return 0
        fi
    done

    _dc_detect_default_branch
}

_dc_detect_production_branch() {
    for branch in production prod main master; do
        if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
            echo "$branch"
            return 0
        fi
    done

    echo "main"
}

_dc_detect_ci_platform() {
    local remote_url
    remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
    if [[ "$remote_url" =~ github\.com ]]; then
        echo "github"
        return 0
    elif [[ "$remote_url" =~ gitlab || "$remote_url" =~ git\. ]]; then
        echo "gitlab"
        return 0
    fi

    if command -v gh >/dev/null 2>&1; then
        echo "github"
        return 0
    elif command -v gitlab >/dev/null 2>&1 || command -v glab >/dev/null 2>&1; then
        echo "gitlab"
        return 0
    fi

    echo "github"
}

# =============================================================================
# Load Configuration
# =============================================================================

if [[ "$HAS_PROJECT_YAML" == "true" ]]; then
    STAGING_BRANCH=$(yaml_get '.ci.branches.staging' PROJECT.yaml)
    PRODUCTION_BRANCH=$(yaml_get '.ci.branches.production' PROJECT.yaml)
    DEV_BRANCH=$(yaml_get '.ci.branches.dev' PROJECT.yaml)
    CI_PLATFORM=$(yaml_get '.ci.platform' PROJECT.yaml)
    DEPLOYMENT_METHOD=$(yaml_get_default '.deployment.method' 'pipeline' PROJECT.yaml)
    HEALTH_CHECK_PATH=$(yaml_get_default '.deployment.health_check_path' '/health' PROJECT.yaml)
    VERSION_PATH=$(yaml_get_default '.deployment.version_path' '/api/version' PROJECT.yaml)
    E2E_COMMAND=$(yaml_get '.testing.e2e_command' PROJECT.yaml)
    E2E_TIMEOUT=$(yaml_get_default '.testing.e2e_timeout' '300' PROJECT.yaml)
    STAGING_URL=$(yaml_get '.deployment.staging.url' PROJECT.yaml)
    PRODUCTION_URL=$(yaml_get '.deployment.production.url' PROJECT.yaml)
    STAGING_PUBLIC_URL=$(yaml_get '.deployment.staging.public_url' PROJECT.yaml)
    PRODUCTION_PUBLIC_URL=$(yaml_get '.deployment.production.public_url' PROJECT.yaml)

    # Fallback: derive URL from roving_domain / nginx_ssl_domain when .url is unset.
    # Projects like medical-clearance use a blue-green schema without an explicit .url key.
    # (This file is sourced at top level, not inside a function — can't use `local`.)
    if [[ -z "$STAGING_URL" ]]; then
        _staging_domain=$(yaml_get '.deployment.staging.roving_domain' PROJECT.yaml)
        [[ -z "$_staging_domain" ]] && _staging_domain=$(yaml_get '.deployment.staging.nginx_ssl_domain' PROJECT.yaml)
        [[ -n "$_staging_domain" ]] && STAGING_URL="https://${_staging_domain}"
        unset _staging_domain
    fi
    if [[ -z "$PRODUCTION_URL" ]]; then
        _prod_domain=$(yaml_get '.deployment.production.roving_domain' PROJECT.yaml)
        [[ -z "$_prod_domain" ]] && _prod_domain=$(yaml_get '.deployment.production.nginx_ssl_domain' PROJECT.yaml)
        [[ -n "$_prod_domain" ]] && PRODUCTION_URL="https://${_prod_domain}"
        unset _prod_domain
    fi

    # Blue-green strategy
    DEPLOY_STRATEGY=$(yaml_get_default '.deployment.strategy' '' PROJECT.yaml)
    DEPLOY_ACTIVE_COLOR=$(yaml_get_default '.deployment.active' '' PROJECT.yaml)
    DEPLOY_REGION=$(yaml_get_default '.deployment.region' 'us-west-1' PROJECT.yaml)
    if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
        STAGING_BLUE_INSTANCE=$(yaml_get '.deployment.staging.blue.instance_id' PROJECT.yaml)
        STAGING_GREEN_INSTANCE=$(yaml_get '.deployment.staging.green.instance_id' PROJECT.yaml)
        PRODUCTION_BLUE_INSTANCE=$(yaml_get '.deployment.production.blue.instance_id' PROJECT.yaml)
        PRODUCTION_GREEN_INSTANCE=$(yaml_get '.deployment.production.green.instance_id' PROJECT.yaml)
    fi
else
    STAGING_BRANCH=""
    PRODUCTION_BRANCH=""
    DEV_BRANCH=""
    CI_PLATFORM=""
    DEPLOYMENT_METHOD="pipeline"
    HEALTH_CHECK_PATH="/health"
    VERSION_PATH="/api/version"
    E2E_COMMAND=""
    E2E_TIMEOUT="300"
    STAGING_URL=""
    PRODUCTION_URL=""
    STAGING_PUBLIC_URL=""
    PRODUCTION_PUBLIC_URL=""
    DEPLOY_STRATEGY=""
    DEPLOY_ACTIVE_COLOR=""
    DEPLOY_REGION="us-west-1"
    STAGING_BLUE_INSTANCE=""
    STAGING_GREEN_INSTANCE=""
    PRODUCTION_BLUE_INSTANCE=""
    PRODUCTION_GREEN_INSTANCE=""
fi

# Apply fallback detection for empty values
if [[ -z "$DEV_BRANCH" ]]; then
    DEV_BRANCH=$(_dc_detect_dev_branch)
    DEPLOYMENT_WARNINGS+=("Using detected dev branch: $DEV_BRANCH")
fi

if [[ -z "$STAGING_BRANCH" ]]; then
    STAGING_BRANCH=$(_dc_detect_staging_branch)
    DEPLOYMENT_WARNINGS+=("Using detected staging branch: $STAGING_BRANCH")
fi

if [[ -z "$PRODUCTION_BRANCH" ]]; then
    PRODUCTION_BRANCH=$(_dc_detect_production_branch)
    DEPLOYMENT_WARNINGS+=("Using detected production branch: $PRODUCTION_BRANCH")
fi

if [[ -z "$CI_PLATFORM" && "$DEPLOYMENT_METHOD" == "pipeline" ]]; then
    CI_PLATFORM=$(_dc_detect_ci_platform)
    DEPLOYMENT_WARNINGS+=("Using detected CI platform: $CI_PLATFORM")
fi

# Get version information
VERSION=$("${_DC_DIR}/../get-version.sh" -q 2>/dev/null || echo "")
if [[ -z "$VERSION" ]]; then
    VERSION=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

# Validate critical settings
if [[ -n "$CI_PLATFORM" && "$CI_PLATFORM" != "github" && "$CI_PLATFORM" != "gitlab" ]]; then
    echo "Invalid ci.platform: $CI_PLATFORM (must be github or gitlab)" >&2
    return 1
fi

# Export for use in parent shell
export ENV_TYPE STAGING_BRANCH PRODUCTION_BRANCH DEV_BRANCH CI_PLATFORM DEPLOYMENT_METHOD
export HEALTH_CHECK_PATH VERSION_PATH E2E_COMMAND E2E_TIMEOUT STAGING_URL PRODUCTION_URL VERSION
export STAGING_PUBLIC_URL PRODUCTION_PUBLIC_URL
export DEPLOY_STRATEGY DEPLOY_ACTIVE_COLOR DEPLOY_REGION
export STAGING_BLUE_INSTANCE STAGING_GREEN_INSTANCE PRODUCTION_BLUE_INSTANCE PRODUCTION_GREEN_INSTANCE

# =============================================================================
# Blue-Green Instance Management
# =============================================================================

# Determine the inactive color (the one we deploy to)
_dc_inactive_color() {
    if [[ "$DEPLOY_ACTIVE_COLOR" == "blue" ]]; then
        echo "green"
    else
        echo "blue"
    fi
}

# Get the instance ID for a given environment and color
# Usage: _dc_instance_id "staging" "green"
_dc_instance_id() {
    local env="$1" color="$2"
    local var="${env^^}_${color^^}_INSTANCE"
    echo "${!var}"
}

# Ensure EC2 instances are running for a given environment's inactive color.
# Delegates to scripts/deploy/ensure-instance.sh which handles start + SSM readiness.
# Usage: dc_ensure_target_instances "staging"  (or "production")
# Returns 0 on success, 1 on failure. Outputs JSON status to stdout.
dc_ensure_target_instances() {
    local environment="$1"

    if [[ "$DEPLOY_STRATEGY" != "blue-green" ]]; then
        echo '{"status":"skipped","reason":"not blue-green strategy"}'
        return 0
    fi

    local inactive
    inactive=$(_dc_inactive_color)

    local instance_id
    instance_id=$(_dc_instance_id "$environment" "$inactive")

    if [[ -z "$instance_id" ]]; then
        echo "{\"status\":\"error\",\"reason\":\"no instance_id for ${environment} ${inactive}\"}"
        return 1
    fi

    local region="${DEPLOY_REGION:-us-west-1}"

    # Find the shared ensure-instance.sh script
    local script=""
    if [[ -f "./scripts/deploy/ensure-instance.sh" ]]; then
        script="./scripts/deploy/ensure-instance.sh"
    elif [[ -f "${_DC_DIR}/../../scripts/deploy/ensure-instance.sh" ]]; then
        script="${_DC_DIR}/../../scripts/deploy/ensure-instance.sh"
    fi

    if [[ -n "$script" ]]; then
        # Use the shared script (handles start + SSM readiness)
        bash "$script" --instance-id "$instance_id" --region "$region"
    else
        # Fallback: basic EC2 state check without SSM wait
        local state
        state=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$region" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>&1) || {
            echo "{\"status\":\"error\",\"instance_id\":\"$instance_id\",\"reason\":\"failed to query instance\"}"
            return 1
        }

        if [[ "$state" == "running" ]]; then
            echo "{\"status\":\"already_running\",\"instance_id\":\"$instance_id\",\"color\":\"$inactive\",\"environment\":\"$environment\"}"
            return 0
        elif [[ "$state" == "stopped" || "$state" == "stopping" ]]; then
            [[ "$state" == "stopping" ]] && aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "$region" 2>/dev/null
            aws ec2 start-instances --instance-ids "$instance_id" --region "$region" --output json >/dev/null 2>&1 || {
                echo "{\"status\":\"error\",\"instance_id\":\"$instance_id\",\"reason\":\"failed to start instance\"}"
                return 1
            }
            aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region" 2>/dev/null || {
                echo "{\"status\":\"error\",\"instance_id\":\"$instance_id\",\"reason\":\"timeout waiting for running state\"}"
                return 1
            }
            echo "{\"status\":\"started\",\"instance_id\":\"$instance_id\",\"color\":\"$inactive\",\"environment\":\"$environment\",\"previous_state\":\"$state\"}"
            return 0
        else
            echo "{\"status\":\"error\",\"instance_id\":\"$instance_id\",\"reason\":\"instance in unrecoverable state: $state\"}"
            return 1
        fi
    fi
}

# Resolve the URL of the *inactive* (target) color for blue-green deploys.
# DNS is the source of truth for which color is currently active — we resolve
# the roving domain and match the IP against blue/green public_ip in
# PROJECT.yaml. The OTHER color is inactive == where the deploy just landed.
#
# Echoes the target URL (e.g. https://clearance-blue.example.com) on success.
# Echoes nothing (and returns 1) when:
#   - DEPLOY_STRATEGY != "blue-green"
#   - PROJECT.yaml is missing required fields (roving_domain, blue/green public_ip+domain)
#   - DNS lookup fails or doesn't match either color
#
# Usage: target_url=$(dc_get_target_url staging)  (or "production")
dc_get_target_url() {
    local env="$1"
    [[ "$DEPLOY_STRATEGY" != "blue-green" ]] && return 1

    local roving blue_ip green_ip blue_domain green_domain resolved
    roving=$(yaml_get ".deployment.${env}.roving_domain" PROJECT.yaml)
    blue_ip=$(yaml_get ".deployment.${env}.blue.public_ip" PROJECT.yaml)
    green_ip=$(yaml_get ".deployment.${env}.green.public_ip" PROJECT.yaml)
    blue_domain=$(yaml_get ".deployment.${env}.blue.domain" PROJECT.yaml)
    green_domain=$(yaml_get ".deployment.${env}.green.domain" PROJECT.yaml)

    [[ -z "$roving" || -z "$blue_ip" || -z "$green_ip" ]] && return 1
    [[ -z "$blue_domain" || -z "$green_domain" ]] && return 1

    # Use a public resolver to bypass any local DNS caching that might lag a cutover.
    resolved=$(dig +short "$roving" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
    [[ -z "$resolved" ]] && return 1

    if [[ "$resolved" == "$blue_ip" ]]; then
        echo "https://${green_domain}"
    elif [[ "$resolved" == "$green_ip" ]]; then
        echo "https://${blue_domain}"
    else
        return 1
    fi
}

# Output warnings if any (only when not in json mode)
if [[ ${#DEPLOYMENT_WARNINGS[@]} -gt 0 && "${OUTPUT_MODE:-}" != "json" ]]; then
    for warning in "${DEPLOYMENT_WARNINGS[@]}"; do
        echo "⚠️  $warning" >&2
    done
    echo "" >&2
fi
