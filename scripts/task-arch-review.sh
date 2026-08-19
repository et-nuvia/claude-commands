#!/usr/bin/env bash
set -euo pipefail

# task-arch-review.sh - Architecture review scoped to a single task's diff
#
# Modeled on task-code-review.sh. Differs in two ways:
#   1. Output is an ARC document (deepening candidates), not a CRV.
#   2. Document filename uses the ARC type code so it co-locates with other
#      task documents next to the TSK.
#
# Usage:
#   ~/.claude/scripts/task-arch-review.sh [--json|--raw] [--full|--section] [--task-id <id>]
#
# Sections:
#   --identify-task | --get-pr | --gather-info | --diff-page N
#   --create-doc    | --commit | --full
#
# Workflow:
#   1. LLM calls --full → gets task context, diff stats, file list, commit log
#   2. LLM reads diff (pages if needed) and applies LANGUAGE.md heuristics
#   3. LLM calls --create-doc → gets ARC path + populated template
#   4. LLM fills Deepening Candidates section, writes file
#   5. LLM calls --commit

DIFF_LINES_PER_PAGE=200

OUTPUT_MODE="json"
SECTION="full"
TASK_INPUT=""
DIFF_PAGE=0

TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
TASK_SLUG=""
TASK_BRANCH=""

PR_URL=""
PR_TYPE=""
PR_NUM=""
CURRENT_BRANCH=""
DEFAULT_BRANCH=""
FILES_CHANGED=0
ADDITIONS=0
DELETIONS=0
PLATFORM=""
DIFF_SOURCE=""

DIFF_FILE=""
DIFF_STATS=""
FILE_LIST=""
COMMIT_LOG=""
DIFF_TOTAL_LINES=0
DIFF_PAGES=0

ARC_FILENAME=""
ARC_PATH=""

KNOWLEDGE_DOC="docs/architecture/PROJECT-KNOWLEDGE.md"
ADR_DIR="docs/adr"
ARC_TEMPLATE="${HOME}/.claude/templates/task-ARC.md"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/git-utils.sh"

get_diff_path() {
    local task_id="${1:-unknown}"
    echo "/tmp/arc-diff-${task_id}.diff"
}

#------------------------------------------------------------------------------
# Section: Identify task
#------------------------------------------------------------------------------
section_identify_task() {
    log "${BLUE}Identifying Task${NC}"

    if [[ ! -f "${SCRIPT_DIR}/doc-utils.sh" ]]; then
        exit_with_json "error" "doc-utils.sh not found" "Required utility script missing"
    fi
    source "${SCRIPT_DIR}/doc-utils.sh"

    if [[ -n "$TASK_INPUT" ]]; then
        if [[ "$TASK_INPUT" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$TASK_INPUT")
            TASK_DOC=$(find_primary "$TASK_ID" 2>/dev/null || echo "")
            if [[ -z "$TASK_DOC" ]]; then
                exit_with_json "error" "No primary task found for task ID $TASK_ID" "Run: /task-fetch"
            fi
        else
            TASK_DOC=$(find docs/active docs/completed -name "*-TSK-*.md" 2>/dev/null | grep "$TASK_INPUT" | head -1 || echo "")
        fi
    elif load_current_task; then
        TASK_DOC="$CT_TASK_DOC"
        TASK_BRANCH="$CT_BRANCH"
        TASK_ID="$CT_TASK_ID"
    fi

    if [[ ! -f "${TASK_DOC:-}" ]]; then
        exit_with_json "error" "Task document not found" "Provide --task-id or run /task-start first"
    fi

    TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")
    TASK_TITLE=$(get_doc_title "$TASK_DOC")
    TASK_SLUG=$(basename "$TASK_DOC" | sed -E 's/^[A-F0-9]{6}-[0-9]{10}-[A-Z]{3}-//' | sed 's/.md$//' | head -c 40 | sed 's/-$//')

    log "${GREEN}✓${NC} Task: $TASK_ID - $TASK_TITLE"

    if [[ "$SECTION" == "identify-task" ]]; then
        log_json "$(jq -nc \
            --arg task_id "$TASK_ID" --arg task_doc "$TASK_DOC" \
            --arg task_title "$TASK_TITLE" --arg task_slug "$TASK_SLUG" \
            --arg task_branch "$TASK_BRANCH" \
            '{status:"success", section:"identify-task", task_id:$task_id, task_doc:$task_doc, task_title:$task_title, task_slug:$task_slug, task_branch:$task_branch}')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Section: Detect PR/MR or use branch diff
#------------------------------------------------------------------------------
section_get_pr() {
    log "${BLUE}Detecting Diff Source${NC}"

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    DEFAULT_BRANCH=$(detect_base_branch)

    if [[ -n "$CURRENT_BRANCH" ]]; then
        if command -v gh &>/dev/null && git remote -v 2>/dev/null | grep -q "github"; then
            PLATFORM="github"; PR_TYPE="PR"
            PR_URL=$(gh pr list --head "$CURRENT_BRANCH" --state all --json url --jq '.[0].url' 2>/dev/null || echo "")
            if [[ -n "$PR_URL" ]]; then
                PR_NUM=$(echo "$PR_URL" | sed -n 's|.*/pull/\([0-9]\+\).*|\1|p' || echo "")
                DIFF_SOURCE="pr"
            fi
        elif command -v glab &>/dev/null && git remote -v 2>/dev/null | grep -q "gitlab"; then
            PLATFORM="gitlab"; PR_TYPE="MR"
            local mr_url
            mr_url=$(glab mr list --source-branch "$CURRENT_BRANCH" 2>/dev/null | head -1 | awk '{print $1}' || echo "")
            if [[ -n "$mr_url" ]]; then
                PR_URL="$mr_url"
                PR_NUM=$(echo "$PR_URL" | sed -n 's|.*/-/merge_requests/\([0-9]\+\).*|\1|p' || echo "")
                DIFF_SOURCE="mr"
            fi
        fi
    fi

    if [[ -z "$DIFF_SOURCE" ]]; then
        DIFF_SOURCE="branch"
        PR_TYPE="Branch diff"
    fi

    if [[ "$SECTION" == "get-pr" ]]; then
        log_json "$(jq -nc \
            --arg platform "$PLATFORM" --arg pr_url "$PR_URL" --arg pr_type "$PR_TYPE" \
            --arg diff_source "$DIFF_SOURCE" --arg current "$CURRENT_BRANCH" --arg default "$DEFAULT_BRANCH" \
            '{status:"success", section:"get-pr", platform:$platform, pr_url:$pr_url, pr_type:$pr_type, diff_source:$diff_source, current_branch:$current, default_branch:$default}')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Section: Capture diff + stats
#------------------------------------------------------------------------------
section_gather_info() {
    log "${BLUE}Gathering Diff${NC}"

    DIFF_FILE=$(get_diff_path "$TASK_ID")

    if [[ "$DIFF_SOURCE" == "pr" ]] && [[ -n "$PR_NUM" ]]; then
        gh pr diff "$PR_NUM" > "$DIFF_FILE" 2>/dev/null || true
        local pr_info
        pr_info=$(gh pr view "$PR_NUM" --json files,additions,deletions 2>/dev/null || echo "{}")
        FILES_CHANGED=$(echo "$pr_info" | jq -r '.files | length' 2>/dev/null || echo "0")
        ADDITIONS=$(echo "$pr_info" | jq -r '.additions' 2>/dev/null || echo "0")
        DELETIONS=$(echo "$pr_info" | jq -r '.deletions' 2>/dev/null || echo "0")
        FILE_LIST=$(echo "$pr_info" | jq -r '.files[].path' 2>/dev/null || echo "")
        COMMIT_LOG=$(gh pr view "$PR_NUM" --json commits --jq '.commits[].messageHeadline' 2>/dev/null || echo "")
        DIFF_STATS=$(git diff --stat "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")
    elif [[ "$DIFF_SOURCE" == "mr" ]] && [[ -n "$PR_NUM" ]]; then
        glab mr diff "$PR_NUM" > "$DIFF_FILE" 2>/dev/null || \
            git diff "origin/${DEFAULT_BRANCH}...HEAD" > "$DIFF_FILE" 2>/dev/null || true
        FILE_LIST=$(git diff --name-only "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")
        COMMIT_LOG=$(git log --oneline "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        DIFF_STATS=$(git diff --stat "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")
        FILES_CHANGED=$(echo "$FILE_LIST" | grep -c '.' || echo "0")
        local numstat
        numstat=$(git diff --numstat "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")
        ADDITIONS=$(echo "$numstat" | awk '{s+=$1} END {print s+0}')
        DELETIONS=$(echo "$numstat" | awk '{s+=$2} END {print s+0}')
    else
        git diff "${DEFAULT_BRANCH}...HEAD" > "$DIFF_FILE" 2>/dev/null || \
            git diff "${DEFAULT_BRANCH}..HEAD" > "$DIFF_FILE" 2>/dev/null || true
        FILE_LIST=$(git diff --name-only "${DEFAULT_BRANCH}...HEAD" 2>/dev/null || \
            git diff --name-only "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        COMMIT_LOG=$(git log --oneline "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        DIFF_STATS=$(git diff --stat "${DEFAULT_BRANCH}...HEAD" 2>/dev/null || \
            git diff --stat "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        FILES_CHANGED=$(echo "$FILE_LIST" | grep -c '.' || echo "0")
        local numstat
        numstat=$(git diff --numstat "${DEFAULT_BRANCH}...HEAD" 2>/dev/null || \
            git diff --numstat "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "")
        ADDITIONS=$(echo "$numstat" | awk '{s+=$1} END {print s+0}')
        DELETIONS=$(echo "$numstat" | awk '{s+=$2} END {print s+0}')
    fi

    FILES_CHANGED="${FILES_CHANGED:-0}"; [[ "$FILES_CHANGED" =~ ^[0-9]+$ ]] || FILES_CHANGED=0
    ADDITIONS="${ADDITIONS:-0}"; [[ "$ADDITIONS" =~ ^[0-9]+$ ]] || ADDITIONS=0
    DELETIONS="${DELETIONS:-0}"; [[ "$DELETIONS" =~ ^[0-9]+$ ]] || DELETIONS=0

    DIFF_TOTAL_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo "0")
    DIFF_TOTAL_LINES="${DIFF_TOTAL_LINES// /}"
    DIFF_PAGES=$(( (DIFF_TOTAL_LINES + DIFF_LINES_PER_PAGE - 1) / DIFF_LINES_PER_PAGE ))
    [[ $DIFF_PAGES -eq 0 ]] && DIFF_PAGES=1

    log "${GREEN}✓${NC} Diff: ${DIFF_TOTAL_LINES} lines (${DIFF_PAGES} pages), ${FILES_CHANGED} files"

    if [[ "$SECTION" == "gather-info" ]]; then
        log_json "$(jq -nc \
            --arg diff_source "$DIFF_SOURCE" \
            --arg diff_stats "$DIFF_STATS" --arg file_list "$FILE_LIST" --arg commit_log "$COMMIT_LOG" \
            --argjson files "$FILES_CHANGED" --argjson adds "$ADDITIONS" --argjson dels "$DELETIONS" \
            --argjson lines "$DIFF_TOTAL_LINES" --argjson pages "$DIFF_PAGES" \
            '{status:"success", section:"gather-info", diff_source:$diff_source, stats:{files_changed:$files, additions:$adds, deletions:$dels}, diff:{total_lines:$lines, pages:$pages, lines_per_page:200}, diff_stats:$diff_stats, file_list:$file_list, commit_log:$commit_log}')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Section: Page through diff
#------------------------------------------------------------------------------
section_diff_page() {
    DIFF_FILE=$(get_diff_path "$TASK_ID")
    if [[ ! -f "$DIFF_FILE" ]]; then
        exit_with_json "error" "Diff file not found — run --full or --gather-info first" ""
    fi
    DIFF_TOTAL_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo "0")
    DIFF_PAGES=$(( (DIFF_TOTAL_LINES + DIFF_LINES_PER_PAGE - 1) / DIFF_LINES_PER_PAGE ))
    [[ $DIFF_PAGES -eq 0 ]] && DIFF_PAGES=1

    if [[ $DIFF_PAGE -lt 1 ]] || [[ $DIFF_PAGE -gt $DIFF_PAGES ]]; then
        exit_with_json "error" "Invalid page ${DIFF_PAGE} — valid range is 1..${DIFF_PAGES}" ""
    fi
    local start_line=$(( (DIFF_PAGE - 1) * DIFF_LINES_PER_PAGE + 1 ))
    local page_content
    page_content=$(sed -n "${start_line},$((start_line + DIFF_LINES_PER_PAGE - 1))p" "$DIFF_FILE")
    local page_lines
    page_lines=$(echo "$page_content" | wc -l)

    log_json "$(jq -nc \
        --argjson page "$DIFF_PAGE" --argjson total_pages "$DIFF_PAGES" \
        --argjson start_line "$start_line" --argjson lines "$page_lines" \
        --arg content "$page_content" \
        '{status:"success", section:"diff-page", page:$page, total_pages:$total_pages, start_line:$start_line, lines:$lines, content:$content}')"
    exit 0
}

#------------------------------------------------------------------------------
# Section: Create ARC document next to the TSK
#------------------------------------------------------------------------------
find_existing_arc() {
    # Search the current git worktree's docs tree first — TASK_DOC may live in
    # the main checkout (find_primary fallback), but an ARC created during
    # this session lives in the worktree.
    local found=""
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_repo_root" ]] && [[ -d "$_repo_root/docs" ]]; then
        found=$(find "$_repo_root/docs" -name "${TASK_ID}-*-ARC-*.md" 2>/dev/null | sort -r | head -1 || echo "")
    fi
    if [[ -z "$found" ]]; then
        found=$(find "$(dirname "$TASK_DOC")" -name "${TASK_ID}-*-ARC-*.md" 2>/dev/null | sort -r | head -1)
    fi
    if [[ -n "$found" ]]; then
        ARC_PATH="$found"
        ARC_FILENAME="$(basename "$found")"
        return 0
    fi
    return 1
}

section_create_doc() {
    log "${BLUE}Creating ARC Document${NC}"

    if find_existing_arc; then
        log "${GREEN}✓${NC} Found existing ARC: $ARC_FILENAME"
        if [[ "$SECTION" == "create-doc" ]]; then
            log_json "$(jq -nc \
                --arg arc_filename "$ARC_FILENAME" --arg arc_path "$ARC_PATH" \
                '{status:"success", section:"create-doc", next_action:"write_document", arc_filename:$arc_filename, arc_path:$arc_path, message:"Existing ARC found — edit Deepening Candidates section, then call --commit"}')"
            exit 0
        fi
        return
    fi

    if [[ ! -f "$ARC_TEMPLATE" ]]; then
        exit_with_json "error" "Template not found: $ARC_TEMPLATE" "Expected ~/.claude/templates/task-ARC.md"
    fi

    # Resolve the ARC path via new-doc.sh — it anchors on the CURRENT worktree
    # (find_docs_dir), so the doc is created here even when TASK_DOC resolved
    # to the main checkout via find_primary's fallback.
    local doc_json
    doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type ARC --description "${TASK_SLUG}" --id "$TASK_ID" --json 2>/dev/null || echo "")
    ARC_PATH=$(echo "$doc_json" | jq -r '.filepath // empty' 2>/dev/null || echo "")
    if [[ -z "$ARC_PATH" ]]; then
        # Fallback: sibling of the TSK doc (pre-worktree behavior)
        local datetime
        datetime=$(date +%y%m%d%H%M)
        ARC_PATH="$(dirname "$TASK_DOC")/${TASK_ID}-${datetime}-ARC-${TASK_SLUG}.md"
    fi
    ARC_FILENAME="$(basename "$ARC_PATH")"

    local folder
    folder="$(dirname "$ARC_PATH")"

    # Surface gating context
    local knowledge_present="false"
    [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"
    local adr_list_json="[]"
    if [[ -d "$ADR_DIR" ]]; then
        adr_list_json=$(find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
            | sort | jq -R . | jq -sc . 2>/dev/null || echo "[]")
    fi

    # Read template and substitute the known header fields. LLM fills the rest.
    local template
    template=$(cat "$ARC_TEMPLATE")
    template=$(echo "$template" \
        | sed "s|# Architecture Review: \[Brief Description\]|# Architecture Review: ${TASK_TITLE}|" \
        | sed "s|\[TASK_ID\]|${TASK_ID}|" \
        | sed "s|\[YYYY-MM-DD HH:MM\]|$(date '+%Y-%m-%d %H:%M')|" \
        | sed "s|\[FOLDER\]|${folder}|")

    # Swap the "Source" stanza to reflect task-scope rather than project-scope
    template=$(echo "$template" | awk '
        /^## Source$/ { print; in_src=1; next }
        in_src && /^## / { in_src=0 }
        in_src && /^$/ && !printed_src {
            print ""
            print "- `/task-arch-review` on task '"${TASK_ID}"' diff"
            print "- Branch: `'"${CURRENT_BRANCH}"'` vs `'"${DEFAULT_BRANCH}"'`"
            print "- Files changed: '"${FILES_CHANGED}"' (+'"${ADDITIONS}"'/-'"${DELETIONS}"')"
            print "- Domain context: `'"${KNOWLEDGE_DOC}"'` (present: '"${knowledge_present}"')"
            printed_src=1
            next
        }
        in_src { next }
        { print }
    ')

    log "${GREEN}✓${NC} Prepared: $ARC_FILENAME"

    if [[ "$SECTION" == "create-doc" ]]; then
        log_json "$(jq -nc \
            --arg arc_filename "$ARC_FILENAME" --arg arc_path "$ARC_PATH" \
            --arg template "$template" \
            --arg knowledge_doc "$KNOWLEDGE_DOC" --arg knowledge_present "$knowledge_present" \
            --argjson adr_files "$adr_list_json" \
            '{status:"success", section:"create-doc", next_action:"write_document", arc_filename:$arc_filename, arc_path:$arc_path, template:$template, knowledge_doc:$knowledge_doc, knowledge_present:($knowledge_present == "true"), adr_files:$adr_files, message:"Write completed ARC to arc_path, then call --commit"}')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Section: Commit
#------------------------------------------------------------------------------
section_commit() {
    log "${BLUE}Committing ARC Document${NC}"

    if [[ ! -f "${ARC_PATH:-}" ]]; then
        exit_with_json "error" "ARC document not found" "Run --create-doc first"
    fi

    git add "$ARC_PATH"
    git commit -m "docs(arch-review): create task-scoped ARC for ${TASK_ID}

Task: ${TASK_TITLE}
Branch: ${CURRENT_BRANCH} vs ${DEFAULT_BRANCH}"

    local diff_tmp
    diff_tmp=$(get_diff_path "$TASK_ID")
    [[ -f "$diff_tmp" ]] && rm -f "$diff_tmp"

    if [[ -f "${SCRIPT_DIR}/update-docs.sh" ]]; then
        "${SCRIPT_DIR}/update-docs.sh" &>/dev/null || true
        git add docs/DOCUMENT-INDEX.md &>/dev/null || true
    fi

    if [[ "$SECTION" == "commit" ]]; then
        log_json "$(jq -nc \
            --arg arc_filename "$ARC_FILENAME" --arg commit "$(git rev-parse HEAD)" \
            '{status:"success", section:"commit", next_action:"display_summary", arc_filename:$arc_filename, commit:$commit}')"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)           OUTPUT_MODE="json"; shift ;;
            --raw)            OUTPUT_MODE="raw"; shift ;;
            --full)           SECTION="full"; shift ;;
            --identify-task)  SECTION="identify-task"; shift ;;
            --get-pr)         SECTION="get-pr"; shift ;;
            --gather-info)    SECTION="gather-info"; shift ;;
            --diff-page)      SECTION="diff-page"; DIFF_PAGE="$2"; shift 2 ;;
            --create-doc)     SECTION="create-doc"; shift ;;
            --commit)         SECTION="commit"; shift ;;
            --pr-url)         PR_URL="$2"; shift 2 ;;
            --task-id)        TASK_INPUT="$2"; shift 2 ;;
            *)                echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        identify-task)
            section_identify_task ;;
        get-pr)
            section_identify_task; section_get_pr ;;
        gather-info)
            section_identify_task; section_get_pr; section_gather_info ;;
        diff-page)
            section_identify_task; section_diff_page ;;
        create-doc)
            section_identify_task; section_get_pr; section_gather_info; section_create_doc ;;
        commit)
            section_identify_task; section_get_pr
            if ! find_existing_arc; then
                exit_with_json "error" "No ARC document found for ${TASK_ID}" "Run --create-doc first"
            fi
            section_commit ;;
        full)
            section_identify_task; section_get_pr; section_gather_info

            local knowledge_present="false"
            [[ -f "$KNOWLEDGE_DOC" ]] && knowledge_present="true"
            local adr_list_json="[]"
            if [[ -d "$ADR_DIR" ]]; then
                adr_list_json=$(find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
                    | sort | jq -R . | jq -sc . 2>/dev/null || echo "[]")
            fi

            log_json "$(jq -nc \
                --arg next_action "analyze_architecture" \
                --arg task_id "$TASK_ID" --arg task_title "$TASK_TITLE" --arg task_doc "$TASK_DOC" \
                --arg diff_source "$DIFF_SOURCE" \
                --arg pr_url "$PR_URL" --arg pr_type "$PR_TYPE" --arg platform "$PLATFORM" \
                --arg current "$CURRENT_BRANCH" --arg default "$DEFAULT_BRANCH" \
                --argjson files "$FILES_CHANGED" --argjson adds "$ADDITIONS" --argjson dels "$DELETIONS" \
                --arg diff_file "$DIFF_FILE" \
                --argjson diff_lines "$DIFF_TOTAL_LINES" --argjson diff_pages "$DIFF_PAGES" \
                --arg diff_stats "$DIFF_STATS" --arg file_list "$FILE_LIST" --arg commit_log "$COMMIT_LOG" \
                --arg knowledge_doc "$KNOWLEDGE_DOC" --arg knowledge_present "$knowledge_present" \
                --argjson adr_files "$adr_list_json" \
                '{
                    status: "success",
                    next_action: $next_action,
                    task: {task_id: $task_id, title: $task_title, doc: $task_doc},
                    diff_source: $diff_source,
                    pr: {url: $pr_url, type: $pr_type, platform: $platform},
                    branch: {current: $current, default: $default},
                    stats: {files_changed: $files, additions: $adds, deletions: $dels},
                    diff: {file: $diff_file, total_lines: $diff_lines, pages: $diff_pages, lines_per_page: 200},
                    diff_stats: $diff_stats,
                    file_list: $file_list,
                    commit_log: $commit_log,
                    architecture: {knowledge_doc: $knowledge_doc, knowledge_present: ($knowledge_present == "true"), adr_files: $adr_files}
                }')"
            exit 0
            ;;
        *)
            exit_with_json "error" "Unknown section: $SECTION" "Valid: identify-task, get-pr, gather-info, diff-page N, create-doc, commit, full" ;;
    esac
}

main "$@"
