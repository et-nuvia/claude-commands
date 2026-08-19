#!/usr/bin/env bash
# worktree-sweep.sh — find stale git worktrees across ~/projects and delete the
# ones you no longer want.
#
#   worktree-sweep.sh                    interactive picker
#   worktree-sweep.sh --summarize        picker, with claude -p summaries
#   worktree-sweep.sh scan [--json]      non-interactive listing (no TUI)
#   worktree-sweep.sh summarize          just refresh the summary cache
#   worktree-sweep.sh delete <path> ...  delete by path (--force, --delete-branch)
#
# Suggested alias:  alias wts='~/.claude/scripts/worktree-sweep.sh'
#
# Classification is conservative: "empty" means no unique commits (measured by
# patch content, so squash-merged work counts as merged), a clean tree, and no
# untracked files. Anything else is "content" and is never preselected.

set -euo pipefail

readonly LIB_DIR="${HOME}/.claude/scripts/lib"

case "${1:-}" in
  scan|summarize|delete)
    exec python3 "${LIB_DIR}/worktree_sweep.py" "$@"
    ;;
  -h|--help|help)
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    exec python3 "${LIB_DIR}/worktree_sweep_tui.py" "$@"
    ;;
esac
