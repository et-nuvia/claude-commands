#!/usr/bin/env bash
# tmux-file-preview.sh — Preview script called by fzf
# Usage: tmux-file-preview.sh <file> [diff]
set -euo pipefail

file="${1:-}"
mode="${2:-preview}"

if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "  No file selected"
    exit 0
fi

# Header
printf '\033[1;36m'
printf '%.0s─' {1..60}
printf '\n  %s\n' "$file"
printf '%.0s─' {1..60}
printf '\033[0m\n'

if [ "$mode" = "diff" ]; then
    # Diff mode
    unstaged=$(git diff -- "$file" 2>/dev/null || true)
    staged=$(git diff --cached -- "$file" 2>/dev/null || true)

    if [ -n "$unstaged" ]; then
        printf '\033[1;33m  Unstaged Changes\033[0m\n'
        printf '\033[90m─────────────────────\033[0m\n'
        if command -v bat &>/dev/null; then
            echo "$unstaged" | bat --color=always -l diff --style=plain
        else
            echo "$unstaged"
        fi
        echo ""
    fi

    if [ -n "$staged" ]; then
        printf '\033[1;32m  Staged Changes\033[0m\n'
        printf '\033[90m─────────────────────\033[0m\n'
        if command -v bat &>/dev/null; then
            echo "$staged" | bat --color=always -l diff --style=plain
        else
            echo "$staged"
        fi
        echo ""
    fi

    if [ -z "$unstaged" ] && [ -z "$staged" ]; then
        printf '\033[90m  No changes for this file.\033[0m\n\n'
        # Fall through to show file contents
        mode="preview"
    fi
fi

if [ "$mode" = "preview" ]; then
    # Status badges
    has_diff=""
    has_staged=""
    git diff --quiet -- "$file" 2>/dev/null || has_diff="1"
    git diff --cached --quiet -- "$file" 2>/dev/null || has_staged="1"

    if [ -n "$has_diff" ] && [ -n "$has_staged" ]; then
        printf '\033[1;33m  ● UNSTAGED\033[0m  \033[1;32m● STAGED\033[0m\n\n'
    elif [ -n "$has_diff" ]; then
        printf '\033[1;33m  ● UNSTAGED CHANGES\033[0m\n\n'
    elif [ -n "$has_staged" ]; then
        printf '\033[1;32m  ● STAGED CHANGES\033[0m\n\n'
    fi

    if command -v bat &>/dev/null; then
        bat --color=always --style=numbers,changes --line-range=:300 -- "$file" 2>/dev/null
    else
        cat -n "$file" 2>/dev/null | head -300
    fi
fi
