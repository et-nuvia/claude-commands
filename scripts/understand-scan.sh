#!/usr/bin/env bash
# understand-scan.sh — orchestrator for the /understand-scan multi-agent pipeline.
#
# Pure deterministic shell scaffolding. Does NOT call LLMs and NEVER reads
# file contents for analysis (subagents do that). Reads only paths, sizes,
# hashes, and configuration.
#
# Sections:
#   --scan         Enumerate source files in cwd, respecting .gitignore.
#   --incremental  Like --scan, but only files whose hash differs from
#                  the existing .understand/graph.json meta.file_hashes.
#   --assemble     Validate aggregated subagent results against the graph
#                  schema and (on success) write .understand/graph.json.
#   --validate     Validate an existing graph against the schema. No write.
#   --full         Emit the orchestration plan; the command layer dispatches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status mapping (defined BEFORE sourcing output-framework).
map_status_to_action() {
    case "$1" in
        success)             echo "display_summary" ;;
        requires_subagents)  echo "dispatch_file_analyzers" ;;
        ready_to_assemble)   echo "dispatch_file_analyzers" ;;
        assemble_failed)     echo "retry_assemble" ;;
        scan_in_progress)    echo "scan_in_progress" ;;
        *)                   _default_map_status_to_action "$1" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# --- Config defaults ---
DEFAULT_MAX_FILE_SIZE_KB=500
DEFAULT_COST_CEILING_USD=5
GRAPH_DIR=".understand"
GRAPH_FILE="${GRAPH_DIR}/graph.json"
CONFIG_FILE="${GRAPH_DIR}/config.json"
LOCK_FILE="${GRAPH_DIR}/scan.lock"
SCHEMA_PATH_REL="schemas/understand-graph.schema.json"

# Acquire a PID-file lock to prevent concurrent scan/assemble writes from
# clobbering each other. Stale locks (PID no longer alive) are reclaimed.
LOCK_HELD=0
acquire_scan_lock() {
    mkdir -p "$GRAPH_DIR"
    if [[ -f "$LOCK_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            local extra
            extra=$(printf '"running_pid": %s, "lock_file": %s' \
                "$(jq -Rs . <<< "$existing_pid")" \
                "$(jq -Rs . <<< "$LOCK_FILE")")
            exit_with_json "scan_in_progress" "another scan is in progress (pid ${existing_pid} holds ${LOCK_FILE})" "" "$extra"
        fi
        # Stale lock — reclaim.
    fi
    printf '%s\n' "$$" > "$LOCK_FILE"
    LOCK_HELD=1
    trap release_scan_lock EXIT INT TERM
}

release_scan_lock() {
    if [[ "$LOCK_HELD" -eq 1 ]]; then
        rm -f "$LOCK_FILE"
        LOCK_HELD=0
    fi
}

# --- Flag parsing ---
OUTPUT_MODE="json"
SECTION=""
RESULTS_FILE=""
GRAPH_FILE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)         OUTPUT_MODE="json"; shift ;;
        --raw)          OUTPUT_MODE="raw"; shift ;;
        --scan)         SECTION="scan"; shift ;;
        --incremental)  SECTION="incremental"; shift ;;
        --assemble)     SECTION="assemble"; shift ;;
        --validate)     SECTION="validate"; shift ;;
        --full)         SECTION="full"; shift ;;
        --results-file) RESULTS_FILE="$2"; shift 2 ;;
        --graph-file)   GRAPH_FILE_OVERRIDE="$2"; shift 2 ;;
        *)
            exit_with_json "error" "unknown flag: $1"
            ;;
    esac
done

if [[ -z "$SECTION" ]]; then
    SECTION="full"
fi

# --- Helpers ---

# Resolve the schema file relative to the worktree root (cwd-independent).
locate_schema() {
    # The script always lives in <repo>/scripts; schema lives in <repo>/schemas.
    local candidate="${SCRIPT_DIR}/../${SCHEMA_PATH_REL}"
    if [[ -f "$candidate" ]]; then
        local dir
        dir=$(cd "$(dirname "$candidate")" && pwd)
        echo "${dir}/$(basename "$candidate")"
    else
        # Fallback: search up from cwd.
        local d="$PWD"
        while [[ "$d" != "/" ]]; do
            if [[ -f "$d/${SCHEMA_PATH_REL}" ]]; then
                echo "$d/${SCHEMA_PATH_REL}"
                return 0
            fi
            d="$(dirname "$d")"
        done
        return 1
    fi
}

# Load max_file_size_kb / exclude_globs / cost_ceiling_usd from .understand/config.json.
load_config() {
    MAX_FILE_SIZE_KB="$DEFAULT_MAX_FILE_SIZE_KB"
    COST_CEILING_USD="$DEFAULT_COST_CEILING_USD"
    EXCLUDE_GLOBS=()
    if [[ -f "$CONFIG_FILE" ]]; then
        local v
        v=$(jq -r '.max_file_size_kb // empty' "$CONFIG_FILE" 2>/dev/null || true)
        [[ -n "$v" ]] && MAX_FILE_SIZE_KB="$v"
        v=$(jq -r '.cost_ceiling_usd // empty' "$CONFIG_FILE" 2>/dev/null || true)
        [[ -n "$v" ]] && COST_CEILING_USD="$v"
        # exclude_globs as newline-separated list
        local globs_raw
        globs_raw=$(jq -r '(.exclude_globs // []) | .[]' "$CONFIG_FILE" 2>/dev/null || true)
        if [[ -n "$globs_raw" ]]; then
            while IFS= read -r g; do
                [[ -n "$g" ]] && EXCLUDE_GLOBS+=("$g")
            done <<< "$globs_raw"
        fi
    fi
}

# Guess a coarse language label from file extension.
guess_language() {
    local path="$1"
    case "${path,,}" in
        *.ts|*.tsx)     echo "typescript" ;;
        *.js|*.jsx|*.mjs|*.cjs) echo "javascript" ;;
        *.py)           echo "python" ;;
        *.rs)           echo "rust" ;;
        *.go)           echo "go" ;;
        *.rb)           echo "ruby" ;;
        *.java)         echo "java" ;;
        *.kt|*.kts)     echo "kotlin" ;;
        *.sh|*.bash)    echo "bash" ;;
        *.c|*.h)        echo "c" ;;
        *.cpp|*.cc|*.cxx|*.hpp|*.hh) echo "cpp" ;;
        *.json)         echo "json" ;;
        *.yaml|*.yml)   echo "yaml" ;;
        *.md|*.markdown) echo "markdown" ;;
        *.toml)         echo "toml" ;;
        *)              echo "other" ;;
    esac
}

# Match a relative path against the glob list. Uses bash extglob.
matches_any_glob() {
    local path="$1"
    shift
    local g
    shopt -s extglob globstar nullglob 2>/dev/null || true
    for g in "$@"; do
        # shellcheck disable=SC2053
        if [[ "$path" == $g ]]; then
            return 0
        fi
    done
    return 1
}

# Enumerate candidate files (gitignore-respecting if in a git repo).
list_candidate_files() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Tracked + untracked-not-ignored, excluding deleted.
        # Always exclude .understand/** — it holds the graph + lock + config,
        # not source code, and the lock file changes mid-scan.
        git ls-files --cached --others --exclude-standard | grep -Ev '^\.understand(/|$)' || true
    else
        # Fallback walk; skip dot-dirs and common heavy dirs.
        find . -type f \
            -not -path '*/.git/*' \
            -not -path '*/.understand/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/.venv/*' \
            -not -path '*/dist/*' \
            -not -path '*/build/*' \
            -printf '%P\n'
    fi
}

# Build the file_list JSON array. Skips files larger than the cap and any
# matching configured exclude_globs.
build_file_list() {
    local tmp
    tmp=$(mktemp)
    local path size hash lang hash_raw
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ ! -f "$path" ]] && continue
        if (( ${#EXCLUDE_GLOBS[@]} > 0 )) && matches_any_glob "$path" "${EXCLUDE_GLOBS[@]}"; then
            continue
        fi
        # Skip unreadable files: a stat failure means we cannot determine size
        # truthfully — better to omit than to record size=0 silently.
        if ! size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null); then
            log "stat failed for ${path}; skipping"
            continue
        fi
        if [[ -z "$size" ]]; then
            log "stat returned empty for ${path}; skipping"
            continue
        fi
        if (( size > MAX_FILE_SIZE_KB * 1024 )); then
            continue
        fi
        if ! hash_raw=$(sha256sum "$path" 2>/dev/null | awk '{print $1}'); then
            log "sha256 failed for ${path}; skipping"
            continue
        fi
        hash="sha256:${hash_raw}"
        lang=$(guess_language "$path")
        printf '%s\t%s\t%s\t%s\n' "$path" "$size" "$hash" "$lang" >> "$tmp"
    done < <(list_candidate_files)
    # Single jq pass: read tab-delimited lines, emit JSON array.
    local arr
    arr=$(jq -Rsn '
        [ inputs
          | split("\n")
          | map(select(length > 0))
          | .[]
          | split("\t")
          | {path: .[0], size: (.[1] | tonumber), hash: .[2], language: .[3]} ]
    ' < "$tmp")
    rm -f "$tmp"
    printf '%s' "$arr"
}

# Get existing graph file_hashes (jq map). Empty object if missing/invalid.
existing_file_hashes() {
    if [[ -f "$GRAPH_FILE" ]]; then
        jq -c '.meta.file_hashes // {}' "$GRAPH_FILE" 2>/dev/null || printf '{}'
    else
        printf '{}'
    fi
}

# --- Section implementations ---

section_scan() {
    acquire_scan_lock
    load_config
    local file_list
    file_list=$(build_file_list)
    local count
    count=$(jq 'length' <<< "$file_list")
    local extra
    extra=$(printf '"file_list": %s, "count": %s' "$file_list" "$count")
    exit_with_json "requires_subagents" "Scanned ${count} files; dispatch analyzers." "" "$extra"
}

section_incremental() {
    acquire_scan_lock
    load_config
    local file_list
    file_list=$(build_file_list)
    local prior
    prior=$(existing_file_hashes)
    # Filter: keep entries where prior[path] != hash.
    local changed
    changed=$(jq -c --argjson prior "$prior" '
        map(select(($prior[.path] // "") != .hash))
    ' <<< "$file_list")
    local count
    count=$(jq 'length' <<< "$changed")
    local extra
    extra=$(printf '"file_list": %s, "count": %s, "incremental": true' "$changed" "$count")
    exit_with_json "requires_subagents" "Incremental scan: ${count} changed files." "" "$extra"
}

section_validate() {
    local target="${GRAPH_FILE_OVERRIDE:-$GRAPH_FILE}"
    if [[ ! -f "$target" ]]; then
        exit_with_json "error" "graph file not found: ${target}"
    fi
    local schema
    schema=$(locate_schema) || exit_with_json "error" "schema not found"
    local ajv_err
    if ajv_err=$(ajv validate -s "$schema" -d "$target" -c ajv-formats --spec=draft2020 2>&1); then
        exit_with_json "success" "graph validates against schema" "" \
            "$(printf '"graph": %s' "$(jq -Rs . <<< "$target")")"
    else
        local extra
        extra=$(printf '"ajv_error": %s' "$(jq -Rs . <<< "$ajv_err")")
        exit_with_json "error" "graph failed schema validation" "$ajv_err" "$extra"
    fi
}

section_assemble() {
    acquire_scan_lock
    if [[ -z "$RESULTS_FILE" ]]; then
        exit_with_json "error" "--assemble requires --results-file <path>"
    fi
    if [[ ! -f "$RESULTS_FILE" ]]; then
        exit_with_json "error" "results file not found: ${RESULTS_FILE}"
    fi
    # JSON well-formedness first (ajv would also catch, but this gives a cleaner error).
    if ! jq -e . "$RESULTS_FILE" >/dev/null 2>&1; then
        exit_with_json "assemble_failed" "results file is not valid JSON"
    fi
    local schema
    schema=$(locate_schema) || exit_with_json "error" "schema not found"
    # Validate the staged file BEFORE writing graph.json.
    local ajv_err
    if ! ajv_err=$(ajv validate -s "$schema" -d "$RESULTS_FILE" -c ajv-formats --spec=draft2020 2>&1); then
        local extra
        extra=$(printf '"ajv_error": %s' "$(jq -Rs . <<< "$ajv_err")")
        exit_with_json "assemble_failed" "assembled graph failed schema validation" "$ajv_err" "$extra"
    fi
    # Edge integrity: every edge.from / edge.to must reference a known node id.
    # ajv's schema can't express this cross-reference, so check it here.
    local dangling
    dangling=$(jq -c '
        (.nodes | map(.id) | unique) as $ids
        | .edges
        | to_entries
        | map(select((.value.from as $f | $ids | index($f) | not)
                  or (.value.to   as $t | $ids | index($t) | not)))
        | .[0:5]
        | map({index: .key, from: .value.from, to: .value.to, kind: .value.kind})
    ' "$RESULTS_FILE")
    if [[ "$dangling" != "[]" ]]; then
        local extra
        extra=$(printf '"dangling_edges": %s' "$dangling")
        exit_with_json "assemble_failed" "assembled graph has dangling edge endpoints (first 5 shown)" "" "$extra"
    fi
    mkdir -p "$GRAPH_DIR"
    cp "$RESULTS_FILE" "$GRAPH_FILE"
    exit_with_json "success" "graph.json written" "" \
        "$(printf '"graph_path": "%s"' "$GRAPH_FILE")"
}

section_full() {
    load_config
    # Detect mode: incremental if a prior graph exists, else full scan.
    local mode="scan"
    [[ -f "$GRAPH_FILE" ]] && mode="incremental"
    local plan
    plan=$(jq -n --arg mode "$mode" --argjson cost_ceiling "$COST_CEILING_USD" --argjson max_kb "$MAX_FILE_SIZE_KB" '
        {
            steps: [
                {step: "scan",     run: "understand-scan.sh --json --\($mode)"},
                {step: "analyze",  run: "dispatch per-file subagents (command layer)"},
                {step: "assemble", run: "understand-scan.sh --json --assemble --results-file <staged>"},
                {step: "validate", run: "understand-scan.sh --json --validate"}
            ],
            mode: $mode,
            cost_ceiling_usd: $cost_ceiling,
            max_file_size_kb: $max_kb
        }
    ')
    local extra
    extra=$(printf '"plan": %s' "$plan")
    exit_with_json "requires_subagents" "Pipeline plan ready; command layer must dispatch subagents." "" "$extra"
}

# --- Main ---
case "$SECTION" in
    scan)        section_scan ;;
    incremental) section_incremental ;;
    assemble)    section_assemble ;;
    validate)    section_validate ;;
    full)        section_full ;;
    *)           exit_with_json "error" "unhandled section: ${SECTION}" ;;
esac
