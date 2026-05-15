#!/usr/bin/env bash
# tdd-precheck.sh — PreToolUse hook for TDD enforcement on Write tool calls.
#
# Per DSN 0C4B72:
#   - Soft-blocks NEW source files when active PLN subtask has tdd_required: yes
#     and no corresponding test file exists.
#   - Edits to existing files are always allowed (Decision 1).
#   - Path-based exclusion list keeps tests/, docs/, configs/, etc. out (Decision 2).
#   - Two bypass mechanisms: TDD_BYPASS=1 env var (one-off) and
#     `<comment-prefix> tdd-bypass: <reason>` first-line sentinel (permanent) (Decision 4).
#   - Block emits structured JSON to stderr (Decision 6).
#   - Every invocation appends one JSONL line to the observability log (Decision 7).
#
# Hook contract (stdin JSON):
#   { "tool_name": "Write", "tool_input": { "file_path": "...", "content": "..." } }
#
# Exit codes:
#   0  → allow (every fail-open path also returns 0)
#   2  → block (Claude Code shows stderr to the agent as feedback)
#
# Fail-open discipline: ANY internal error (parse failure, missing dep, plan-progress
# crash) results in `allow` + log entry + exit 0. Hook must NEVER block its caller
# for the wrong reason.

# Deliberately NO `set -e` — caller controls error handling at every step.
set -u
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load helper libraries — these define is_excluded_path, detect_language,
# get_test_paths, get_comment_prefix, tdd_log, tdd_log_rotate.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/test-file-conventions.sh" 2>/dev/null || {
    # If the library is missing, fail-open silently — there's nothing to log to either.
    exit 0
}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/tdd-log.sh" 2>/dev/null || {
    # No logger → just allow and exit. Don't try to log without the logger.
    exit 0
}

export TDD_HOOK_TOOL="${TDD_HOOK_TOOL:-Write}"

# Plan-progress lookup binary; tests override via env, prod uses the absolute path.
PLAN_PROGRESS_BIN="${TDD_PLAN_PROGRESS_BIN:-${HOME}/.claude/scripts/plan-progress.sh}"

# ─── Helper: emit structured block JSON to stderr ───────────────────────────
emit_block_json() {
    local file="$1" language="$2" subtask="$3"
    local test_paths_json
    # Build expected_test_paths array from get_test_paths newline output
    test_paths_json=$(get_test_paths "$file" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')

    jq -nc \
        --arg file "$file" \
        --arg language "$language" \
        --arg subtask "$subtask" \
        --argjson paths "$test_paths_json" \
        '{
            blocked: true,
            reason: "no_test_for_new_source_file",
            file: $file,
            expected_test_paths: $paths,
            language: $language,
            active_subtask: $subtask,
            bypass: {
                one_off: "Set TDD_BYPASS=1 then retry",
                permanent: "Add `<comment> tdd-bypass: <reason>` as the first line of the file"
            }
        }' >&2 2>/dev/null || {
        # If jq is unavailable, fall back to a hand-rolled minimal JSON
        printf '{"blocked":true,"reason":"no_test_for_new_source_file","file":"%s","language":"%s","active_subtask":"%s"}\n' \
            "$file" "$language" "$subtask" >&2
    }
}

# ─── Helper: extract subtask context from plan-progress.sh ───────────────────
# Echoes "<subtask_label>|<tdd_required>" or empty on failure.
get_active_subtask_context() {
    [[ -x "$PLAN_PROGRESS_BIN" ]] || return 1
    local out subtask tdd_req
    out=$("$PLAN_PROGRESS_BIN" --json 2>/dev/null) || return 1
    [[ -z "$out" ]] && return 1
    subtask=$(echo "$out" | jq -r '.current_subtask // empty' 2>/dev/null) || return 1
    tdd_req=$(echo "$out" | jq -r '.next_task_config.tdd_required // empty' 2>/dev/null) || return 1
    [[ -z "$subtask" ]] && return 1
    echo "${subtask}|${tdd_req}"
}

# ─── Helper: check sentinel comment in content ───────────────────────────────
# Returns 0 if the first line of $1 (content) matches `<prefix> tdd-bypass: <reason>`
# for the file's language. Echoes the reason on success.
check_sentinel() {
    local content="$1" file="$2"
    local prefix first_line
    prefix=$(get_comment_prefix "$file")
    # First line only
    first_line="${content%%$'\n'*}"
    # Pattern: <prefix> tdd-bypass: <non-empty reason>
    # Allow optional whitespace around tdd-bypass: marker
    local pattern="^[[:space:]]*${prefix}[[:space:]]+tdd-bypass:[[:space:]]+(.+)$"
    if [[ "$first_line" =~ $pattern ]]; then
        # Reason captured; treat as bypass if non-empty after trimming
        local reason="${BASH_REMATCH[1]}"
        # Strip trailing whitespace and any closing comment marker (e.g. -->)
        reason="${reason%-->}"
        reason="${reason%"${reason##*[![:space:]]}"}"
        [[ -n "$reason" ]] || return 1
        echo "$reason"
        return 0
    fi
    return 1
}

# ─── Decision tree ──────────────────────────────────────────────────────────

# Step 1: Read + parse stdin JSON.
STDIN_RAW=$(cat 2>/dev/null) || STDIN_RAW=""
if [[ -z "$STDIN_RAW" ]]; then
    tdd_log "allow" "parse_error" "" "" "false"
    exit 0
fi

if ! echo "$STDIN_RAW" | jq empty 2>/dev/null; then
    tdd_log "allow" "parse_error" "" "" "false"
    exit 0
fi

TOOL_NAME=$(echo "$STDIN_RAW" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$STDIN_RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
CONTENT=$(echo "$STDIN_RAW" | jq -r '.tool_input.content // ""' 2>/dev/null)

# Step 2: Wrong tool → allow
if [[ "$TOOL_NAME" != "Write" ]]; then
    tdd_log "allow" "wrong_tool" "$FILE_PATH" "" "false"
    exit 0
fi

# Step 3: No active task → allow
if [[ ! -f .current-task ]]; then
    tdd_log "allow" "no_active_task" "$FILE_PATH" "" "false"
    exit 0
fi

# Step 4: No PROJECT.yaml → allow
if [[ ! -f PROJECT.yaml ]]; then
    tdd_log "allow" "no_project_yaml" "$FILE_PATH" "" "false"
    exit 0
fi

# Step 5: Resolve subtask via plan-progress.sh; if tdd_required != yes → allow
SUBTASK_CTX=$(get_active_subtask_context)
if [[ -z "$SUBTASK_CTX" ]]; then
    tdd_log "allow" "no_pln_state" "$FILE_PATH" "" "false"
    exit 0
fi
SUBTASK_LABEL="${SUBTASK_CTX%|*}"
SUBTASK_TDD="${SUBTASK_CTX#*|}"

if [[ "$SUBTASK_TDD" != "yes" ]]; then
    tdd_log "allow" "tdd_not_required" "$FILE_PATH" "$SUBTASK_LABEL" "false"
    exit 0
fi

# Step 6: Missing file_path → allow
if [[ -z "$FILE_PATH" ]]; then
    tdd_log "allow" "no_file_path" "" "$SUBTASK_LABEL" "true"
    exit 0
fi

# Step 7: File already exists → allow (Decision 1: refactor handling)
if [[ -e "$FILE_PATH" ]]; then
    tdd_log "allow" "file_exists" "$FILE_PATH" "$SUBTASK_LABEL" "true"
    exit 0
fi

# Step 8: Excluded path → allow (Decision 2)
if is_excluded_path "$FILE_PATH"; then
    tdd_log "allow" "path_excluded" "$FILE_PATH" "$SUBTASK_LABEL" "true"
    exit 0
fi

# Step 9: TDD_BYPASS env var → allow (Decision 4a)
if [[ "${TDD_BYPASS:-}" == "1" ]]; then
    tdd_log "allow" "bypass_env" "$FILE_PATH" "$SUBTASK_LABEL" "true"
    exit 0
fi

# Step 10: Sentinel comment in content → allow (Decision 4b)
if SENTINEL_REASON=$(check_sentinel "$CONTENT" "$FILE_PATH"); then
    tdd_log "allow" "bypass_sentinel" "$FILE_PATH" "$SUBTASK_LABEL" "true"
    exit 0
fi

# Step 11: Any candidate test path exists → allow
LANG=$(detect_language "$FILE_PATH")
TEST_FOUND=false
while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if [[ -e "$candidate" ]]; then
        TEST_FOUND=true
        break
    fi
done < <(get_test_paths "$FILE_PATH" 2>/dev/null)

if [[ "$TEST_FOUND" == "true" ]]; then
    tdd_log "allow" "test_exists" "$FILE_PATH" "$SUBTASK_LABEL" "true"
    exit 0
fi

# Step 12: Block — emit structured JSON to stderr, log, exit 2
emit_block_json "$FILE_PATH" "$LANG" "$SUBTASK_LABEL"
tdd_log "block" "no_test_for_new_source_file" "$FILE_PATH" "$SUBTASK_LABEL" "true"
exit 2
