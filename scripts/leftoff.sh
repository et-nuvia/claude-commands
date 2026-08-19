#!/usr/bin/env bash
set -euo pipefail

# leftoff.sh - Gather "where did we leave off" context for the current project
#
# Combines three signals so the agent can recommend what to do next:
#   1. Tasks   - active vs completed V4 task documents (id, title, status)
#   2. History - the most recent Claude Code conversations for this project
#                (ai-title + last prompt per session, no full transcript read)
#   3. Project - current branch, active task, uncommitted changes, recent commits
#
# Usage:
#   leftoff.sh [--json|--raw] [--full|--tasks|--history|--project] [--limit <n>]
#
# Output Modes:
#   --json: Structured JSON for the LLM to synthesize (default)
#   --raw:  Verbose human-readable debugging output
#
# Section Flags:
#   --tasks:    Task completion snapshot only
#   --history:  Recent conversation snapshot only
#   --project:  Git/working-tree snapshot only
#   --full:     All sections (default)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success) echo "parse_content" ;;
        *)       _default_map_status_to_action "$1" ;;
    esac
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output-framework.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/platform.sh"   # portable_date_parse (macOS + Linux)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/doc-utils.sh"

# Portable file mtime as ISO-8601. GNU `stat -c` / BSD `stat -f` differ, and
# BSD `date -r` treats its arg as epoch seconds (not a file), so resolve the
# epoch with stat then format via the shared portable_date_parse helper.
file_mtime_iso() {
    local f="$1" epoch
    epoch=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo "")
    [[ -z "$epoch" ]] && { echo ""; return; }
    portable_date_parse "$epoch" '%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo "$epoch"
}

# Read file paths on stdin, emit them newest-first by mtime. Portable
# replacement for `xargs -r ls -t` (BSD xargs lacks -r; bare `ls -t` on empty
# input lists the cwd on macOS).
sort_by_mtime_desc() {
    local f epoch
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        epoch=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)
        printf '%s\t%s\n' "$epoch" "$f"
    done | sort -rn | cut -f2-
}

# --- Config ---
CLAUDE_DIR="${HOME}/.claude"
PROJECTS_DIR="${CLAUDE_DIR}/projects"
WIKI_CONV_DIR="${HOME}/projects/wiki/conversations"
OUTPUT_MODE="json"
SECTION="full"
LIMIT=3   # "the last couple" — keep it small by default

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# --- Flag Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)    OUTPUT_MODE="json"; shift ;;
        --raw)     OUTPUT_MODE="raw"; shift ;;
        --tasks)   SECTION="tasks"; shift ;;
        --history) SECTION="history"; shift ;;
        --project) SECTION="project"; shift ;;
        --full)    SECTION="full"; shift ;;
        --limit)   LIMIT="${2:-5}"; shift 2 ;;
        *)         break ;;
    esac
done

# Encode an absolute path the way Claude Code names project history dirs:
# every '/' and '.' becomes '-'.
encode_project_dir() {
    echo "$1" | sed 's/[/.]/-/g'
}

# Find the curated conversation-wiki entry for a session id, if one was mined.
# Wiki files live at ~/projects/wiki/conversations/<wing>/<date>-<8hex>.md and
# carry the full session_id in frontmatter; the filename uses the id's first 8
# hex chars (== the jsonl filename prefix). Echoes "title<TAB>summary" or "".
find_wiki_entry() {
    local sid="$1" short="${1:0:8}" file=""
    [[ -d "$WIKI_CONV_DIR" ]] || return 0
    # Match by filename hash first (cheap), then confirm via frontmatter.
    for file in "$WIKI_CONV_DIR"/*/*-"$short".md; do
        [[ -f "$file" ]] || continue
        grep -q "session_id: ${sid}" "$file" 2>/dev/null || continue
        local wtitle wsummary
        wtitle=$(awk -F': ' '/^title:/{sub(/^title: */,""); print; exit}' "$file")
        # The prose under "## Summary" up to the next "## " heading.
        wsummary=$(awk '/^## Summary/{f=1;next} /^## /{f=0} f' "$file" \
            | sed '/^$/d' | head -c 600)
        printf '%s\t%s' "$wtitle" "$wsummary"
        return 0
    done
}

# --- Section: Tasks ---
collect_tasks() {
    local docs_dir active_json="[]" completed_recent="[]" active_count=0 completed_count=0
    docs_dir="$(find_docs_dir 2>/dev/null || true)"

    if [[ -n "$docs_dir" ]]; then
        local id rows=""
        while read -r id; do
            [[ -z "$id" ]] && continue
            active_count=$((active_count + 1))
            local primary title
            primary=$(find_primary "$id" 2>/dev/null || true)
            title=""
            [[ -n "$primary" ]] && title=$(get_doc_title "$primary" 2>/dev/null || echo "")
            rows+=$(jq -n --arg id "$id" --arg title "$title" --arg doc "${primary:-}" \
                '{task_id:$id, title:$title, primary_doc:$doc}')$'\n'
        done < <(list_task_ids active 2>/dev/null || true)
        [[ -n "$rows" ]] && active_json=$(echo "$rows" | jq -s '.')

        completed_count=$(list_task_ids completed 2>/dev/null | grep -c . || true)
        # Most recently modified completed docs for "recently finished" context
        local crows=""
        while read -r f; do
            [[ -z "$f" ]] && continue
            local cid ctitle
            cid=$(basename "$f" | grep -oE '^[A-F0-9]{6}' || echo "")
            ctitle=$(get_doc_title "$f" 2>/dev/null || echo "")
            crows+=$(jq -n --arg id "$cid" --arg title "$ctitle" '{task_id:$id, title:$title}')$'\n'
        done < <(find "$docs_dir/completed" -name "*.md" 2>/dev/null | sort_by_mtime_desc | head -3)
        [[ -n "$crows" ]] && completed_recent=$(echo "$crows" | jq -s 'unique_by(.task_id)')
    fi

    jq -n --argjson active "$active_json" --argjson recent "$completed_recent" \
        --argjson ac "$active_count" --argjson cc "$completed_count" \
        --arg dir "${docs_dir:-}" \
        '{docs_dir:$dir, active_count:$ac, completed_count:$cc, active:$active, recently_completed:$recent}'
}

# --- Section: History ---
collect_history() {
    local main_root encoded conv_json="[]"
    # Resolve to the MAIN worktree root so history is consistent whether the
    # command is invoked from the main checkout or any linked worktree.
    main_root=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print $2; exit}')
    [[ -z "$main_root" ]] && main_root="$PROJECT_ROOT"
    encoded=$(encode_project_dir "$main_root")

    # History dirs: the main project dir plus every linked-worktree dir, which
    # Claude Code names "<encoded-main>--worktrees-<id>".
    local -a hist_dirs=()
    [[ -d "${PROJECTS_DIR}/${encoded}" ]] && hist_dirs+=("${PROJECTS_DIR}/${encoded}")
    local d
    for d in "${PROJECTS_DIR}/${encoded}--worktrees-"*; do
        [[ -d "$d" ]] && hist_dirs+=("$d")
    done

    if [[ ${#hist_dirs[@]} -gt 0 ]]; then
        local rows=""
        while read -r f; do
            [[ -z "$f" ]] && continue
            local sid title prompt mtime msgs wt="" wiki_title="" wiki_summary=""
            sid=$(basename "$f" .jsonl)
            title=$(jq -rs 'map(select(.type=="ai-title")) | last | .aiTitle // empty' "$f" 2>/dev/null || echo "")
            prompt=$(jq -rs 'map(select(.type=="last-prompt")) | last | .lastPrompt // empty' "$f" 2>/dev/null || echo "")
            msgs=$(jq -rs 'map(select(.type=="user" or .type=="assistant")) | length' "$f" 2>/dev/null || echo "0")
            mtime=$(file_mtime_iso "$f")
            # Tag which worktree (if any) the session came from
            [[ "$(dirname "$f")" == *"--worktrees-"* ]] && wt=$(basename "$(dirname "$f")" | sed 's/.*--worktrees-//')
            # Enrich with the curated conversation-wiki summary when available
            local wiki_entry
            wiki_entry=$(find_wiki_entry "$sid" 2>/dev/null || echo "")
            if [[ -n "$wiki_entry" ]]; then
                wiki_title="${wiki_entry%%$'\t'*}"
                wiki_summary="${wiki_entry#*$'\t'}"
                [[ -n "$wiki_title" ]] && title="$wiki_title"
            fi
            rows+=$(jq -n --arg file "$f" --arg title "$title" --arg prompt "$prompt" \
                --arg mtime "$mtime" --arg wt "$wt" --arg wsum "$wiki_summary" --argjson msgs "${msgs:-0}" \
                '{file:$file, title:$title, last_prompt:$prompt, message_count:$msgs, modified:$mtime, worktree:$wt, wiki_summary:$wsum}')$'\n'
        done < <(find "${hist_dirs[@]}" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | sort_by_mtime_desc | head -"$LIMIT")
        [[ -n "$rows" ]] && conv_json=$(echo "$rows" | jq -s '.')
    fi

    jq -n --arg dir "${PROJECTS_DIR}/${encoded}" --argjson dirs "$(printf '%s\n' "${hist_dirs[@]}" | jq -R . | jq -s .)" \
        --argjson convs "$conv_json" \
        '{history_dir:$dir, searched_dirs:$dirs, conversations:$convs}'
}

# --- Section: Project ---
collect_project() {
    local branch current_task="" dirty=0 commits="[]"
    branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [[ -f "$PROJECT_ROOT/.current-task" ]] && current_task=$(grep -m1 -oE '[A-F0-9]{6}' "$PROJECT_ROOT/.current-task" 2>/dev/null || echo "")
    dirty=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | grep -c . || true)
    if git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        commits=$(git -C "$PROJECT_ROOT" log -5 --pretty=format:'%h %s' 2>/dev/null \
            | jq -R . | jq -s '.' 2>/dev/null || echo "[]")
    fi

    jq -n --arg branch "$branch" --arg task "$current_task" \
        --argjson dirty "${dirty:-0}" --argjson commits "$commits" \
        '{branch:$branch, current_task:$task, uncommitted_files:$dirty, recent_commits:$commits}'
}

# --- Main ---
TASKS_JSON="{}"; HISTORY_JSON="{}"; PROJECT_JSON="{}"

case "$SECTION" in
    tasks)   TASKS_JSON=$(collect_tasks) ;;
    history) HISTORY_JSON=$(collect_history) ;;
    project) PROJECT_JSON=$(collect_project) ;;
    full)
        TASKS_JSON=$(collect_tasks)
        HISTORY_JSON=$(collect_history)
        PROJECT_JSON=$(collect_project)
        ;;
esac

if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "=== leftoff: $PROJECT_ROOT ==="
    echo "--- tasks ---";   echo "$TASKS_JSON" | jq .
    echo "--- history ---"; echo "$HISTORY_JSON" | jq .
    echo "--- project ---"; echo "$PROJECT_JSON" | jq .
    exit 0
fi

EXTRA=$(jq -n \
    --arg root "$PROJECT_ROOT" \
    --argjson tasks "$TASKS_JSON" \
    --argjson history "$HISTORY_JSON" \
    --argjson project "$PROJECT_JSON" \
    '{project_root:$root, tasks:$tasks, history:$history, project:$project}' \
    | jq -c 'to_entries | map("\(.key|@json): \(.value|@json)") | join(",\n  ")' -r)

exit_with_json "success" "Left-off context gathered for $PROJECT_ROOT" "" "$EXTRA"
