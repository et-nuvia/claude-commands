#!/usr/bin/env bash
# =============================================================================
# Sync Deploy Scripts Between Global and Projects
# =============================================================================
# Keeps ~/.claude/scripts/deploy/ and project scripts/deploy/ in sync
# using rsync. No submodules, no version files — just timestamps.
#
# Usage:
#   sync-deploy-scripts.sh [project-dir]       # Global -> project (default: cwd)
#   sync-deploy-scripts.sh --reverse [dir]     # Project -> global
#   sync-deploy-scripts.sh --all               # Global -> all registered projects
#   sync-deploy-scripts.sh --install-hook [dir] # Install post-commit hook only
#   sync-deploy-scripts.sh --register [dir]    # Register project only
#   sync-deploy-scripts.sh --status            # Show sync status
#
# The sync is timestamp-based (rsync --update): newer files win.
# =============================================================================

set -euo pipefail

GLOBAL_DIR="$HOME/.claude/scripts/deploy"
PROJECTS_FILE="$GLOBAL_DIR/.projects"
SCRIPT_NAME="$(basename "$0")"

# Ensure global dir exists
[[ -d "$GLOBAL_DIR" ]] || { echo "Error: $GLOBAL_DIR does not exist"; exit 1; }

# =============================================================================
# Helpers
# =============================================================================

_rsync_scripts() {
  local src="$1"
  local dst="$2"
  local label="$3"

  # Ensure trailing slashes
  src="${src%/}/"
  dst="${dst%/}/"

  # Create destination if needed
  mkdir -p "$dst" "$dst/lib"

  # rsync with --update (only copy if source is newer)
  local output
  output=$(rsync -av --update \
    --include='*.sh' \
    --include='lib/' \
    --include='lib/*.sh' \
    --exclude='.projects' \
    --exclude='config/' \
    --exclude='config/**' \
    "$src" "$dst" 2>&1)

  local changed
  changed=$(echo "$output" | grep '\.sh$' | grep -v '/$' || true)

  if [[ -n "$changed" ]]; then
    echo "  $label:"
    echo "$changed" | sed 's/^/    /'
  else
    echo "  $label: up to date"
  fi
}

_register_project() {
  local project_dir="$1"
  project_dir=$(cd "$project_dir" && pwd)

  touch "$PROJECTS_FILE"

  if ! grep -qxF "$project_dir" "$PROJECTS_FILE" 2>/dev/null; then
    echo "$project_dir" >> "$PROJECTS_FILE"
    echo "  Registered: $project_dir"
  fi
}

_install_hook() {
  local project_dir="$1"
  local hooks_dir="$project_dir/.git/hooks"

  if [[ ! -d "$project_dir/.git" ]]; then
    echo "  Warning: Not a git repo — skipping hook install"
    return 0
  fi

  mkdir -p "$hooks_dir"

  local hook_file="$hooks_dir/post-commit"
  local hook_marker="# deploy-scripts-sync"

  # Check if hook already has our section
  if [[ -f "$hook_file" ]] && grep -q "$hook_marker" "$hook_file"; then
    echo "  Hook already installed"
    return 0
  fi

  # Append to existing hook or create new one
  if [[ ! -f "$hook_file" ]]; then
    cat > "$hook_file" <<'HOOKEOF'
#!/bin/bash
HOOKEOF
  fi

  cat >> "$hook_file" <<'HOOKEOF'

# deploy-scripts-sync — auto-sync project scripts/deploy/ to global
# This hook is LOCAL ONLY (never pushed). Coworkers won't see it.
_sync_deploy_to_global() {
  local changed
  changed=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | grep '^scripts/deploy/' || true)
  if [[ -n "$changed" ]]; then
    local global_dir="$HOME/.claude/scripts/deploy"
    local project_dir
    project_dir="$(git rev-parse --show-toplevel)"
    if [[ -d "$global_dir" ]] && [[ -d "$project_dir/scripts/deploy" ]]; then
      rsync -a --update \
        --include='*.sh' \
        --include='lib/' \
        --include='lib/*.sh' \
        --exclude='.projects' \
        --exclude='config/' \
        --exclude='config/**' \
        "$project_dir/scripts/deploy/" "$global_dir/" 2>/dev/null || true
    fi
  fi
}
_sync_deploy_to_global &
HOOKEOF

  chmod +x "$hook_file"
  echo "  Hook installed: $hook_file"
}

# =============================================================================
# Commands
# =============================================================================

show_help() {
  echo "Usage: $SCRIPT_NAME [command] [project-dir]"
  echo ""
  echo "Sync deploy scripts between global (~/.claude/scripts/deploy/) and projects."
  echo ""
  echo "Commands:"
  echo "  [project-dir]           Sync global -> project (default: current dir)"
  echo "  --reverse [dir]         Sync project -> global"
  echo "  --all                   Sync global -> all registered projects"
  echo "  --install-hook [dir]    Install post-commit hook only"
  echo "  --register [dir]        Register project in .projects file"
  echo "  --status                Show sync status for all registered projects"
  echo "  -h, --help              Show this help"
}

sync_to_project() {
  local project_dir="${1:-$(pwd)}"
  project_dir=$(cd "$project_dir" && pwd)
  local scripts_dir="$project_dir/scripts/deploy"

  echo "Syncing global -> $project_dir"
  _rsync_scripts "$GLOBAL_DIR" "$scripts_dir" "Updated"
  _register_project "$project_dir"
  _install_hook "$project_dir"
  echo "  Done"
}

sync_to_global() {
  local project_dir="${1:-$(pwd)}"
  project_dir=$(cd "$project_dir" && pwd)
  local scripts_dir="$project_dir/scripts/deploy"

  if [[ ! -d "$scripts_dir" ]]; then
    echo "Error: $scripts_dir does not exist"
    exit 1
  fi

  echo "Syncing $project_dir -> global"
  _rsync_scripts "$scripts_dir" "$GLOBAL_DIR" "Updated"
  echo "  Done"
}

sync_all() {
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    echo "No projects registered. Run: $SCRIPT_NAME /path/to/project"
    exit 0
  fi

  echo "Syncing global -> all registered projects"
  echo ""

  while IFS= read -r project_dir || [[ -n "$project_dir" ]]; do
    [[ -z "$project_dir" ]] && continue
    [[ "$project_dir" =~ ^# ]] && continue

    if [[ -d "$project_dir" ]]; then
      echo "  Project: $(basename "$project_dir")"
      _rsync_scripts "$GLOBAL_DIR" "$project_dir/scripts/deploy" "  Updated"
    else
      echo "  Warning: $project_dir not found (skipping)"
    fi
  done < "$PROJECTS_FILE"

  echo ""
  echo "All projects synced"
}

show_status() {
  echo "Deploy Scripts Sync Status"
  echo "════════════════════════════════════════"
  echo ""
  echo "Global: $GLOBAL_DIR"
  echo "Scripts: $(find "$GLOBAL_DIR" -name '*.sh' | wc -l | tr -d ' ') files"
  echo ""

  if [[ ! -f "$PROJECTS_FILE" ]] || [[ ! -s "$PROJECTS_FILE" ]]; then
    echo "No projects registered"
    return
  fi

  echo "Registered projects:"
  while IFS= read -r project_dir || [[ -n "$project_dir" ]]; do
    [[ -z "$project_dir" ]] && continue
    [[ "$project_dir" =~ ^# ]] && continue

    local name
    name=$(basename "$project_dir")
    local scripts_dir="$project_dir/scripts/deploy"

    if [[ ! -d "$project_dir" ]]; then
      echo "  $name: NOT FOUND"
      continue
    fi

    if [[ ! -d "$scripts_dir" ]]; then
      echo "  $name: no scripts/deploy/ dir"
      continue
    fi

    # Check for differences
    local diff_count
    local rsync_output
    rsync_output=$(rsync -avn --update \
      --include='*.sh' \
      --include='lib/' \
      --include='lib/*.sh' \
      --exclude='.projects' \
      --exclude='config/' \
      --exclude='config/**' \
      "$GLOBAL_DIR/" "$scripts_dir/" 2>/dev/null || true)
    diff_count=$(echo "$rsync_output" | grep -c '\.sh$' || true)

    local hook_status="no hook"
    if [[ -f "$project_dir/.git/hooks/post-commit" ]] && \
       grep -q "deploy-scripts-sync" "$project_dir/.git/hooks/post-commit" 2>/dev/null; then
      hook_status="hook installed"
    fi

    if [[ "$diff_count" -eq 0 ]]; then
      echo "  $name: in sync ($hook_status)"
    else
      echo "  $name: $diff_count file(s) need update ($hook_status)"
    fi
  done < "$PROJECTS_FILE"
}

# =============================================================================
# Main
# =============================================================================

case "${1:-}" in
  --reverse)
    sync_to_global "${2:-$(pwd)}"
    ;;
  --all)
    sync_all
    ;;
  --install-hook)
    _install_hook "${2:-$(pwd)}"
    ;;
  --register)
    _register_project "${2:-$(pwd)}"
    ;;
  --status)
    show_status
    ;;
  -h|--help)
    show_help
    ;;
  "")
    sync_to_project "$(pwd)"
    ;;
  *)
    if [[ -d "$1" ]]; then
      sync_to_project "$1"
    else
      echo "Error: Unknown option or directory: $1"
      show_help
      exit 1
    fi
    ;;
esac
