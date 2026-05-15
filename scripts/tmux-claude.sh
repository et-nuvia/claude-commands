#!/usr/bin/env bash
set -euo pipefail

# tmux-claude.sh — Immersive Claude Code tmux layout
# Usage: tmux-claude.sh [project-dir]
#
# Dependencies: tmux, fzf (required), bat (optional — syntax highlighting)
# Install:  brew install fzf bat
#
# Layout:
# ┌──────────────────────────────────────────────────┐
# │  Project Banner + Shortcuts                      │
# ├─────────────────────────────┬────────────────────┤
# │                             │ Interactive File   │
# │                             │ Browser (fzf)      │
# │     Claude Code             ├────────────────────┤
# │     (main pane)             │   Git Info         │
# │                             │   (auto-refresh)   │
# │                             ├────────────────────┤
# │                             │ [Console] [Docker] │
# └─────────────────────────────┴────────────────────┘

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"
PROJECT_NAME="$(basename "${PROJECT_DIR}")"
SESSION_NAME="claude-${PROJECT_NAME}"

# Check dependencies
if ! command -v tmux &>/dev/null; then
    echo "Error: tmux is required. Install with: brew install tmux"
    exit 1
fi
if ! command -v fzf &>/dev/null; then
    echo "Error: fzf is required for the interactive file browser."
    echo "Install with: brew install fzf"
    exit 1
fi
if ! command -v bat &>/dev/null; then
    echo "Note: bat is optional but recommended for syntax highlighting."
    echo "Install with: brew install bat"
    echo ""
fi

# Kill existing session if present
tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true

# Create session — top banner pane
tmux new-session -d -s "${SESSION_NAME}" -c "${PROJECT_DIR}" -x "$(tput cols)" -y "$(tput lines)"

# Banner: static display
BANNER_LINE=$(printf '%.0s─' {1..120})
tmux send-keys "clear && printf '\\033[1;36m${BANNER_LINE}\\n  %-45s%s\\n${BANNER_LINE}\\033[0m\\n' '${PROJECT_NAME}' 'C-b z: zoom | C-b arrows: nav | C-b d: detach | Tabs: 1=Console 2=Docker q=quit'" C-m

# Split below the banner for the main workspace (banner keeps ~3 lines)
tmux split-window -v -l 90% -c "${PROJECT_DIR}"

# This is the main left pane — split right column off it (35% width)
tmux split-window -h -l 35% -c "${PROJECT_DIR}"

# Top-right: interactive file browser
tmux send-keys "${SCRIPT_DIR}/tmux-file-browser.sh '${PROJECT_DIR}'" C-m

# Middle-right: git info (auto-refreshing, flicker-free)
tmux split-window -v -l 60% -c "${PROJECT_DIR}"
tmux send-keys "${SCRIPT_DIR}/tmux-git-status.sh '${PROJECT_DIR}'" C-m

# Bottom-right: tabbed view (Console | Docker)
tmux split-window -v -l 30% -c "${PROJECT_DIR}"
tmux send-keys "${SCRIPT_DIR}/tmux-tabbed-pane.sh '${PROJECT_DIR}'" C-m

# Focus on main Claude Code pane and launch it
tmux select-pane -t 1
tmux send-keys "claude" C-m

# Enable mouse support for clicking between panes
tmux set-option -t "${SESSION_NAME}" mouse on

# Attach to session
tmux attach-session -t "${SESSION_NAME}"
