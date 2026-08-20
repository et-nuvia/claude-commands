#!/usr/bin/env bash
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$_SD}"
# Document utility functions for V4 naming convention (6-char hex Task IDs)
# Source this file in command scripts: source ~/.claude/scripts/doc-utils.sh

source "${SCRIPT_DIR}/common.sh"

# Find project docs directory
# Priority: 1) PROJECT.yaml docs_dir field  2) Auto-detect from directory structure
find_docs_dir() {
    local project_root="$PWD"

    # Prefer git's view of the project root — this is worktree-aware
    # (`git rev-parse --show-toplevel` returns the worktree path, not the
    # main repo path, when invoked from inside a worktree). Falls back to
    # a manual walk for non-git directories.
    local git_toplevel
    git_toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$git_toplevel" ]]; then
        project_root="$git_toplevel"
    else
        # Find project root (directory containing PROJECT.yaml or .git).
        # Accept .git as file OR directory — .git is a file in worktrees.
        local search_dir="$PWD"
        local levels=0
        while [[ "$search_dir" != "/" ]] && [[ $levels -lt 5 ]]; do
            if [[ -f "$search_dir/PROJECT.yaml" ]] || [[ -e "$search_dir/.git" ]]; then
                project_root="$search_dir"
                break
            fi
            search_dir=$(dirname "$search_dir")
            ((levels++))
        done
    fi

    # Priority 1: Read docs_dir from PROJECT.yaml. Check the worktree first,
    # then the main repo (worktrees may not have PROJECT.yaml on their branch).
    local pyaml_file=""
    if [[ -f "$project_root/PROJECT.yaml" ]]; then
        pyaml_file="$project_root/PROJECT.yaml"
    else
        local common_dir main_root
        common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
        if [[ -n "$common_dir" ]]; then
            # --git-common-dir points at the shared .git directory; its parent is the main worktree
            main_root=$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd || true)
            if [[ -n "$main_root" ]] && [[ -f "$main_root/PROJECT.yaml" ]]; then
                pyaml_file="$main_root/PROJECT.yaml"
            fi
        fi
    fi
    if [[ -n "$pyaml_file" ]]; then
        local configured_dir=""
        if command -v yq &>/dev/null; then
            configured_dir=$(yaml_get '.docs_dir // ""' "$pyaml_file")
        elif command -v grep &>/dev/null; then
            configured_dir=$(grep '^docs_dir:' "$pyaml_file" 2>/dev/null | sed 's/^docs_dir:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"'"'" || true)
        fi
        if [[ -n "$configured_dir" ]] && [[ -d "$project_root/$configured_dir" ]]; then
            echo "$project_root/$configured_dir"
            return 0
        fi
    fi

    # Priority 2: Auto-detect docs directory from project root
    if [[ -d "$project_root/docs" ]]; then
        echo "$project_root/docs"
        return 0
    fi

    # Priority 3: Walk up from PWD looking for any docs/ directory.
    # Never walk past the git toplevel — from a linked worktree that walk
    # would escape into the main checkout (.worktrees/<id> → main repo) and
    # documents would silently be created outside the worktree.
    search_dir="$PWD"
    levels=0
    while [[ "$search_dir" != "/" ]] && [[ $levels -lt 5 ]]; do
        if [[ -n "$git_toplevel" ]] && [[ "$search_dir" != "$git_toplevel" ]] && [[ "$search_dir" != "$git_toplevel"/* ]]; then
            break
        fi
        if [[ -d "$search_dir/docs" ]]; then
            echo "$search_dir/docs"
            return 0
        fi
        search_dir=$(dirname "$search_dir")
        ((levels++))
    done

    # In a linked worktree whose branch has no docs/ yet, anchor new docs at
    # the worktree root instead of failing — callers mkdir -p as needed.
    if [[ -n "$git_toplevel" ]]; then
        local wt_git_dir wt_common_dir
        wt_git_dir=$(cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd || true)
        wt_common_dir=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd || true)
        if [[ -n "$wt_git_dir" ]] && [[ -n "$wt_common_dir" ]] && [[ "$wt_git_dir" != "$wt_common_dir" ]]; then
            echo "$git_toplevel/docs"
            return 0
        fi
    fi

    return 1
}

# Find documents by Task ID (6-char hex)
# Usage: find_by_id "A3F2B9"
find_by_id() {
    local task_id="$1"
    local docs_dir="${2:-$(find_docs_dir)}"

    if [[ -z "$docs_dir" ]]; then
        echo "Error: Could not find docs directory" >&2
        return 1
    fi

    # Normalize to uppercase
    task_id=$(echo "$task_id" | tr '[:lower:]' '[:upper:]')

    # Find all documents with this Task ID prefix (|| true: find exits 1 if a path doesn't exist)
    find "$docs_dir/active" "$docs_dir/completed" -name "${task_id}-*" 2>/dev/null | sort || true
}

# Backward-compatible alias
find_by_sequence() { find_by_id "$@"; }

# Pick the NEWEST document from a newline-separated list of paths on stdin.
#
# WHY this exists: every caller used to do `... | head -1` on a path list, but
# `find`/`find_by_id` emit paths in directory order, so `head -1` silently returns
# the OLDEST document whenever a work item has more than one of a type — e.g. a
# task with a second PLN gets its first one, and month-partitioned folders make
# `docs/active/2026-07/` always beat `docs/active/2026-08/`. That produced a
# wrong-document selection with no error: task-continue.sh loaded a superseded PLN,
# reported "0 tasks pending", and would have written completions into it.
#
# Ranking is on the DATETIME field of the V4 filename (<ID>-<YYMMDDHHMM>-<TYPE>-*),
# not on the full path and not on the whole basename. Path order encodes the folder
# (so `completed/` would outrank `active/`), and whole-basename order sorts by work
# item ID first (so the highest task ID would win instead of the newest document).
# The datetime field is the only component that actually means "most recent".
newest_doc() {
    awk -F/ 'NF { n = split($NF, parts, "-"); if (n >= 2) print parts[2] "\t" $0 }' \
        | sort -r | cut -f2- | head -1
}

# Find the newest document of a given type for a Task ID.
# Usage: find_newest_by_type "A3F2B9" "PLN"
find_newest_by_type() {
    local task_id="$1"
    local doc_type="$2"
    find_by_id "$task_id" | grep -- "-${doc_type}-" | newest_doc
}

# Find primary document (INC or TSK) for a Task ID
# Usage: find_primary "A3F2B9"
find_primary() {
    local task_id="$1"
    local docs_dir="${2:-$(find_docs_dir)}"

    task_id=$(echo "$task_id" | tr '[:lower:]' '[:upper:]')

    # Search the local docs dir first.
    local hit
    hit=$(find "$docs_dir/active" "$docs_dir/completed" \
        \( -name "${task_id}-*-INC-*" -o -name "${task_id}-*-TSK-*" \) \
        2>/dev/null | head -1)
    if [[ -n "$hit" ]]; then
        echo "$hit"
        return 0
    fi

    # Worktree fallback: when invoked from a git worktree, the canonical TSK
    # may live in the main repository's docs/. Resolve via git's common dir.
    local common_git_dir
    common_git_dir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    if [[ -n "$common_git_dir" ]]; then
        # Convert relative path to absolute
        if [[ "$common_git_dir" != /* ]]; then
            common_git_dir="$(cd "$(dirname "$common_git_dir")" && pwd)/$(basename "$common_git_dir")"
        fi
        local main_repo_root
        main_repo_root=$(dirname "$common_git_dir")
        if [[ "$main_repo_root" != "$(dirname "$docs_dir")" ]] && [[ -d "$main_repo_root/docs" ]]; then
            hit=$(find "$main_repo_root/docs/active" "$main_repo_root/docs/completed" \
                \( -name "${task_id}-*-INC-*" -o -name "${task_id}-*-TSK-*" \) \
                2>/dev/null | head -1)
            [[ -n "$hit" ]] && echo "$hit"
        fi
    fi
}

# Get Task ID from filename
# Usage: get_task_id "A3F2B9-2602031430-INC-description.md"
get_task_id() {
    local filename="$1"
    echo "$filename" | grep -oE '^[A-F0-9]{6}'
}

# Backward-compatible alias
get_sequence() { get_task_id "$@"; }

# Get type from filename
# Usage: get_type "A3F2B9-2602031430-INC-description.md"
get_type() {
    local filename="$1"
    echo "$filename" | sed -E 's/^[A-F0-9]{6}-[0-9]{10,12}-([A-Z]{3,}).*/\1/'
}

# Get datetime from filename
# Usage: get_datetime "A3F2B9-2602031430-INC-description.md"
get_datetime() {
    local filename="$1"
    echo "$filename" | sed -E 's/^[A-F0-9]{6}-([0-9]{10,12})-.*/\1/'
}

# Parse datetime to human readable (handles 10-digit and legacy 12-digit)
# Usage: parse_datetime "2602031430"
parse_datetime() {
    local dt="$1"
    local year month day hour min
    if [[ ${#dt} -eq 12 ]]; then
        year="${dt:0:4}"
        month="${dt:4:2}"
        day="${dt:6:2}"
        hour="${dt:8:2}"
        min="${dt:10:2}"
    else
        year="20${dt:0:2}"
        month="${dt:2:2}"
        day="${dt:4:2}"
        hour="${dt:6:2}"
        min="${dt:8:2}"
    fi
    echo "${year}-${month}-${day} ${hour}:${min}"
}

# Find document by old-style task filename (legacy support)
find_legacy_task() {
    local legacy_name="$1"
    local docs_dir="${2:-$(find_docs_dir)}"

    if [[ -z "$docs_dir" ]]; then
        return 1
    fi

    if [[ -f "$docs_dir/tasks/$legacy_name" ]]; then
        echo "$docs_dir/tasks/$legacy_name"
        return 0
    fi

    if [[ -f "$docs_dir/tasks/completed/$legacy_name" ]]; then
        echo "$docs_dir/tasks/completed/$legacy_name"
        return 0
    fi

    return 1
}

# List all Task IDs in project
# Usage: list_task_ids [active|completed|all]
list_task_ids() {
    local filter="${1:-all}"
    local docs_dir="$(find_docs_dir)"

    if [[ -z "$docs_dir" ]]; then
        return 1
    fi

    case "$filter" in
        active)
            find "$docs_dir/active" -name "*.md" 2>/dev/null | \
                xargs -I {} basename {} | \
                grep -oE '^[A-F0-9]{6}' | sort -u
            ;;
        completed)
            find "$docs_dir/completed" -name "*.md" 2>/dev/null | \
                xargs -I {} basename {} | \
                grep -oE '^[A-F0-9]{6}' | sort -u
            ;;
        all)
            find "$docs_dir/active" "$docs_dir/completed" -name "*.md" 2>/dev/null | \
                xargs -I {} basename {} | \
                grep -oE '^[A-F0-9]{6}' | sort -u
            ;;
    esac
}

# Backward-compatible alias
list_sequences() { list_task_ids "$@"; }

# Count documents for a Task ID
# Usage: count_docs "A3F2B9"
count_docs() {
    local task_id="$1"
    find_by_id "$task_id" | wc -l
}

# Check if Task ID exists
# Usage: task_id_exists "A3F2B9"
task_id_exists() {
    local task_id="$1"
    [[ $(count_docs "$task_id") -gt 0 ]]
}

# Backward-compatible alias
sequence_exists() { task_id_exists "$@"; }

# Get work item status (active if any doc is in active/, completed otherwise)
# Usage: get_status "A3F2B9"
get_status() {
    local task_id="$1"
    local docs_dir="$(find_docs_dir)"

    task_id=$(echo "$task_id" | tr '[:lower:]' '[:upper:]')

    if find "$docs_dir/active" -name "${task_id}-*" 2>/dev/null | grep -q .; then
        echo "active"
    elif find "$docs_dir/completed" -name "${task_id}-*" 2>/dev/null | grep -q .; then
        echo "completed"
    else
        echo "unknown"
    fi
}

# Extract task info for display
# Usage: show_task_info "A3F2B9"
show_task_info() {
    local task_id="$1"
    local docs_dir="$(find_docs_dir)"

    task_id=$(echo "$task_id" | tr '[:lower:]' '[:upper:]')

    echo "Work Item: $task_id"
    echo "Status: $(get_status "$task_id")"
    echo "Documents: $(count_docs "$task_id")"
    echo ""
    echo "Files:"
    find_by_id "$task_id" | while read -r file; do
        local fname=$(basename "$file")
        local dt=$(get_datetime "$fname")
        local type=$(get_type "$fname")
        local human_dt=$(parse_datetime "$dt")
        echo "  - $human_dt $type $(basename "$file")"
    done
}

# Find Task ID by issue number (from task document content)
# Usage: find_by_issue_number 123
find_by_issue_number() {
    local issue_num="$1"
    local docs_dir="$(find_docs_dir)"

    # Search for issue number in task documents
    grep -l "Issue.*#${issue_num}" "$docs_dir"/active/*/*.md "$docs_dir"/completed/*/*.md 2>/dev/null | \
        head -1 | \
        xargs -I {} basename {} | \
        grep -oE '^[A-F0-9]{6}'
}

# Check current task and branch consistency
# Returns structured data
check_current_task() {
    if ! load_current_task; then
        return 1
    fi

    local task_id="$CT_TASK_ID"
    local expected_branch="$CT_BRANCH"
    local current_branch=$(git rev-parse --abbrev-ref HEAD)

    if [[ -z "$task_id" ]]; then
        return 2
    fi

    # Find primary doc
    local primary_doc=$(find_primary "$task_id")

    # Check match
    local match_code=0
    if [[ "$current_branch" != "$expected_branch" ]]; then
        match_code=3
    fi

    # Print results
    echo "task_id=$task_id"
    echo "expected_branch=$expected_branch"
    echo "current_branch=$current_branch"
    echo "branch_match=$([[ $match_code -eq 0 ]] && echo "true" || echo "false")"
    echo "primary_doc=$primary_doc"

    return $match_code
}

# Get document title from file content (strips "# Type: " prefix)
# Usage: get_doc_title "/path/to/doc.md"
get_doc_title() {
    local filepath="$1"
    grep -m1 "^#\s" "$filepath" | sed 's/^#\s*\(Task\|Design\|Plan\|Incident\|Audit\|Summary\|Code Review\):\s*//' || echo "Untitled"
}

# Export functions for use in other scripts (bash only, zsh auto-exports on source)
if [[ -n "$BASH_VERSION" ]]; then
    export -f find_docs_dir
    export -f find_by_id
    export -f find_by_sequence
    export -f find_primary
    export -f get_task_id
    export -f get_sequence
    export -f get_type
    export -f get_datetime
    export -f parse_datetime
    export -f find_legacy_task
    export -f list_task_ids
    export -f list_sequences
    export -f count_docs
    export -f task_id_exists
    export -f sequence_exists
    export -f get_status
    export -f show_task_info
    export -f find_by_issue_number
    export -f check_current_task
    export -f get_doc_title
fi
