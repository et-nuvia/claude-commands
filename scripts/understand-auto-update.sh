#!/usr/bin/env bash
set -uo pipefail
# understand-auto-update.sh — cron-driven auto-update orchestrator.
#
# Walks the understand-watchlist, decides per-repo whether the graph has
# drifted beyond churn thresholds, and dispatches understand-scan.sh for those
# that need it. Per-repo failures are logged and the walk continues.
#
# Sections:
#   --full              Walk watchlist (default: ~/.claude/understand-watchlist.txt).
#   --check <repo>      Single-repo dry run; decision + churn metrics, no scan.
#   --rescan <repo>     Force rescan, bypass threshold check.

set -uo pipefail
# NOTE: -e is intentionally omitted so per-repo errors during --full do NOT
# kill the walk. Functions return explicit statuses; callers check them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Allow tests / unusual installs to point at a different scan script.
SCAN_SCRIPT="${SCAN_SCRIPT:-${SCRIPT_DIR}/understand-scan.sh}"

DEFAULT_WATCHLIST="${HOME}/.claude/understand-watchlist.txt"
DEFAULT_VIEWER_API_KEY_FILE="${HOME}/.claude/.secrets/viewer_api_key"
DEFAULT_VIEWER_URL_FILE="${HOME}/.claude/.secrets/viewer_url"
VIEWER_API_KEY_FILE="${VIEWER_API_KEY_FILE:-$DEFAULT_VIEWER_API_KEY_FILE}"
VIEWER_URL_FILE="${VIEWER_URL_FILE:-$DEFAULT_VIEWER_URL_FILE}"
DEFAULT_THRESH_COMMITS=20
DEFAULT_THRESH_FILES_PCT=10
DEFAULT_THRESH_MAX_AGE_DAYS=30
CURRENT_GRAPH_SCHEMA_VERSION=1
GRAPH_REL=".understand/graph.json"
CONFIG_REL=".understand/config.json"
LAST_RUN_REL=".understand/last-run.json"

# --- Flag parsing ---
OUTPUT_MODE="json"
SECTION=""
WATCHLIST=""
SINGLE_REPO=""
NO_PUSH=0
PUSH_ONLY_GROUP=""
GROUP_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)       OUTPUT_MODE="json"; shift ;;
        --raw)        OUTPUT_MODE="raw"; shift ;;
        --toon)       OUTPUT_MODE="toon"; shift ;;
        --full)       SECTION="full"; shift ;;
        --check)      SECTION="check"; SINGLE_REPO="${2:-}"; shift 2 ;;
        --rescan)     SECTION="rescan"; SINGLE_REPO="${2:-}"; shift 2 ;;
        --push-only)  SECTION="push_only"; SINGLE_REPO="${2:-}"; shift 2 ;;
        --no-push)    NO_PUSH=1; shift ;;
        --group)      GROUP_OVERRIDE="${2:-}"; shift 2 ;;
        --watchlist)  WATCHLIST="$2"; shift 2 ;;
        *)
            exit_with_json "error" "unknown flag: $1"
            ;;
    esac
done

# --group only makes sense alongside --push-only (single-repo manual case).
# For --full, the watchlist's ":override" suffix is the supported mechanism.
if [[ -n "$GROUP_OVERRIDE" && "$SECTION" != "push_only" ]]; then
    exit_with_json "error" "--group is only valid with --push-only (use watchlist ':override' suffix for --full)"
fi
if [[ "$SECTION" == "push_only" && -n "$GROUP_OVERRIDE" ]]; then
    PUSH_ONLY_GROUP="$GROUP_OVERRIDE"
fi

[[ -z "$SECTION" ]] && SECTION="full"
[[ -z "$WATCHLIST" ]] && WATCHLIST="$DEFAULT_WATCHLIST"

# --- Helpers ---

# JSON-encode a bash string (no trailing newline) for safe embedding.
json_str() {
    jq -Rn --arg v "$1" '$v'
}

# Expand a leading ~ to $HOME (POSIX read doesn't do shell expansion).
expand_tilde() {
    local p="$1"
    if [[ "$p" == "~" ]]; then
        printf '%s' "$HOME"
    elif [[ "$p" == "~/"* ]]; then
        printf '%s/%s' "$HOME" "${p#\~/}"
    else
        printf '%s' "$p"
    fi
}

# Parse one watchlist line. Sets $LINE_PATH and $LINE_GROUP (empty if none).
# Returns 1 if the line is blank or a comment.
parse_watchlist_line() {
    local raw="$1"
    # Strip leading/trailing whitespace.
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ -z "$raw" ]] && return 1
    [[ "${raw:0:1}" == "#" ]] && return 1
    LINE_GROUP=""
    LINE_PATH="$raw"
    # :group_override is everything after the LAST colon, IF present and the
    # part before is a non-empty path. Paths typically have no `:` on *nix.
    if [[ "$raw" == *:* ]]; then
        local before="${raw%:*}"
        local after="${raw##*:}"
        if [[ -n "$before" && -n "$after" ]]; then
            LINE_PATH="$before"
            LINE_GROUP="$after"
        fi
    fi
    LINE_PATH="$(expand_tilde "$LINE_PATH")"
    return 0
}

# Detect default branch — try common names against origin.
detect_default_branch() {
    local repo="$1"
    local candidates=("dev" "develop" "main" "master")
    local b
    for b in "${candidates[@]}"; do
        if git -C "$repo" rev-parse --verify "refs/remotes/origin/${b}" >/dev/null 2>&1; then
            echo "$b"
            return 0
        fi
    done
    # Fallback: check local refs.
    for b in "${candidates[@]}"; do
        if git -C "$repo" rev-parse --verify "refs/heads/${b}" >/dev/null 2>&1; then
            echo "$b"
            return 0
        fi
    done
    return 1
}

# Load per-repo thresholds. Sets THRESH_COMMITS, THRESH_FILES_PCT, THRESH_MAX_AGE_DAYS.
load_thresholds() {
    local repo="$1"
    THRESH_COMMITS="$DEFAULT_THRESH_COMMITS"
    THRESH_FILES_PCT="$DEFAULT_THRESH_FILES_PCT"
    THRESH_MAX_AGE_DAYS="$DEFAULT_THRESH_MAX_AGE_DAYS"
    local cfg="${repo}/${CONFIG_REL}"
    if [[ -f "$cfg" ]]; then
        local v
        v=$(jq -r '.thresholds.commits // empty' "$cfg" 2>/dev/null || true)
        [[ -n "$v" ]] && THRESH_COMMITS="$v"
        v=$(jq -r '.thresholds.files_pct // empty' "$cfg" 2>/dev/null || true)
        [[ -n "$v" ]] && THRESH_FILES_PCT="$v"
        v=$(jq -r '.thresholds.max_age_days // empty' "$cfg" 2>/dev/null || true)
        [[ -n "$v" ]] && THRESH_MAX_AGE_DAYS="$v"
    fi
}

# Parse ISO-8601 UTC timestamp (with or without 'Z') to epoch seconds.
# Mirrors scripts/understand-explore.sh: GNU `date -d` first, BSD fallback.
parse_iso8601_to_epoch() {
    local ts="$1"
    local epoch
    if epoch=$(date -d "$ts" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi
    local stripped="${ts%Z}"
    if epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$stripped" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi
    return 1
}

# Evaluate a repo against the threshold logic without invoking scan.
# Echoes JSON: {action, reason, churn_metrics, default_branch}.
# Always returns 0 unless the repo is fundamentally unusable; the JSON tells
# the story.
evaluate_repo() {
    local repo="$1"
    if [[ ! -d "$repo" ]]; then
        jq -n --arg r "$repo" '{action:"error", reason:"repo path does not exist", repo:$r}'
        return 1
    fi
    if [[ ! -d "${repo}/.git" ]] && ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        jq -n --arg r "$repo" '{action:"error", reason:"not a git repo", repo:$r}'
        return 1
    fi

    local graph="${repo}/${GRAPH_REL}"
    if [[ ! -f "$graph" ]]; then
        jq -n '{action:"rescan", reason:"no graph yet", churn_metrics:{}}'
        return 0
    fi

    local default_branch
    if ! default_branch=$(detect_default_branch "$repo"); then
        jq -n '{action:"skip", reason:"could not detect default branch", churn_metrics:{}}'
        return 0
    fi

    # Dirty tree? Ignore .understand/ — those files are local-only by policy
    # (only graph.json is committed; lock/scratch/config are gitignored).
    local porcelain
    porcelain=$(git -C "$repo" status --porcelain 2>/dev/null | grep -Ev ' \.understand(/|$)' || true)
    if [[ -n "$porcelain" ]]; then
        jq -n --arg db "$default_branch" \
            '{action:"skip", reason:"uncommitted changes present", churn_metrics:{}, default_branch:$db}'
        return 0
    fi

    # On default branch?
    local current
    current=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$current" != "$default_branch" ]]; then
        jq -n --arg db "$default_branch" --arg cur "$current" \
            '{action:"skip", reason:("not on default branch (on " + $cur + ")"), churn_metrics:{}, default_branch:$db}'
        return 0
    fi

    # Read graph commit_sha, scanned_at, and schema version.
    local pinned_sha scanned_at graph_schema_version
    pinned_sha=$(jq -r '.meta.commit_sha // empty' "$graph" 2>/dev/null || echo "")
    scanned_at=$(jq -r '.meta.scanned_at // empty' "$graph" 2>/dev/null || echo "")
    graph_schema_version=$(jq -r '.graph_schema_version // empty' "$graph" 2>/dev/null || echo "")
    if [[ -z "$pinned_sha" ]]; then
        jq -n '{action:"rescan", reason:"graph missing meta.commit_sha", churn_metrics:{}}'
        return 0
    fi

    # Schema mismatch (or missing) takes precedence — graph is structurally
    # incompatible, churn comparisons aren't meaningful.
    if [[ -z "$graph_schema_version" ]]; then
        jq -n --arg cur "$CURRENT_GRAPH_SCHEMA_VERSION" \
            '{action:"rescan",
              reason:("schema_version mismatch (graph=missing, current=" + $cur + ")"),
              churn_metrics:{age_days:null, graph_schema_version:null}}'
        return 0
    fi
    if [[ "$graph_schema_version" != "$CURRENT_GRAPH_SCHEMA_VERSION" ]]; then
        jq -n --arg gv "$graph_schema_version" --arg cur "$CURRENT_GRAPH_SCHEMA_VERSION" \
            --argjson gvj "$graph_schema_version" \
            '{action:"rescan",
              reason:("schema_version mismatch (graph=" + $gv + ", current=" + $cur + ")"),
              churn_metrics:{age_days:null, graph_schema_version:$gvj}}'
        return 0
    fi

    # Age check: missing/unparseable scanned_at -> force rescan.
    local now_epoch scanned_epoch age_days
    now_epoch=$(date +%s)
    if [[ -z "$scanned_at" ]]; then
        jq -n --argjson gv "$graph_schema_version" \
            '{action:"rescan", reason:"missing scanned_at",
              churn_metrics:{age_days:null, graph_schema_version:$gv}}'
        return 0
    fi
    if ! scanned_epoch=$(parse_iso8601_to_epoch "$scanned_at"); then
        jq -n --argjson gv "$graph_schema_version" --arg sa "$scanned_at" \
            '{action:"rescan", reason:("unparseable scanned_at: " + $sa),
              churn_metrics:{age_days:null, graph_schema_version:$gv}}'
        return 0
    fi
    age_days=$(( (now_epoch - scanned_epoch) / 86400 ))

    # Fetch latest (best-effort; ignore failure — local refs may be enough).
    git -C "$repo" fetch --quiet origin "$default_branch" >/dev/null 2>&1 || true

    local origin_ref="origin/${default_branch}"
    # If origin ref isn't resolvable, fall back to local branch ref.
    if ! git -C "$repo" rev-parse --verify "refs/remotes/${origin_ref}" >/dev/null 2>&1; then
        origin_ref="$default_branch"
    fi

    # Churn metrics.
    local commits_since=0 files_changed=0 total_files=1
    if git -C "$repo" rev-parse --verify "$pinned_sha" >/dev/null 2>&1; then
        commits_since=$(git -C "$repo" rev-list --count "${pinned_sha}..${origin_ref}" 2>/dev/null || echo 0)
        files_changed=$(git -C "$repo" diff --name-only "${pinned_sha}" "${origin_ref}" 2>/dev/null | grep -c . || true)
    else
        # Pinned sha unknown locally — treat as drifted.
        jq -n '{action:"rescan", reason:"graph commit_sha not found in repo history", churn_metrics:{}}'
        return 0
    fi
    total_files=$(git -C "$repo" ls-tree -r --name-only "$origin_ref" 2>/dev/null | grep -c . || true)
    [[ "$total_files" -lt 1 ]] && total_files=1

    # Percentage: integer math (truncated). Tests use generous margins.
    local files_pct=$(( (files_changed * 100) / total_files ))

    load_thresholds "$repo"

    local action reason
    if (( age_days > THRESH_MAX_AGE_DAYS )); then
        action="rescan"
        reason="graph age exceeded threshold (${age_days} days > ${THRESH_MAX_AGE_DAYS} days)"
    elif (( commits_since > THRESH_COMMITS )); then
        action="rescan"
        reason="commits exceeded threshold (${commits_since} > ${THRESH_COMMITS})"
    elif (( files_pct > THRESH_FILES_PCT )); then
        action="rescan"
        reason="files exceeded threshold (${files_pct}% > ${THRESH_FILES_PCT}%)"
    else
        action="skip"
        reason="below threshold"
    fi

    jq -n \
        --arg action "$action" \
        --arg reason "$reason" \
        --arg db "$default_branch" \
        --argjson commits_since "$commits_since" \
        --argjson files_changed "$files_changed" \
        --argjson total_files "$total_files" \
        --argjson files_pct "$files_pct" \
        --argjson age_days "$age_days" \
        --argjson graph_schema_version "$graph_schema_version" \
        --argjson thresh_c "$THRESH_COMMITS" \
        --argjson thresh_f "$THRESH_FILES_PCT" \
        --argjson thresh_age "$THRESH_MAX_AGE_DAYS" \
        '{
            action: $action,
            reason: $reason,
            default_branch: $db,
            churn_metrics: {
                commits_since: $commits_since,
                files_changed: $files_changed,
                total_files: $total_files,
                files_changed_pct: $files_pct,
                age_days: $age_days,
                graph_schema_version: $graph_schema_version,
                thresholds: { commits: $thresh_c, files_pct: $thresh_f, max_age_days: $thresh_age }
            }
        }'
    return 0
}

# Invoke the scan script for a repo. Returns scan exit code via $SCAN_STATUS,
# duration in seconds via $SCAN_DURATION, and stdout payload via $SCAN_OUTPUT.
run_scan() {
    local repo="$1"
    local mode="$2"   # "incremental" or "scan"
    local start end
    start=$(date +%s)
    SCAN_OUTPUT=$(cd "$repo" && "$SCAN_SCRIPT" --json "--${mode}" 2>&1)
    SCAN_STATUS=$?
    end=$(date +%s)
    SCAN_DURATION=$(( end - start ))
}

# Write per-repo last-run.json. Best-effort; failure is non-fatal.
write_last_run() {
    local repo="$1" action="$2" reason="$3" churn="$4" scan_status="$5" scan_duration="$6" push_json="${7:-null}"
    mkdir -p "${repo}/.understand" 2>/dev/null || return 0
    local ts
    ts=$(date -Iseconds)
    jq -n \
        --arg checked_at "$ts" \
        --arg action "$action" \
        --arg reason "$reason" \
        --argjson churn "$churn" \
        --arg scan_status "$scan_status" \
        --argjson scan_duration "$scan_duration" \
        --argjson push "$push_json" \
        '{
            checked_at: $checked_at,
            action: $action,
            reason: $reason,
            churn_metrics: $churn,
            scan_status: $scan_status,
            scan_duration_seconds: $scan_duration,
            scan_cost_usd: null,
            push: $push
        }' > "${repo}/${LAST_RUN_REL}" 2>/dev/null || true
}

# Derive parent_group for a repo. If group_override is non-empty, use it.
# Otherwise, take the basename of the parent directory of the repo path.
derive_parent_group() {
    local repo="$1" group_override="$2"
    if [[ -n "$group_override" ]]; then
        printf '%s' "$group_override"
        return 0
    fi
    local parent
    parent="$(dirname "$repo")"
    basename "$parent"
}

# POST the freshly-scanned graph.json to the viewer API.
# Echoes a JSON object describing the push outcome:
#   {attempted, status:"success"|"skipped"|"failed", reason, http_status, duration_seconds}
# Always returns 0; never aborts the scan.
push_graph() {
    local repo="$1" group_override="$2"
    local graph="${repo}/${GRAPH_REL}"

    if [[ ! -f "$graph" ]]; then
        jq -n '{attempted:false, status:"skipped", reason:"no graph.json", http_status:null, duration_seconds:0}'
        return 0
    fi
    if [[ ! -f "$VIEWER_API_KEY_FILE" ]]; then
        jq -n '{attempted:false, status:"skipped", reason:"no api key", http_status:null, duration_seconds:0}'
        return 0
    fi
    if [[ ! -f "$VIEWER_URL_FILE" ]]; then
        jq -n '{attempted:false, status:"skipped", reason:"no viewer url", http_status:null, duration_seconds:0}'
        return 0
    fi

    local api_key viewer_url
    api_key="$(tr -d '\n\r' < "$VIEWER_API_KEY_FILE")"
    viewer_url="$(tr -d '\n\r' < "$VIEWER_URL_FILE")"

    local repo_name parent_group
    repo_name="$(basename "$repo")"
    parent_group="$(derive_parent_group "$repo" "$group_override")"

    # Build payload: {repo_name, parent_group, graph: <contents of graph.json>}
    local payload_file="${repo}/.understand/.push-payload.json"
    if ! jq -n \
        --arg repo_name "$repo_name" \
        --arg parent_group "$parent_group" \
        --slurpfile graph "$graph" \
        '{repo_name:$repo_name, parent_group:$parent_group, graph:$graph[0]}' \
        > "$payload_file" 2>/dev/null; then
        jq -n '{attempted:true, status:"failed", reason:"payload build failed", http_status:null, duration_seconds:0}'
        rm -f "$payload_file" 2>/dev/null || true
        return 0
    fi

    local start end duration http_status curl_status attempt last_status=""
    start=$(date +%s)
    # Header file is created per attempt and removed promptly; trap ensures
    # cleanup even on signal. Mode 600 so other users on the host can't read
    # the API key during the curl process lifetime.
    local header_file=""
    _push_cleanup_header() { [[ -n "${header_file:-}" && -f "${header_file}" ]] && rm -f "${header_file}"; }
    trap _push_cleanup_header EXIT INT TERM
    for attempt in 1 2; do
        header_file=$(mktemp "${TMPDIR:-/tmp}/uau-hdr.XXXXXX")
        chmod 600 "$header_file"
        # printf (not echo) — curl's @file header form treats a trailing newline
        # as an empty header continuation; use no trailing newline.
        printf 'X-API-Key: %s' "$api_key" > "$header_file"
        # `--write-out '%{http_code}'` and `-o /dev/null` to capture status only.
        http_status=$(curl --silent --show-error \
            --connect-timeout 30 --max-time 60 \
            -o /dev/null -w '%{http_code}' \
            -X POST \
            -H "Content-Type: application/json" \
            -H "@${header_file}" \
            --data-binary "@${payload_file}" \
            "$viewer_url" 2>/dev/null)
        curl_status=$?
        rm -f "$header_file" 2>/dev/null || true
        header_file=""
        last_status="$http_status"
        # Success: 2xx
        if [[ "$curl_status" -eq 0 && "$http_status" =~ ^2 ]]; then
            end=$(date +%s); duration=$(( end - start ))
            rm -f "$payload_file" 2>/dev/null || true
            jq -n --argjson hs "$http_status" --argjson d "$duration" \
                '{attempted:true, status:"success", reason:null, http_status:$hs, duration_seconds:$d}'
            return 0
        fi
        # 4xx (non-retryable). curl_status==0 means we got an HTTP response.
        if [[ "$curl_status" -eq 0 && "$http_status" =~ ^4 ]]; then
            end=$(date +%s); duration=$(( end - start ))
            rm -f "$payload_file" 2>/dev/null || true
            jq -n --argjson hs "$http_status" --argjson d "$duration" \
                '{attempted:true, status:"failed", reason:"http 4xx", http_status:$hs, duration_seconds:$d}'
            return 0
        fi
        # Else: 5xx or network error — retry once.
    done

    end=$(date +%s); duration=$(( end - start ))
    rm -f "$payload_file" 2>/dev/null || true
    local hs_json="null"
    [[ "$last_status" =~ ^[0-9]+$ ]] && hs_json="$last_status"
    jq -n --argjson hs "$hs_json" --argjson d "$duration" \
        '{attempted:true, status:"failed", reason:"transient failure after retry", http_status:$hs, duration_seconds:$d}'
    return 0
}

# --- Sections ---

section_check() {
    if [[ -z "$SINGLE_REPO" ]]; then
        exit_with_json "error" "--check requires a repo path"
    fi
    SINGLE_REPO="$(expand_tilde "$SINGLE_REPO")"
    local result
    if ! result=$(evaluate_repo "$SINGLE_REPO"); then
        # evaluate_repo emitted JSON describing the error.
        local msg
        msg=$(jq -r '.reason // "evaluation failed"' <<< "$result")
        local extra
        extra=$(printf '"repo": %s' "$(json_str "$SINGLE_REPO")")
        exit_with_json "error" "${msg}: ${SINGLE_REPO}" "" "$extra"
    fi
    local action reason churn db
    action=$(jq -r '.action' <<< "$result")
    reason=$(jq -r '.reason' <<< "$result")
    churn=$(jq -c '.churn_metrics // {}' <<< "$result")
    db=$(jq -r '.default_branch // ""' <<< "$result")
    local extra
    extra=$(printf '"repo": %s, "action": %s, "reason": %s, "churn_metrics": %s, "default_branch": %s' \
        "$(json_str "$SINGLE_REPO")" \
        "$(json_str "$action")" \
        "$(json_str "$reason")" \
        "$churn" \
        "$(json_str "$db")")
    exit_with_json "success" "check complete" "" "$extra"
}

section_rescan() {
    if [[ -z "$SINGLE_REPO" ]]; then
        exit_with_json "error" "--rescan requires a repo path"
    fi
    SINGLE_REPO="$(expand_tilde "$SINGLE_REPO")"
    if [[ ! -d "$SINGLE_REPO" ]]; then
        exit_with_json "error" "repo path does not exist: ${SINGLE_REPO}"
    fi
    local mode="incremental"
    [[ ! -f "${SINGLE_REPO}/${GRAPH_REL}" ]] && mode="scan"

    local SCAN_STATUS=0 SCAN_DURATION=0 SCAN_OUTPUT=""
    run_scan "$SINGLE_REPO" "$mode"
    local reason="forced rescan"
    local churn='{}'
    local scan_status_label="success"
    [[ "$SCAN_STATUS" -ne 0 ]] && scan_status_label="failed"
    local push_json='null'
    if [[ "$SCAN_STATUS" -eq 0 && "$NO_PUSH" -eq 0 ]]; then
        push_json=$(push_graph "$SINGLE_REPO" "")
    fi
    write_last_run "$SINGLE_REPO" "rescan" "$reason" "$churn" "$scan_status_label" "$SCAN_DURATION" "$push_json"

    local extra
    extra=$(printf '"repo": %s, "action": "rescan", "reason": %s, "scan_status": %s, "scan_duration_seconds": %s, "scan_mode": %s' \
        "$(json_str "$SINGLE_REPO")" \
        "$(json_str "$reason")" \
        "$(json_str "$scan_status_label")" \
        "$SCAN_DURATION" \
        "$(json_str "$mode")")
    if [[ "$SCAN_STATUS" -eq 0 ]]; then
        exit_with_json "success" "rescan complete" "" "$extra"
    else
        exit_with_json "error" "rescan failed" "$SCAN_OUTPUT" "$extra"
    fi
}

section_full() {
    if [[ ! -f "$WATCHLIST" ]]; then
        # Missing watchlist == empty walk, not an error (first-run friendly).
        local extra
        extra='"repos": [], "summary": {"scanned": 0, "skipped": 0, "errored": 0, "total": 0}, "watchlist": '"$(json_str "$WATCHLIST")"
        exit_with_json "success" "watchlist not present; nothing to do" "" "$extra"
    fi

    local repos_json='[]'
    local scanned=0 skipped=0 errored=0 total=0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if ! parse_watchlist_line "$line"; then
            continue
        fi
        local repo="$LINE_PATH"
        local group="$LINE_GROUP"
        total=$((total + 1))

        local eval_json
        if ! eval_json=$(evaluate_repo "$repo"); then
            errored=$((errored + 1))
            local err_entry
            err_entry=$(jq -n --arg r "$repo" --arg g "$group" --argjson e "$eval_json" \
                '{repo:$r, group:$g, action:"error", reason:$e.reason}')
            repos_json=$(jq --argjson e "$err_entry" '. + [$e]' <<< "$repos_json")
            continue
        fi

        local action reason churn
        action=$(jq -r '.action' <<< "$eval_json")
        reason=$(jq -r '.reason' <<< "$eval_json")
        churn=$(jq -c '.churn_metrics // {}' <<< "$eval_json")

        local scan_status_label="not_run"
        local scan_duration=0
        if [[ "$action" == "rescan" ]]; then
            local mode="incremental"
            [[ ! -f "${repo}/${GRAPH_REL}" ]] && mode="scan"
            local SCAN_STATUS=0 SCAN_DURATION=0 SCAN_OUTPUT=""
            run_scan "$repo" "$mode"
            scan_duration="$SCAN_DURATION"
            if [[ "$SCAN_STATUS" -eq 0 ]]; then
                scan_status_label="success"
                scanned=$((scanned + 1))
            else
                scan_status_label="failed"
                errored=$((errored + 1))
            fi
            local push_json='null'
            if [[ "$SCAN_STATUS" -eq 0 && "$NO_PUSH" -eq 0 ]]; then
                push_json=$(push_graph "$repo" "$group")
            fi
            write_last_run "$repo" "$action" "$reason" "$churn" "$scan_status_label" "$scan_duration" "$push_json"
        else
            skipped=$((skipped + 1))
        fi

        local entry
        entry=$(jq -n \
            --arg repo "$repo" \
            --arg group "$group" \
            --arg action "$action" \
            --arg reason "$reason" \
            --argjson churn "$churn" \
            --arg scan_status "$scan_status_label" \
            --argjson scan_duration "$scan_duration" \
            '{repo:$repo, group:$group, action:$action, reason:$reason, churn_metrics:$churn, scan_status:$scan_status, scan_duration_seconds:$scan_duration}')
        repos_json=$(jq --argjson e "$entry" '. + [$e]' <<< "$repos_json")
    done < "$WATCHLIST"

    local extra
    extra=$(printf '"repos": %s, "summary": {"scanned": %s, "skipped": %s, "errored": %s, "total": %s}, "watchlist": %s' \
        "$repos_json" "$scanned" "$skipped" "$errored" "$total" \
        "$(json_str "$WATCHLIST")")
    exit_with_json "success" "walk complete: ${scanned} scanned, ${skipped} skipped, ${errored} errored" "" "$extra"
}

section_push_only() {
    if [[ -z "$SINGLE_REPO" ]]; then
        exit_with_json "error" "--push-only requires a repo path"
    fi
    SINGLE_REPO="$(expand_tilde "$SINGLE_REPO")"
    if [[ ! -d "$SINGLE_REPO" ]]; then
        exit_with_json "error" "repo path does not exist: ${SINGLE_REPO}"
    fi
    local push_json
    push_json=$(push_graph "$SINGLE_REPO" "$PUSH_ONLY_GROUP")
    local status_label reason hs duration
    status_label=$(jq -r '.status' <<< "$push_json")
    local extra
    extra=$(printf '"repo": %s, "action": "push_only", "push": %s' \
        "$(json_str "$SINGLE_REPO")" "$push_json")
    if [[ "$status_label" == "failed" ]]; then
        exit_with_json "error" "push failed" "" "$extra"
    else
        exit_with_json "success" "push complete" "" "$extra"
    fi
}

# --- Dispatch ---
case "$SECTION" in
    full)       section_full ;;
    check)      section_check ;;
    rescan)     section_rescan ;;
    push_only)  section_push_only ;;
    *)          exit_with_json "error" "unhandled section: ${SECTION}" ;;
esac
