#!/usr/bin/env bash
set -euo pipefail

# claude-sync.sh — Auto-commit, pull, resolve conflicts, push
#
# Designed to run via cron on both work and home machines to keep
# ~/.claude in sync. Safe to run frequently — no-ops when nothing
# has changed.
#
# Usage:
#   claude-sync.sh              # Full sync (commit + pull + push)
#   claude-sync.sh --commit     # Only commit local changes
#   claude-sync.sh --pull       # Only pull remote changes
#   claude-sync.sh --push       # Only push local commits
#   claude-sync.sh --status     # Show sync status (no changes)

CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
LOG_FILE="${CLAUDE_DIR}/scripts/.sync.log"
LOCK_FILE="/tmp/claude-sync.lock"

log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "${msg}" | tee -a "${LOG_FILE}"
}

die() {
  log "ERROR: $*"
  exit 1
}

acquire_lock() {
  if [[ -f "${LOCK_FILE}" ]]; then
    local pid
    pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      die "Another sync is running (pid ${pid})"
    fi
    rm -f "${LOCK_FILE}"
  fi
  echo $$ > "${LOCK_FILE}"
  trap 'rm -f "${LOCK_FILE}"' EXIT
}

do_commit() {
  cd "${CLAUDE_DIR}"

  if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    return 0
  fi

  local hostname
  hostname=$(hostname -s 2>/dev/null || echo "unknown")

  git add -A
  git commit -m "$(cat <<EOF
claude-config: auto-sync from ${hostname}

Automatic commit of ~/.claude changes detected by cron.
EOF
)" 2>/dev/null || true

  log "Committed local changes from ${hostname}"
}

do_pull() {
  cd "${CLAUDE_DIR}"

  git fetch origin main 2>/dev/null || die "Failed to fetch from origin"

  local local_head remote_head
  local_head=$(git rev-parse HEAD)
  remote_head=$(git rev-parse origin/main)

  if [[ "${local_head}" == "${remote_head}" ]]; then
    return 0
  fi

  if ! git pull --rebase origin main 2>/dev/null; then
    log "Conflicts detected, attempting auto-resolution..."
    resolve_conflicts
  fi

  log "Pulled remote changes"
}

resolve_conflicts() {
  cd "${CLAUDE_DIR}"

  local conflicted
  conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")

  if [[ -z "${conflicted}" ]]; then
    return 0
  fi

  while IFS= read -r file; do
    if [[ "${file}" == *.md ]]; then
      if [[ -f "${file}" ]]; then
        sed -i.bak \
          -e '/^<<<<<<< /d' \
          -e '/^=======/d' \
          -e '/^>>>>>>> /d' \
          "${file}"
        rm -f "${file}.bak"
        git add "${file}"
        log "Auto-resolved conflict in ${file} (kept both sides)"
      fi
    else
      git checkout --ours "${file}" 2>/dev/null
      git add "${file}"
      log "Auto-resolved conflict in ${file} (kept local)"
    fi
  done <<< "${conflicted}"

  git rebase --continue 2>/dev/null || git commit --no-edit 2>/dev/null || true
}

do_push() {
  cd "${CLAUDE_DIR}"

  local ahead
  ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")

  if [[ "${ahead}" -eq 0 ]]; then
    return 0
  fi

  git push origin main 2>/dev/null || die "Failed to push to origin"
  log "Pushed ${ahead} commit(s) to origin"
}

do_status() {
  cd "${CLAUDE_DIR}"

  echo "=== Claude Config Sync Status ==="
  echo "Directory: ${CLAUDE_DIR}"
  echo "Branch:    $(git branch --show-current)"
  echo "Remote:    $(git remote get-url origin)"
  echo ""

  local changes
  changes=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo "Uncommitted changes: ${changes}"

  git fetch origin main 2>/dev/null
  local ahead behind
  ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
  behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
  echo "Ahead of remote:  ${ahead}"
  echo "Behind remote:    ${behind}"

  if [[ -f "${LOG_FILE}" ]]; then
    echo ""
    echo "Last sync log entries:"
    tail -5 "${LOG_FILE}"
  fi
}

main() {
  local mode="${1:-full}"

  mkdir -p "${CLAUDE_DIR}/scripts"

  if [[ "${mode}" == "--status" ]]; then
    do_status
    return 0
  fi

  acquire_lock

  case "${mode}" in
    --commit)  do_commit ;;
    --pull)    do_pull ;;
    --push)    do_push ;;
    full|*)
      do_commit
      do_pull
      do_push
      ;;
  esac
}

main "$@"
