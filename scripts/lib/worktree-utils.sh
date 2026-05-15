#!/usr/bin/env bash
# worktree-utils.sh — Git worktree management for task lifecycle scripts
#
# Provides 7 functions per DSN 85456E Decision 10:
#   is_in_worktree         — detect if running inside a linked worktree
#   get_worktree_root      — current worktree root path (main or linked)
#   get_main_checkout      — main checkout path (even from linked worktree)
#   create_task_worktree   — create .worktrees/<task_id> with branch
#   remove_task_worktree   — remove .worktrees/<task_id> and prune
#   get_worktree_path      — get path for a task_id, empty if none
#   list_task_worktrees    — list active .worktrees/<id> entries
#
# Designed to be sourced. No `set -e` — caller controls error handling.

# ─── is_in_worktree ──────────────────────────────────────────────────────────
# Returns 0 if running inside a linked worktree (not the main checkout).
# A linked worktree has a .git FILE (not directory) pointing to the main repo's
# .git/worktrees/<name>/ subdirectory.
is_in_worktree() {
    local git_dir common_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    # In main checkout: git-dir == common-dir (both are ".git" or absolute path to .git)
    # In linked worktree: git-dir points to .git/worktrees/<name>, common-dir points to .git
    # Normalize to absolute paths for reliable comparison
    git_dir=$(cd "$git_dir" 2>/dev/null && pwd) || return 1
    common_dir=$(cd "$common_dir" 2>/dev/null && pwd) || return 1
    [[ "$git_dir" != "$common_dir" ]]
}

# ─── get_worktree_root ────────────────────────────────────────────────────────
# Echoes the root path of the current worktree (works for both main and linked).
# In a linked worktree, this returns the worktree's root, NOT the main checkout.
get_worktree_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# ─── get_main_checkout ────────────────────────────────────────────────────────
# Echoes the main checkout path, even when called from a linked worktree.
# Uses --git-common-dir which always points to the main repo's .git directory.
get_main_checkout() {
    local common_dir
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    # common_dir is the path to .git (main checkout) or an absolute .git path
    # If it's a relative path like ".git", resolve it
    common_dir=$(cd "$common_dir" 2>/dev/null && pwd) || return 1
    # Strip the trailing /.git to get the checkout root
    # Handle both "/path/to/repo/.git" and "/path/to/repo/.git/" patterns
    echo "${common_dir%/.git}"
}

# ─── create_task_worktree ────────────────────────────────────────────────────
# Creates a linked worktree at .worktrees/<task_id> on a new branch.
# Args: $1 = task_id, $2 = branch_name
# Echoes the new worktree path. Creates .worktrees/ dir if needed.
# Adds .worktrees/ to .gitignore if not already present (DSN Decision 13).
create_task_worktree() {
    local task_id="$1"
    local branch_name="$2"
    local main_root worktree_base worktree_path

    main_root=$(get_main_checkout) || return 1
    worktree_base="${main_root}/.worktrees"
    worktree_path="${worktree_base}/${task_id}"

    # Create .worktrees/ directory
    mkdir -p "$worktree_base"

    # Add .worktrees/ to .gitignore if not present (per-repo fallback, DSN Decision 13)
    local gitignore="${main_root}/.gitignore"
    if [[ ! -f "$gitignore" ]] || ! grep -q '^\.worktrees/$' "$gitignore" 2>/dev/null; then
        echo ".worktrees/" >> "$gitignore"
    fi

    # Create the worktree with a new branch (suppress git output to avoid polluting echo)
    git -C "$main_root" worktree add "$worktree_path" -b "$branch_name" >/dev/null 2>&1 || {
        # Branch might already exist (e.g., resuming) — try without -b
        git -C "$main_root" worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1 || return 1
    }

    echo "$worktree_path"
}

# ─── remove_task_worktree ────────────────────────────────────────────────────
# Removes .worktrees/<task_id> and prunes stale worktree entries.
# Idempotent — no error if already gone.
remove_task_worktree() {
    local task_id="$1"
    local main_root worktree_path

    main_root=$(get_main_checkout) || return 0
    worktree_path="${main_root}/.worktrees/${task_id}"

    if [[ -d "$worktree_path" ]]; then
        git -C "$main_root" worktree remove --force "$worktree_path" 2>/dev/null || {
            # Force remove the directory if git worktree remove fails
            rm -rf "$worktree_path" 2>/dev/null || true
        }
    fi

    # Prune stale worktree entries
    git -C "$main_root" worktree prune 2>/dev/null || true
}

# ─── get_worktree_path ────────────────────────────────────────────────────────
# Echoes the worktree path for a task_id, or empty string if none exists.
get_worktree_path() {
    local task_id="$1"
    local main_root worktree_path

    main_root=$(get_main_checkout) || return 0
    worktree_path="${main_root}/.worktrees/${task_id}"

    if [[ -d "$worktree_path" ]]; then
        echo "$worktree_path"
    fi
}

# ─── list_task_worktrees ─────────────────────────────────────────────────────
# Lists all active task worktree IDs (directory names under .worktrees/).
list_task_worktrees() {
    local main_root worktree_base

    main_root=$(get_main_checkout) || return 0
    worktree_base="${main_root}/.worktrees"

    [[ -d "$worktree_base" ]] || return 0

    local entry
    for entry in "$worktree_base"/*/; do
        [[ -d "$entry" ]] || continue
        basename "$entry"
    done
}
