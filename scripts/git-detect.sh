#!/usr/bin/env bash
set -euo pipefail

# Detect git platform configuration from PROJECT.yaml
# Usage: git-detect.sh                  # Returns all fields as JSON
#        git-detect.sh --field platform  # Returns single field value
#
# Fields: platform, instance, repo, api_url, project_path, token_file
# No exports. Callers capture output via command substitution.

# Detect if sourced vs executed directly. When sourced, skip arg parsing
# and output — the caller only needs the exported variables.
_GIT_DETECT_SOURCED=false
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _GIT_DETECT_SOURCED=true
fi

FIELD=""

if [[ "$_GIT_DETECT_SOURCED" == "false" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --field) FIELD="${2:?--field requires a value}"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done
fi

# Find PROJECT.yaml by walking up from cwd (intentional: finds closest PROJECT.yaml
# in nested repo structures, matching "closest project" semantics)
PROJECT_YAML=""
CURRENT_DIR=$(pwd)
while [[ "$CURRENT_DIR" != "/" ]]; do
    if [[ -f "$CURRENT_DIR/PROJECT.yaml" ]]; then
        PROJECT_YAML="$CURRENT_DIR/PROJECT.yaml"
        break
    fi
    CURRENT_DIR=$(dirname "$CURRENT_DIR")
done

if [[ -z "$PROJECT_YAML" ]]; then
    if [[ "$_GIT_DETECT_SOURCED" == "true" ]]; then
        echo "Error: PROJECT.yaml not found" >&2
        return 1
    elif [[ -n "$FIELD" ]]; then
        echo "Error: PROJECT.yaml not found" >&2
        exit 1
    fi
    cat <<'EOF'
{"status":"error","next_action":"fix_error","message":"PROJECT.yaml not found"}
EOF
    exit 1
fi

# Read fields with yq for safe YAML parsing
GIT_PLATFORM=$(yq -r '.git.platform // ""' "$PROJECT_YAML")
GIT_INSTANCE=$(yq -r '.git.instance // ""' "$PROJECT_YAML")
GIT_REPO=$(yq -r '.git.repo // ""' "$PROJECT_YAML")

if [[ -z "$GIT_PLATFORM" ]]; then
    if [[ "$_GIT_DETECT_SOURCED" == "true" ]]; then
        echo "Error: git.platform not found in PROJECT.yaml" >&2
        return 1
    elif [[ -n "$FIELD" ]]; then
        echo "Error: git.platform not found in PROJECT.yaml" >&2
        exit 1
    fi
    cat <<'EOF'
{"status":"error","next_action":"fix_error","message":"git.platform not found in PROJECT.yaml"}
EOF
    exit 1
fi

# Platform-specific derived fields
GIT_TOKEN_FILE=""
GIT_API_URL=""
GIT_PROJECT_PATH=""

case "$GIT_PLATFORM" in
    gitlab)
        # Where the token lives is a per-machine choice, so it comes from the
        # profile (git.token_file) rather than being hardcoded here — one
        # person's ~/.secrets/gitlab-token is another's ~/.gitlab-token, and
        # baking either in silently sends every other machine to a path that
        # does not exist. ~/.gitlab-token is the documented default.
        GIT_TOKEN_FILE=""
        if declare -f profile_env_get >/dev/null 2>&1; then
            GIT_TOKEN_FILE=$(profile_env_get .git.token_file 2>/dev/null || true)
        fi
        [[ -z "$GIT_TOKEN_FILE" || "$GIT_TOKEN_FILE" == "null" ]] && GIT_TOKEN_FILE="${HOME}/.gitlab-token"
        GIT_TOKEN_FILE="${GIT_TOKEN_FILE/#\~/$HOME}"
        GIT_API_URL="https://${GIT_INSTANCE}/api/v4"
        GIT_PROJECT_PATH=$(echo "$GIT_REPO" | sed 's|/|%2F|g')
        ;;
    github)
        GIT_TOKEN_FILE=""
        GIT_API_URL="https://api.github.com"
        GIT_PROJECT_PATH="$GIT_REPO"
        ;;
esac

# When sourced, variables are set — skip output and exit logic
if [[ "$_GIT_DETECT_SOURCED" == "false" ]]; then
    # Single field mode
    if [[ -n "$FIELD" ]]; then
        case "$FIELD" in
            platform)     echo "$GIT_PLATFORM" ;;
            instance)     echo "$GIT_INSTANCE" ;;
            repo)         echo "$GIT_REPO" ;;
            api_url)      echo "$GIT_API_URL" ;;
            project_path) echo "$GIT_PROJECT_PATH" ;;
            token_file)   echo "$GIT_TOKEN_FILE" ;;
            *) echo "Unknown field: $FIELD" >&2; exit 1 ;;
        esac
        exit 0
    fi

    # JSON mode (default) - use jq for safe escaping
    jq -n \
        --arg platform "$GIT_PLATFORM" \
        --arg instance "$GIT_INSTANCE" \
        --arg repo "$GIT_REPO" \
        --arg api_url "$GIT_API_URL" \
        --arg project_path "$GIT_PROJECT_PATH" \
        --arg token_file "$GIT_TOKEN_FILE" \
        '{platform:$platform,instance:$instance,repo:$repo,api_url:$api_url,project_path:$project_path,token_file:$token_file}'
fi
