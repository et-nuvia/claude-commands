#!/usr/bin/env bash
set -euo pipefail

# tmux-git-status.sh — Flicker-free git status display for tmux pane
# Renders to a buffer, then overwrites the screen in one shot.

PROJECT_DIR="${1:-.}"
cd "${PROJECT_DIR}"

# Hide cursor
printf '\033[?25l'

# Restore cursor on exit
trap 'printf "\033[?25h"' EXIT

# Get terminal dimensions
get_rows() { tput lines 2>/dev/null || echo 24; }

# Initial clear
clear

while true; do
    buf=""
    buf+="\033[1;32m  Branch\033[0m\n"
    buf+="\033[90m─────────────────────\033[0m\n"
    buf+="  $(git branch --show-current 2>/dev/null || echo 'N/A')\n"
    buf+="\n"
    buf+="\033[1;32m  Recent Commits\033[0m\n"
    buf+="\033[90m─────────────────────\033[0m\n"
    buf+="$(git log --oneline --graph --decorate -12 2>/dev/null || echo '  No commits')\n"
    buf+="\n"
    buf+="\033[1;32m  Working Tree\033[0m\n"
    buf+="\033[90m─────────────────────\033[0m\n"
    working=$(git -c color.status=always status -s 2>/dev/null || echo '  Not a git repo')
    if [ -z "$working" ]; then
        buf+="  \033[90mclean\033[0m\n"
    else
        buf+="${working}\n"
    fi

    # Pad remaining lines to overwrite stale content
    rows=$(get_rows)
    line_count=$(echo -e "$buf" | wc -l)
    padding=$((rows - line_count))
    for ((i = 0; i < padding && i < 20; i++)); do
        buf+="\033[K\n"
    done

    # Move cursor to top-left and draw the buffer (no clear = no flash)
    printf '\033[H'
    printf '%b' "$buf"

    sleep 3
done
