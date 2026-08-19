#!/usr/bin/env bash
# understand-scan.sh — orchestrator for the /understand-scan multi-agent pipeline.
#
# Pure deterministic shell scaffolding. Does NOT call LLMs and NEVER reads
# file contents for analysis (subagents do that). Reads only paths, sizes,
# hashes, and configuration.
#
# Sections:
#   --scan         Enumerate source files in cwd, respecting .gitignore.
#                  Also bundles commit_sha, PROJECT-KNOWLEDGE excerpt, config,
#                  and tracking session id so the orchestrator does not need
#                  one-off Bash calls for them.
#   --incremental  Like --scan, but only files whose hash differs from
#                  the existing .understand/graph.json meta.file_hashes.
#   --read-files   Read content of multiple paths in one call. Takes
#                  --paths-file <json> (a JSON array of relative paths) and
#                  emits {files: [{path, hash, content}]}. Lets the
#                  orchestrator batch file reads for the analyzer stage.
#   --assemble     Validate aggregated subagent results against the graph
#                  schema and (on success) write .understand/graph.json.
#   --validate     Validate an existing graph against the schema. No write.
#   --full         Emit the orchestration plan AND the same bundle as --scan
#                  so the orchestrator can start without a second call.

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
PATHS_FILE=""
SCANNER_FILE=""
BUNDLE_FILE=""
OUT_DIR=""
OUTPUTS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)         OUTPUT_MODE="json"; shift ;;
        --raw)          OUTPUT_MODE="raw"; shift ;;
        --scan)         SECTION="scan"; shift ;;
        --incremental)  SECTION="incremental"; shift ;;
        --assemble)     SECTION="assemble"; shift ;;
        --validate)     SECTION="validate"; shift ;;
        --full)         SECTION="full"; shift ;;
        --read-files)   SECTION="read_files"; shift ;;
        --prepare-analyzer-inputs) SECTION="prepare_analyzer_inputs"; shift ;;
        --bundle-analyzer-results) SECTION="bundle_analyzer_results"; shift ;;
        --outputs-dir)  OUTPUTS_DIR="$2"; shift 2 ;;
        --scanner-file) SCANNER_FILE="$2"; shift 2 ;;
        --bundle-file)  BUNDLE_FILE="$2"; shift 2 ;;
        --out-dir)      OUT_DIR="$2"; shift 2 ;;
        --results-file) RESULTS_FILE="$2"; shift 2 ;;
        --paths-file)   PATHS_FILE="$2"; shift 2 ;;
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

# Collect orchestration bundle: commit_sha, PK excerpt, config knobs,
# tracking session id, cwd. Emitted once at scan time so the orchestrator
# does not need separate Bash/Read calls for any of this.
PK_EXCERPT_BYTES=2048
PK_CANDIDATE_PATHS=(
    "docs/architecture/PROJECT-KNOWLEDGE.md"
    "PROJECT-KNOWLEDGE.md"
    "docs/PROJECT-KNOWLEDGE.md"
)

build_bundle_json() {
    local commit_sha=""
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        commit_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "")
    fi
    local pk_path="" pk_excerpt=""
    local p
    for p in "${PK_CANDIDATE_PATHS[@]}"; do
        if [[ -f "$p" ]]; then
            pk_path="$p"
            pk_excerpt=$(head -c "$PK_EXCERPT_BYTES" "$p" 2>/dev/null || true)
            break
        fi
    done
    local session_id=""
    if [[ -x "${HOME}/.claude/scripts/track-command.sh" ]]; then
        # Capture stderr (where track-command emits its session line) and
        # extract the session id; never fail the scan if tracking is broken.
        local track_out
        track_out=$("${HOME}/.claude/scripts/track-command.sh" \
            --command "understand-scan" --event start 2>&1 || true)
        session_id=$(printf '%s' "$track_out" \
            | sed -nE 's/.*session=([A-Za-z0-9_-]+).*/\1/p' \
            | head -n1)
    fi
    local cwd
    cwd="$PWD"
    jq -n \
        --arg commit_sha "$commit_sha" \
        --arg pk_path "$pk_path" \
        --arg pk_excerpt "$pk_excerpt" \
        --arg session_id "$session_id" \
        --arg cwd "$cwd" \
        --argjson max_kb "$MAX_FILE_SIZE_KB" \
        --argjson cost_ceiling "$COST_CEILING_USD" \
        '{
            cwd: $cwd,
            commit_sha: $commit_sha,
            project_knowledge: {path: $pk_path, excerpt: $pk_excerpt},
            tracking_session_id: $session_id,
            config: {max_file_size_kb: $max_kb, cost_ceiling_usd: $cost_ceiling}
         }'
}

# Read content of a batch of paths in a single invocation.
section_read_files() {
    if [[ -z "$PATHS_FILE" ]]; then
        exit_with_json "error" "--read-files requires --paths-file <json>"
    fi
    if [[ ! -f "$PATHS_FILE" ]]; then
        exit_with_json "error" "paths file not found: ${PATHS_FILE}"
    fi
    if ! jq -e 'type == "array"' "$PATHS_FILE" >/dev/null 2>&1; then
        exit_with_json "error" "paths file must be a JSON array of strings"
    fi
    load_config
    local out
    out=$(mktemp)
    printf '[' > "$out"
    local first=1
    local path size hash_raw content_b64
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if [[ ! -f "$path" ]]; then
            continue
        fi
        if ! size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null); then
            continue
        fi
        if (( size > MAX_FILE_SIZE_KB * 1024 )); then
            continue
        fi
        if ! hash_raw=$(sha256sum "$path" 2>/dev/null | awk '{print $1}'); then
            continue
        fi
        # Use base64 to round-trip arbitrary bytes safely through jq.
        if ! content_b64=$(base64 < "$path" 2>/dev/null | tr -d '\n'); then
            continue
        fi
        if [[ $first -eq 0 ]]; then
            printf ',' >> "$out"
        fi
        first=0
        jq -n --arg p "$path" --arg h "sha256:${hash_raw}" --arg b "$content_b64" --argjson s "$size" \
            '{path: $p, hash: $h, size: $s, content_base64: $b}' >> "$out"
    done < <(jq -r '.[]' "$PATHS_FILE")
    printf ']' >> "$out"
    local files_json count
    files_json=$(cat "$out")
    count=$(jq 'length' <<< "$files_json")
    rm -f "$out"
    local extra
    extra=$(printf '"files": %s, "count": %s' "$files_json" "$count")
    exit_with_json "success" "Read ${count} files." "" "$extra"
}

# Materialize one input JSON per tier1/tier2 file containing everything a
# file-analyzer subagent needs: path, base64 content, hash, role, layer_hint,
# project_knowledge_excerpt. Orchestrator dispatches one Agent per file using
# the materialized input path.
section_prepare_analyzer_inputs() {
    if [[ -z "$SCANNER_FILE" || ! -f "$SCANNER_FILE" ]]; then
        exit_with_json "error" "--prepare-analyzer-inputs requires --scanner-file <path>"
    fi
    if [[ -z "$BUNDLE_FILE" || ! -f "$BUNDLE_FILE" ]]; then
        exit_with_json "error" "--prepare-analyzer-inputs requires --bundle-file <path>"
    fi
    local out_dir="${OUT_DIR:-/tmp/uscan_analyzer_inputs}"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"
    load_config

    local pk_excerpt
    pk_excerpt=$(jq -r '.bundle.project_knowledge.excerpt // ""' "$BUNDLE_FILE")
    local commit_sha
    commit_sha=$(jq -r '.bundle.commit_sha // ""' "$BUNDLE_FILE")

    # Build a {path: {size, hash, language}} map from the bundle for fast lookup.
    local file_meta
    file_meta=$(jq -c '
        .file_list
        | map({(.path): {size: .size, hash: .hash, language: .language}})
        | add // {}
    ' "$BUNDLE_FILE")

    # Walk tier1+tier2 entries from the scanner output.
    local idx=0 written=0 skipped=0
    local manifest
    manifest=$(mktemp)
    printf '[' > "$manifest"
    local first=1

    while IFS=$'\t' read -r path role tier layer_hint; do
        [[ -z "$path" ]] && continue
        [[ "$tier" != "tier1" && "$tier" != "tier2" ]] && continue
        if [[ ! -f "$path" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        local size hash_raw
        if ! size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null); then
            skipped=$((skipped + 1))
            continue
        fi
        if (( size > MAX_FILE_SIZE_KB * 1024 )); then
            skipped=$((skipped + 1))
            continue
        fi
        if ! hash_raw=$(sha256sum "$path" 2>/dev/null | awk '{print $1}'); then
            skipped=$((skipped + 1))
            continue
        fi
        local content_b64
        if ! content_b64=$(base64 < "$path" 2>/dev/null | tr -d '\n'); then
            skipped=$((skipped + 1))
            continue
        fi
        local out_path
        out_path="${out_dir}/input_$(printf '%04d' "$idx").json"
        jq -n \
            --arg path "$path" \
            --arg role "$role" \
            --arg tier "$tier" \
            --arg layer_hint "$layer_hint" \
            --arg hash "sha256:${hash_raw}" \
            --argjson size "$size" \
            --arg content_b64 "$content_b64" \
            --arg pk "$pk_excerpt" \
            --arg commit "$commit_sha" \
            '{
                path: $path,
                role: $role,
                tier: $tier,
                layer_hint: $layer_hint,
                file_hash: $hash,
                size: $size,
                content_base64: $content_b64,
                project_knowledge_excerpt: $pk,
                commit_sha: $commit
             }' > "$out_path"
        if [[ $first -eq 0 ]]; then printf ',' >> "$manifest"; fi
        first=0
        jq -n --arg p "$out_path" --arg src "$path" --arg t "$tier" --arg r "$role" \
            '{input_path: $p, source_path: $src, tier: $t, role: $r}' >> "$manifest"
        idx=$((idx + 1))
        written=$((written + 1))
    done < <(jq -r '.file_roles[] | [.path, (.role // ""), (.tier // ""), (.layer_hint // .layer // "")] | @tsv' "$SCANNER_FILE")

    printf ']' >> "$manifest"
    local manifest_json
    manifest_json=$(cat "$manifest")
    rm -f "$manifest"

    local extra
    extra=$(printf '"out_dir": "%s", "written": %s, "skipped": %s, "inputs": %s' \
        "$out_dir" "$written" "$skipped" "$manifest_json")
    exit_with_json "success" "Prepared ${written} analyzer inputs (skipped ${skipped})." "" "$extra"
}

# Aggregate per-file analyzer outputs into a single document the
# architecture-analyzer (and ultimately assemble-reviewer) can consume.
# Produces:
#   {
#     bundle: <bundle from scan>,
#     scanner: {layers, file_roles, stack_notes},
#     analyzer: {file_count, nodes, edges, broken: [{file, error}]},
#     meta: {commit_sha, scanned_at, file_hashes}
#   }
section_bundle_analyzer_results() {
    if [[ -z "$OUTPUTS_DIR" || ! -d "$OUTPUTS_DIR" ]]; then
        exit_with_json "error" "--bundle-analyzer-results requires --outputs-dir <dir>"
    fi
    if [[ -z "$SCANNER_FILE" || ! -f "$SCANNER_FILE" ]]; then
        exit_with_json "error" "--bundle-analyzer-results requires --scanner-file <path>"
    fi
    if [[ -z "$BUNDLE_FILE" || ! -f "$BUNDLE_FILE" ]]; then
        exit_with_json "error" "--bundle-analyzer-results requires --bundle-file <path>"
    fi
    local out
    out=$(mktemp)
    # Iterate output_*.json files, merge nodes/edges. Record broken ones.
    jq -n \
        --slurpfile bundle "$BUNDLE_FILE" \
        --slurpfile scanner "$SCANNER_FILE" \
        --arg outputs_dir "$OUTPUTS_DIR" \
        '{
            bundle: ($bundle[0].bundle // $bundle[0]),
            scanner: $scanner[0],
            file_list: ($bundle[0].file_list // [])
         }' > "$out"

    # Collect nodes + edges via streaming jq over each output file.
    local nodes_tmp edges_tmp broken_tmp
    nodes_tmp=$(mktemp)
    edges_tmp=$(mktemp)
    broken_tmp=$(mktemp)
    printf '[' > "$nodes_tmp"
    printf '[' > "$edges_tmp"
    printf '[' > "$broken_tmp"
    local first_n=1 first_e=1 first_b=1
    local file_count=0
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        file_count=$((file_count + 1))
        if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
            local entry
            entry=$(jq -n --arg fp "$f" --arg err "not a JSON object" '{file: $fp, error: $err}')
            if [[ $first_b -eq 0 ]]; then printf ',' >> "$broken_tmp"; fi
            first_b=0
            printf '%s' "$entry" >> "$broken_tmp"
            continue
        fi
        # Stream nodes
        local nodes_payload edges_payload
        nodes_payload=$(jq -c '.nodes // [] | .[]' "$f" 2>/dev/null || true)
        if [[ -n "$nodes_payload" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ $first_n -eq 0 ]]; then printf ',' >> "$nodes_tmp"; fi
                first_n=0
                printf '%s' "$line" >> "$nodes_tmp"
            done <<< "$nodes_payload"
        fi
        edges_payload=$(jq -c '.edges // [] | .[]' "$f" 2>/dev/null || true)
        if [[ -n "$edges_payload" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ $first_e -eq 0 ]]; then printf ',' >> "$edges_tmp"; fi
                first_e=0
                printf '%s' "$line" >> "$edges_tmp"
            done <<< "$edges_payload"
        fi
    done < <(find "$OUTPUTS_DIR" -maxdepth 1 -type f -name 'output_*.json' | sort)
    printf ']' >> "$nodes_tmp"
    printf ']' >> "$edges_tmp"
    printf ']' >> "$broken_tmp"

    # Build the meta block.
    local commit_sha scanned_at
    commit_sha=$(jq -r '.bundle.commit_sha // ""' "$BUNDLE_FILE")
    scanned_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local file_hashes
    file_hashes=$(jq -c '.file_list | map({(.path): .hash}) | add // {}' "$BUNDLE_FILE")

    # Compose final.
    local final
    final=$(jq -n \
        --slurpfile base "$out" \
        --slurpfile nodes "$nodes_tmp" \
        --slurpfile edges "$edges_tmp" \
        --slurpfile broken "$broken_tmp" \
        --arg commit_sha "$commit_sha" \
        --arg scanned_at "$scanned_at" \
        --argjson file_hashes "$file_hashes" \
        --argjson file_count "$file_count" \
        '$base[0] + {
            analyzer: {
                file_count: $file_count,
                nodes: $nodes[0],
                edges: $edges[0],
                broken: $broken[0]
            },
            meta: {
                commit_sha: $commit_sha,
                scanned_at: $scanned_at,
                file_hashes: $file_hashes
            }
         }')
    rm -f "$out" "$nodes_tmp" "$edges_tmp" "$broken_tmp"
    local node_count edge_count broken_count
    node_count=$(jq '.analyzer.nodes | length' <<< "$final")
    edge_count=$(jq '.analyzer.edges | length' <<< "$final")
    broken_count=$(jq '.analyzer.broken | length' <<< "$final")
    # Write bundled doc to disk so we don't blow the response budget.
    local bundle_path="/tmp/uscan_aggregate.json"
    printf '%s' "$final" > "$bundle_path"
    local extra
    extra=$(printf '"aggregate_path": "%s", "files": %s, "nodes": %s, "edges": %s, "broken": %s' \
        "$bundle_path" "$file_count" "$node_count" "$edge_count" "$broken_count")
    exit_with_json "success" "Aggregated ${file_count} analyzer outputs (${node_count} nodes, ${edge_count} edges, ${broken_count} broken)." "" "$extra"
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
    local bundle
    bundle=$(build_bundle_json)
    local file_list
    file_list=$(build_file_list)
    local count
    count=$(jq 'length' <<< "$file_list")
    local extra
    extra=$(printf '"file_list": %s, "count": %s, "bundle": %s' "$file_list" "$count" "$bundle")
    exit_with_json "requires_subagents" "Scanned ${count} files; dispatch analyzers." "" "$extra"
}

section_incremental() {
    acquire_scan_lock
    load_config
    local bundle
    bundle=$(build_bundle_json)
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
    extra=$(printf '"file_list": %s, "count": %s, "incremental": true, "bundle": %s' "$changed" "$count" "$bundle")
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
    acquire_scan_lock
    load_config
    # Detect mode: incremental if a prior graph exists, else full scan.
    local mode="scan"
    [[ -f "$GRAPH_FILE" ]] && mode="incremental"
    local bundle
    bundle=$(build_bundle_json)
    local file_list
    file_list=$(build_file_list)
    if [[ "$mode" == "incremental" ]]; then
        local prior
        prior=$(existing_file_hashes)
        file_list=$(jq -c --argjson prior "$prior" '
            map(select(($prior[.path] // "") != .hash))
        ' <<< "$file_list")
    fi
    local count
    count=$(jq 'length' <<< "$file_list")
    local plan
    plan=$(jq -n --arg mode "$mode" --argjson cost_ceiling "$COST_CEILING_USD" --argjson max_kb "$MAX_FILE_SIZE_KB" '
        {
            steps: [
                {step: "scan",        run: "(bundled in this response)"},
                {step: "analyze",     run: "dispatch per-file subagents; batch reads via understand-scan.sh --read-files --paths-file <json>"},
                {step: "assemble",    run: "understand-scan.sh --json --assemble --results-file <staged>"},
                {step: "validate",    run: "understand-scan.sh --json --validate"}
            ],
            mode: $mode,
            cost_ceiling_usd: $cost_ceiling,
            max_file_size_kb: $max_kb
        }
    ')
    local extra
    extra=$(printf '"plan": %s, "bundle": %s, "file_list": %s, "count": %s, "mode": "%s"' \
        "$plan" "$bundle" "$file_list" "$count" "$mode")
    exit_with_json "requires_subagents" "Pipeline ready: ${count} files for ${mode}; orchestrator dispatches subagents." "" "$extra"
}

# --- Main ---
case "$SECTION" in
    scan)        section_scan ;;
    incremental) section_incremental ;;
    read_files)  section_read_files ;;
    prepare_analyzer_inputs) section_prepare_analyzer_inputs ;;
    bundle_analyzer_results) section_bundle_analyzer_results ;;
    assemble)    section_assemble ;;
    validate)    section_validate ;;
    full)        section_full ;;
    *)           exit_with_json "error" "unhandled section: ${SECTION}" ;;
esac
