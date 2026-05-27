#!/usr/bin/env bash
# understand-explore.sh — terminal exploration of .understand/graph.json.
#
# Pure shell + jq, no LLM calls. Read-only on the graph.
#
# Sections:
#   --search <query>     Ranked substring match on node id/name/summary.
#   --node <id>          One node + 1-hop neighbors (incoming/outgoing).
#   --tour               Dependency-ordered walk (leaves first), --limit N.
#   --for-task <task_id> Rank nodes by keyword overlap with task TSK/PLN docs.
#   --stats              Graph metadata, counts, layer distribution, staleness.
#
# Loads .understand/graph.json from cwd. --graph-file <path> overrides location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/output-framework.sh"

GRAPH_DIR=".understand"
DEFAULT_GRAPH_FILE="${GRAPH_DIR}/graph.json"
SUPPORTED_SCHEMA_VERSION=1
DEFAULT_TOUR_LIMIT=50
FOR_TASK_LIMIT=20

# English stopwords filtered from task-doc keyword extraction; tunable by
# editing this list. Anchored regex applied per-line.
STOPWORDS_RE='^(this|that|with|from|have|been|will|would|should|could|then|when|what|where|which|while|task|tasks|plan|goal|goals|file|files|section|sections|update|updates|refactor|improve|improvements|pipeline)$'

# --- Flag parsing ---
OUTPUT_MODE="json"
SECTION=""
GRAPH_FILE_OVERRIDE=""
QUERY=""
NODE_ID=""
TASK_ID=""
TASK_DOC=""
TOUR_LIMIT="${DEFAULT_TOUR_LIMIT}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)        OUTPUT_MODE="json"; shift ;;
        --raw)         OUTPUT_MODE="raw"; shift ;;
        --toon)        OUTPUT_MODE="json"; export OUTPUT_FORMAT=toon; shift ;;
        --search)      SECTION="search"; QUERY="${2:-}"; shift 2 ;;
        --node)        SECTION="node"; NODE_ID="${2:-}"; shift 2 ;;
        --tour)        SECTION="tour"; shift ;;
        --for-task)    SECTION="for-task"; TASK_ID="${2:-}"; shift 2 ;;
        --task-doc)    TASK_DOC="${2:-}"; shift 2 ;;
        --stats)       SECTION="stats"; shift ;;
        --limit)       TOUR_LIMIT="${2:-}"; shift 2 ;;
        --graph-file)  GRAPH_FILE_OVERRIDE="${2:-}"; shift 2 ;;
        *)
            exit_with_json "error" "unknown flag: $1"
            ;;
    esac
done

if [[ -z "$SECTION" ]]; then
    exit_with_json "error" "no section specified; use one of --search, --node, --tour, --for-task, --stats"
fi

GRAPH_FILE="${GRAPH_FILE_OVERRIDE:-$DEFAULT_GRAPH_FILE}"

# Parse ISO-8601 UTC timestamp (with or without 'Z') to epoch seconds.
# Tries GNU `date -d` first (Linux), falls back to BSD `date -j -f` (macOS).
parse_iso8601_to_epoch() {
    local ts="$1"
    local epoch
    if epoch=$(date -d "$ts" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi
    # BSD/macOS path. Strip trailing 'Z' (BSD strptime doesn't take it as %Z).
    local stripped="${ts%Z}"
    if epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$stripped" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi
    return 1
}

# --- Graph loading + validation ---

load_graph() {
    if [[ ! -f "$GRAPH_FILE" ]]; then
        exit_with_json "error" "graph file not found at ${GRAPH_FILE}; run /understand-scan to generate it"
    fi
    if ! jq -e . "$GRAPH_FILE" >/dev/null 2>&1; then
        exit_with_json "error" "graph file is not valid JSON: ${GRAPH_FILE}"
    fi
    local v
    v=$(jq -r '.graph_schema_version // empty' "$GRAPH_FILE")
    if [[ "$v" != "$SUPPORTED_SCHEMA_VERSION" ]]; then
        exit_with_json "error" "incompatible graph schema version ${v}; expected ${SUPPORTED_SCHEMA_VERSION}. Re-run /understand-scan to migrate."
    fi
}

# --- Sections ---

section_search() {
    if [[ -z "$QUERY" ]]; then
        exit_with_json "error" "--search requires a query string"
    fi
    local results
    results=$(jq -c --arg q "$QUERY" '
        ($q | ascii_downcase) as $lq
        | [ .nodes[]
            | . as $n
            | (.name // "" | ascii_downcase) as $nm
            | (.id   // "" | ascii_downcase) as $id
            | (.summary // "" | ascii_downcase) as $sm
            | if ($nm | contains($lq))      then {node: $n, score: 3, match_kind: "name"}
              elif ($id | contains($lq))    then {node: $n, score: 2, match_kind: "id"}
              elif ($sm | contains($lq))    then {node: $n, score: 1, match_kind: "summary"}
              else empty
              end
          ]
        | sort_by(-.score)
    ' "$GRAPH_FILE")
    local extra
    extra=$(printf '"results": %s, "query": %s' "$results" "$(jq -Rs . <<< "$QUERY")")
    exit_with_json "success" "search complete" "" "$extra"
}

section_node() {
    if [[ -z "$NODE_ID" ]]; then
        exit_with_json "error" "--node requires a node id"
    fi
    local node_json outgoing_json incoming_json
    node_json=$(jq -c --arg id "$NODE_ID" '.nodes[] | select(.id == $id)' "$GRAPH_FILE")
    if [[ -z "$node_json" ]]; then
        exit_with_json "error" "node not found: ${NODE_ID}"
    fi
    outgoing_json=$(jq -c --arg id "$NODE_ID" '
        (.nodes | map({key: .id, value: .}) | from_entries) as $byid
        | [ .edges[] | select(.from == $id)
            | {node: ($byid[.to] // {id: .to}), kind: .kind} ]
    ' "$GRAPH_FILE")
    incoming_json=$(jq -c --arg id "$NODE_ID" '
        (.nodes | map({key: .id, value: .}) | from_entries) as $byid
        | [ .edges[] | select(.to == $id)
            | {node: ($byid[.from] // {id: .from}), kind: .kind} ]
    ' "$GRAPH_FILE")
    local extra
    extra=$(printf '"node": %s, "outgoing": %s, "incoming": %s' \
        "$node_json" "$outgoing_json" "$incoming_json")
    exit_with_json "success" "node found" "" "$extra"
}

section_tour() {
    # Topological-ish walk: repeatedly pick nodes whose outgoing deps are all visited.
    # Outgoing edges encode "depends on" → leaves (no outgoing) come first.
    local limit="${TOUR_LIMIT}"
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        exit_with_json "error" "--limit must be a non-negative integer"
    fi
    local tour
    tour=$(jq -c --argjson limit "$limit" '
        . as $g
        | ($g.nodes | map({key: .id, value: .}) | from_entries) as $byid
        # out_deps[id] = list of ids this node points to
        | (reduce $g.edges[] as $e ({}; .[$e.from] = ((.[$e.from] // []) + [$e.to]))) as $out
        # Repeatedly select nodes whose unvisited out-deps are empty
        | reduce range(0; $g.nodes | length) as $_ (
            {visited: {}, order: []};
            . as $st
            | ($g.nodes
                | map(select($st.visited[.id] | not))
                | map(select(
                    (($out[.id] // []) | map(select($st.visited[.] | not))) | length == 0
                  ))
              ) as $ready
            | if ($ready | length) == 0
              then
                # Cycle break: pick the first remaining node deterministically.
                ($g.nodes | map(select($st.visited[.id] | not)) | .[0]) as $fallback
                | if $fallback == null then $st
                  else $st
                       | .visited[$fallback.id] = true
                       | .order += [$fallback]
                  end
              else
                # Add all ready nodes in their original order.
                reduce $ready[] as $n (
                    $st;
                    .visited[$n.id] = true | .order += [$n]
                )
              end
          )
        | .order
        | map({id, kind, layer: (.layer // null), summary})
        | if $limit > 0 then .[0:$limit] else . end
    ' "$GRAPH_FILE")
    local count
    count=$(jq 'length' <<< "$tour")
    local extra
    extra=$(printf '"tour": %s, "count": %s, "limit": %s' "$tour" "$count" "$limit")
    exit_with_json "success" "tour generated" "" "$extra"
}

# --- --for-task helpers ---

# Extract keywords from a markdown file: words from # / ## headings and bullet lines
# referencing file paths, lowercased, length >= 4, stopwords removed.
extract_keywords_from_file() {
    local f="$1"
    [[ ! -f "$f" ]] && return 0
    # Lines: headings + bullets (file references)
    grep -E '^(#{1,3} |- |\* )' "$f" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c '[:alnum:]_' '\n' \
        | awk 'length($0) >= 4'
}

section_for_task() {
    if [[ -z "$TASK_ID" ]]; then
        exit_with_json "error" "--for-task requires a task id"
    fi
    # Find TSK + PLN docs. If --task-doc is supplied, use it directly; otherwise
    # search from cwd so the script is not coupled to a fixed absolute layout.
    local tsk_files=() pln_files=()
    if [[ -n "$TASK_DOC" ]]; then
        if [[ ! -f "$TASK_DOC" ]]; then
            exit_with_json "error" "--task-doc not found: ${TASK_DOC}"
        fi
        tsk_files=("$TASK_DOC")
    else
        mapfile -t tsk_files < <(find . -path '*/docs/active/*' -type f -name "${TASK_ID}-*-TSK-*.md" 2>/dev/null || true)
        mapfile -t pln_files < <(find . -path '*/docs/active/*' -type f -name "${TASK_ID}-*-PLN-*.md" 2>/dev/null || true)
    fi

    local kw_file
    kw_file=$(mktemp)
    local f
    for f in "${tsk_files[@]}" "${pln_files[@]}"; do
        [[ -z "$f" ]] && continue
        extract_keywords_from_file "$f" >> "$kw_file"
    done

    # Build keyword set: lowercased, dedup, stopwords filtered.
    local keywords_json
    if [[ -s "$kw_file" ]]; then
        keywords_json=$(grep -Ev "$STOPWORDS_RE" "$kw_file" | sort -u | jq -R . | jq -s .)
    else
        keywords_json='[]'
    fi
    rm -f "$kw_file"

    local kw_count
    kw_count=$(jq 'length' <<< "$keywords_json")
    if [[ "$kw_count" -eq 0 ]]; then
        local extra
        extra=$(printf '"ranked": [], "task_id": %s, "keywords": []' "$(jq -Rs . <<< "$TASK_ID")")
        exit_with_json "success" "no task docs found for ${TASK_ID}; nothing to rank" "" "$extra"
    fi

    # Rank: score = count of keyword substring matches across id|name|summary.
    local ranked
    ranked=$(jq -c --argjson kws "$keywords_json" --argjson limit "$FOR_TASK_LIMIT" '
        [ .nodes[]
          | . as $n
          | ((.id // "") + " " + (.name // "") + " " + (.summary // "") | ascii_downcase) as $hay
          | [ $kws[] | . as $k | select($hay | contains($k)) ] as $matched
          | select(($matched | length) > 0)
          | {node: $n, score: ($matched | length), matched_keywords: $matched}
        ]
        | sort_by(-.score)
        | .[0:$limit]
    ' "$GRAPH_FILE")

    local extra
    extra=$(printf '"ranked": %s, "task_id": %s, "keywords": %s' \
        "$ranked" "$(jq -Rs . <<< "$TASK_ID")" "$keywords_json")
    exit_with_json "success" "ranked nodes against task ${TASK_ID}" "" "$extra"
}

section_stats() {
    local now_epoch scanned_epoch staleness_days
    now_epoch=$(date +%s)
    local scanned_at
    scanned_at=$(jq -r '.meta.scanned_at // ""' "$GRAPH_FILE")
    if [[ -n "$scanned_at" ]]; then
        scanned_epoch=$(parse_iso8601_to_epoch "$scanned_at" || echo "$now_epoch")
    else
        scanned_epoch="$now_epoch"
    fi
    staleness_days=$(( (now_epoch - scanned_epoch) / 86400 ))

    local stats
    stats=$(jq -c --argjson staleness "$staleness_days" '
        {
            node_count: (.nodes | length),
            edge_count: (.edges | length),
            nodes_by_kind: (.nodes | group_by(.kind)
                            | map({key: (.[0].kind // "unknown"), value: length})
                            | from_entries),
            edges_by_kind: (.edges | group_by(.kind)
                            | map({key: (.[0].kind // "unknown"), value: length})
                            | from_entries),
            layers: (.nodes | group_by(.layer // "unlayered")
                     | map({key: (.[0].layer // "unlayered"), value: length})
                     | from_entries),
            meta: {
                commit_sha: (.meta.commit_sha // null),
                scanned_at: (.meta.scanned_at // null),
                staleness_days: $staleness
            }
        }
    ' "$GRAPH_FILE")
    local extra
    extra=$(printf '"stats": %s' "$stats")
    exit_with_json "success" "graph stats" "" "$extra"
}

# --- Main ---
load_graph

case "$SECTION" in
    search)    section_search ;;
    node)      section_node ;;
    tour)      section_tour ;;
    for-task)  section_for_task ;;
    stats)     section_stats ;;
    *)         exit_with_json "error" "unhandled section: ${SECTION}" ;;
esac
