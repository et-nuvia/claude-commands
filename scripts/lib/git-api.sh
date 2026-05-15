#!/usr/bin/env bash
# git-api.sh - Git platform API helpers
# Source this file for gitlab_api() and github_api() functions
# Requires: GIT_API_URL, GIT_TOKEN_FILE set by caller (from git-detect.sh output)

# Wrapper for GitLab API calls with error handling.
# Usage: gitlab_api GET "/projects/ID/pipelines" [extra_curl_args...]
# Requires: GIT_API_URL and GIT_TOKEN_FILE variables set by caller
# Returns JSON on stdout. Returns 1 with message on HTTP error.
gitlab_api() {
    local method="${1:?method required}"
    local endpoint="${2:?endpoint required}"
    shift 2

    [[ -n "${GIT_API_URL:-}" ]] || { echo "Error: GIT_API_URL not set" >&2; return 1; }
    [[ -f "${GIT_TOKEN_FILE:-}" ]] || { echo "Error: Token file not found: ${GIT_TOKEN_FILE:-unset}" >&2; return 1; }

    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' RETURN

    local http_code
    http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 \
        -X "$method" \
        --header "PRIVATE-TOKEN: $(cat "$GIT_TOKEN_FILE")" \
        "$@" \
        "${GIT_API_URL}${endpoint}")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        cat "$tmpfile"
        return 0
    else
        echo "GitLab API error: HTTP ${http_code} on ${method} ${endpoint}" >&2
        cat "$tmpfile" >&2
        return 1
    fi
}
