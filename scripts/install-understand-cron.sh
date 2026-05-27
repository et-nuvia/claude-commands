#!/usr/bin/env bash
# install-understand-cron.sh — idempotently register the understand-auto-update cron entry
#
# Default schedule: nightly at 3am local time.
# Override: pass `--schedule '<cron-expr>'`.
# Log file: ~/.local/state/understand/auto-update.log (XDG-friendly, user-owned).
#
# Usage:
#   scripts/install-understand-cron.sh              # install if absent
#   scripts/install-understand-cron.sh --check      # report install state, no changes
#   scripts/install-understand-cron.sh --uninstall  # remove the entry
#   scripts/install-understand-cron.sh --schedule '0 4 * * *'   # custom schedule

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
SCRIPT_PATH="${CLAUDE_DIR}/scripts/understand-auto-update.sh"
LOG_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/understand"
LOG_FILE="${LOG_DIR}/auto-update.log"
TAG="# understand-auto-update (managed by install-understand-cron.sh)"

ACTION="install"
SCHEDULE="0 3 * * *"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)     ACTION="check";     shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        --schedule)  SCHEDULE="$2";      shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

if ! command -v crontab >/dev/null 2>&1; then
    echo "crontab not installed; cannot manage cron entries" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

current=$(crontab -l 2>/dev/null || true)
desired_line="${SCHEDULE} ${SCRIPT_PATH} --json --full >> ${LOG_FILE} 2>&1 ${TAG}"

already_installed=false
if printf '%s\n' "$current" | grep -Fq -- "$TAG"; then
    already_installed=true
fi

case "$ACTION" in
    check)
        if "$already_installed"; then
            printf '%s\n' "$current" | grep -F -- "$TAG"
            echo "installed: true"
        else
            echo "installed: false"
        fi
        exit 0
        ;;
    uninstall)
        if ! "$already_installed"; then
            echo "not installed; nothing to remove"
            exit 0
        fi
        new=$(printf '%s\n' "$current" | grep -Fv -- "$TAG" || true)
        printf '%s\n' "$new" | crontab -
        echo "removed cron entry"
        exit 0
        ;;
    install)
        if [[ ! -x "$SCRIPT_PATH" ]]; then
            echo "scan orchestrator not executable: $SCRIPT_PATH" >&2
            exit 1
        fi
        if "$already_installed"; then
            existing=$(printf '%s\n' "$current" | grep -F -- "$TAG")
            if [[ "$existing" == "$desired_line" ]]; then
                echo "cron entry already up-to-date; no changes"
                exit 0
            fi
            new=$(printf '%s\n' "$current" | grep -Fv -- "$TAG" || true)
        else
            new="$current"
        fi
        # Append the desired line; strip leading/trailing blank lines on the way in.
        new=$(printf '%s\n%s\n' "$new" "$desired_line" | sed '/./,$!d')
        printf '%s\n' "$new" | crontab -
        echo "installed cron entry:"
        echo "  $desired_line"
        echo "logs: $LOG_FILE"
        exit 0
        ;;
esac
