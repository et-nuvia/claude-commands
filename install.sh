#!/usr/bin/env bash
# Install claude-commands into ~/.claude/ via symlinks.
#
# Idempotent: re-running updates symlinks but preserves any pre-existing
# real directories by backing them up to ~/.claude/<name>.backup-<timestamp>.
#
# Usage:
#   ./install.sh                   # install / re-link
#   ./install.sh --dry-run         # show what would happen
#   ./install.sh --uninstall       # remove symlinks (calls uninstall.sh)
#   ./install.sh --target <dir>    # install into <dir> instead of ~/.claude
#                                  # (also settable via CLAUDE_HOME env var)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
DRY_RUN=0
TS="$(date +%Y%m%d-%H%M%S)"

# Tiers to symlink into ~/.claude/. Personal/runtime state in ~/.claude/
# (projects/, memory/, settings.local.json, .credentials.json, etc.) is
# intentionally NOT touched.
LINKS=(
  "commands"
  "scripts"
  "skills"
  "templates"
  "docs"
  "profiles"
  "schemas"
  "tracking"
)

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARN: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) exec "${REPO_DIR}/uninstall.sh" ;;
    --target)
      [[ $# -ge 2 ]] || die "--target requires a directory argument"
      CLAUDE_DIR="$2"; shift ;;
    --target=*)  CLAUDE_DIR="${1#--target=}" ;;
    -h|--help)
      sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  DRY: %s\n' "$*"
  else
    eval "$@"
  fi
}

[[ -d "$CLAUDE_DIR" ]] || run "mkdir -p '$CLAUDE_DIR'"

log "repo:   $REPO_DIR"
log "target: $CLAUDE_DIR"

for name in "${LINKS[@]}"; do
  src="$REPO_DIR/$name"
  dst="$CLAUDE_DIR/$name"

  [[ -e "$src" ]] || { warn "skip $name (not in repo)"; continue; }

  if [[ -L "$dst" ]]; then
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]]; then
      log "ok     $name (already linked)"
      continue
    fi
    log "relink $name (was: $current)"
    run "rm '$dst'"
  elif [[ -e "$dst" ]]; then
    backup="$dst.backup-$TS"
    warn "$name exists as real path — backing up to $backup"
    run "mv '$dst' '$backup'"
  fi

  run "ln -s '$src' '$dst'"
  log "link   $name"
done

# First-run profile setup hint
if [[ ! -f "$CLAUDE_DIR/profiles/active.yaml" ]] && [[ "$DRY_RUN" == "0" ]]; then
  cat <<EOF

Next step: create your local profile.

  cp $CLAUDE_DIR/profiles/default.yaml.example $CLAUDE_DIR/profiles/active.yaml
  \$EDITOR $CLAUDE_DIR/profiles/active.yaml

The active.yaml file is gitignored and holds your environment-specific
values (company domain, registries, task backend, tokens).
EOF
fi

log "done"
