#!/usr/bin/env bash
# Remove symlinks created by install.sh. Personal data in ~/.claude/
# (projects/, memory/, settings.local.json) is left untouched.
#
# Usage: ./uninstall.sh [--dry-run]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
DRY_RUN=0

LINKS=(commands scripts skills templates docs profiles schemas tracking hooks .subagent-sessions logs)

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

run() {
  if [[ "$DRY_RUN" == "1" ]]; then printf '  DRY: %s\n' "$*"
  else eval "$@"; fi
}

for name in "${LINKS[@]}"; do
  dst="$CLAUDE_DIR/$name"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$REPO_DIR/$name" ]]; then
    printf '[uninstall] remove %s\n' "$dst"
    run "rm '$dst'"
  fi
done

printf '[uninstall] done (personal data preserved)\n'
