#!/usr/bin/env bash
# understand-impact.sh — branch-diff impact analysis on .understand/graph.json.
#
# Given a git diff (current HEAD vs base), identify which graph nodes are
# directly changed and which nodes are downstream callers (reverse-edges).
#
# Sections:
#   --full          Default. Compute changed_nodes, affected_nodes,
#                   layer_crossings, blast_radius_score.
#
# Flags:
#   --base <ref>        Comparison base (default: auto-detect dev/main).
#   --hops N            Reverse-edge hop count (default: 2).
#   --graph-file <path> Override graph location.
#
# Output: changed_nodes[], affected_nodes[], layer_crossings, blast_radius_score.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/output-framework.sh"

GRAPH_DIR=".understand"
DEFAULT_GRAPH_FILE="${GRAPH_DIR}/graph.json"
SUPPORTED_SCHEMA_VERSION=1
DEFAULT_HOPS=2

# --- Flag parsing ---
OUTPUT_MODE="json"
SECTION="full"
BASE_REF=""
HOPS="${DEFAULT_HOPS}"
GRAPH_FILE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)        OUTPUT_MODE="json"; shift ;;
        --raw)         OUTPUT_MODE="raw"; shift ;;
        --toon)        OUTPUT_MODE="json"; export OUTPUT_FORMAT=toon; shift ;;
        --full)        SECTION="full"; shift ;;
        --base)        BASE_REF="${2:-}"; shift 2 ;;
        --hops)        HOPS="${2:-}"; shift 2 ;;
        --graph-file)  GRAPH_FILE_OVERRIDE="${2:-}"; shift 2 ;;
        *)
            exit_with_json "error" "unknown flag: $1"
            ;;
    esac
done

if ! [[ "$HOPS" =~ ^[0-9]+$ ]]; then
    exit_with_json "error" "--hops must be a non-negative integer"
fi

GRAPH_FILE="${GRAPH_FILE_OVERRIDE:-$DEFAULT_GRAPH_FILE}"

# --- Graph loading ---
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

# --- Base ref auto-detect ---
detect_base_ref() {
    if [[ -n "$BASE_REF" ]]; then
        echo "$BASE_REF"
        return
    fi
    local candidates=("dev" "develop" "main" "master")
    local ref
    for ref in "${candidates[@]}"; do
        if git rev-parse --verify "$ref" >/dev/null 2>&1; then
            echo "$ref"
            return
        fi
    done
    echo ""
}

# --- Diff collection ---
# Emit changed paths (both sides of a rename), one per line.
get_changed_files() {
    local base="$1"
    if [[ -z "$base" ]]; then
        return 0
    fi
    if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
        return 0
    fi
    # Use --name-status -M so renames are detected. Emit both old and new
    # paths so the caller can match either against the (possibly stale) graph.
    {
        git diff --name-status -M "$base"...HEAD 2>/dev/null || true
        git diff --name-status -M HEAD 2>/dev/null || true
        git diff --name-status -M --cached 2>/dev/null || true
    } | awk '
        /^R/ { print $2; print $3; next }
        /^[ACDMTUX]/ { print $2 }
    ' | sort -u | grep -v '^$' || true
}

# Emit rename records as JSON: [{old_path, new_path, similarity}, ...].
get_renamed_files_json() {
    local base="$1"
    if [[ -z "$base" ]]; then
        echo '[]'
        return 0
    fi
    if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
        echo '[]'
        return 0
    fi
    {
        git diff --name-status -M "$base"...HEAD 2>/dev/null || true
        git diff --name-status -M HEAD 2>/dev/null || true
        git diff --name-status -M --cached 2>/dev/null || true
    } | awk '
        # Rename line format: "R<similarity>\t<old>\t<new>"
        /^R/ {
            sim = substr($1, 2) + 0
            printf "%s\t%s\t%s\n", sim, $2, $3
        }
    ' | sort -u | jq -Rsn '
        [ inputs
          | split("\n")
          | map(select(length > 0))
          | .[]
          | split("\t")
          | {similarity: (.[0] | tonumber), old_path: .[1], new_path: .[2]} ]
    '
}

# --- Main section ---
section_full() {
    local base
    base=$(detect_base_ref)

    local changed_files renamed_files_json
    changed_files=$(get_changed_files "$base" || true)
    renamed_files_json=$(get_renamed_files_json "$base" || echo '[]')

    if [[ -z "$changed_files" ]]; then
        local extra
        extra='"changed_nodes": [], "affected_nodes": [], "renamed_files": '"$renamed_files_json"', "layer_crossings": 0, "blast_radius_score": 0, "base": '"$(jq -Rs . <<< "$base")"', "hops": '"$HOPS"
        exit_with_json "success" "no changes detected" "" "$extra"
    fi

    # Convert file list to JSON array.
    local changed_files_json
    changed_files_json=$(printf '%s\n' "$changed_files" | jq -R . | jq -s .)

    # Compute everything in jq.
    local result
    result=$(jq -c \
        --argjson files "$changed_files_json" \
        --argjson hops "$HOPS" '
        . as $g
        | ($g.nodes | map({key: .id, value: .}) | from_entries) as $byid
        # changed_nodes: nodes whose path is in $files OR whose id starts with "<file>::"
        | ($files | map(.) ) as $fs
        | [ $g.nodes[]
            | . as $n
            | select(
                ($fs | any(. as $f | ($n.path // "") == $f or (($n.id // "") | startswith($f + "::"))))
              )
          ] as $changed
        | ($changed | map(.id)) as $changed_ids
        # reverse adjacency: rev_adj[to] = [from, from, ...]
        | (reduce $g.edges[] as $e ({}; .[$e.to] = ((.[$e.to] // []) + [$e.from]))) as $rev_adj
        # BFS reverse-walk from changed_ids for $hops hops.
        | (reduce range(0; $hops) as $_ (
              {frontier: $changed_ids, visited: ($changed_ids | map({key: ., value: true}) | from_entries), affected: []};
              . as $st
              | ([ $st.frontier[] | ($rev_adj[.] // [])[] ] | unique) as $next_all
              | ([ $next_all[] | select($st.visited[.] | not) ]) as $next
              | {
                  frontier: $next,
                  visited: ($st.visited + ($next | map({key: ., value: true}) | from_entries)),
                  affected: ($st.affected + $next)
                }
          )) as $walk
        | ($walk.affected | unique) as $affected_ids
        | ($affected_ids | map($byid[.] // {id: .})) as $affected_nodes
        # layer_crossings: distinct (changed_layer, affected_layer) pairs
        # where the layers differ. Captures how far the blast crosses layers.
        | ([ $changed[] | (.layer // "unlayered") ] | unique) as $changed_layers
        | ([ $affected_nodes[] | (.layer // "unlayered") ] | unique) as $affected_layers
        | ([ $changed_layers[] as $cl
             | $affected_layers[] as $al
             | select($cl != $al)
             | [$cl, $al]
           ] | unique | length) as $crossings
        | {
            changed_nodes: $changed,
            affected_nodes: $affected_nodes,
            layer_crossings: $crossings,
            blast_radius_score: (($affected_nodes | length) + 2 * $crossings)
          }
    ' "$GRAPH_FILE")

    local changed_count affected_count crossings score
    changed_count=$(jq '.changed_nodes | length' <<< "$result")
    affected_count=$(jq '.affected_nodes | length' <<< "$result")
    crossings=$(jq '.layer_crossings' <<< "$result")
    score=$(jq '.blast_radius_score' <<< "$result")

    if [[ "$changed_count" -eq 0 ]]; then
        local extra
        extra='"changed_nodes": [], "affected_nodes": [], "renamed_files": '"$renamed_files_json"', "layer_crossings": 0, "blast_radius_score": 0, "base": '"$(jq -Rs . <<< "$base")"', "hops": '"$HOPS"
        exit_with_json "success" "diff present but no matching graph nodes" "" "$extra"
    fi

    local extra
    extra=$(printf '"changed_nodes": %s, "affected_nodes": %s, "renamed_files": %s, "layer_crossings": %s, "blast_radius_score": %s, "base": %s, "hops": %s' \
        "$(jq -c '.changed_nodes' <<< "$result")" \
        "$(jq -c '.affected_nodes' <<< "$result")" \
        "$renamed_files_json" \
        "$crossings" \
        "$score" \
        "$(jq -Rs . <<< "$base")" \
        "$HOPS")
    exit_with_json "success" "impact analysis complete: ${changed_count} changed, ${affected_count} affected" "" "$extra"
}

# --- Main ---
load_graph

case "$SECTION" in
    full) section_full ;;
    *)    exit_with_json "error" "unhandled section: ${SECTION}" ;;
esac
