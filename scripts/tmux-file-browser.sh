#!/usr/bin/env bash
set -euo pipefail

# tmux-file-browser.sh — Interactive navigable file tree with preview and git diff
# Runs inside a tmux pane. Browse directories, preview files, see diffs.
#
# Dependencies: fzf (required), bat (optional, for syntax highlighting)
#
# Controls:
#   Enter    — open directory / preview file full screen
#   Ctrl-d   — toggle git diff view in preview
#   Ctrl-r   — refresh listing
#   Ctrl-h   — go up to parent directory
#   Esc      — quit browser

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREVIEW_SCRIPT="${SCRIPT_DIR}/tmux-file-preview.sh"

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"
cd "${PROJECT_DIR}"

# Directories to skip
EXCLUDE_DIRS=(.git node_modules .venv vendor __pycache__ dist build .docker .next .cache coverage .turbo .pytest_cache)

# Build a single listing of files + dirs for a given path (depth 1)
list_dir() {
    local dir="${1:-.}"

    # Show ".." unless we're at project root
    if [ "$(cd "${dir}" && pwd)" != "${PROJECT_DIR}" ]; then
        echo "../"
    fi

    # Collect directories and files separately, then sort each group ascending
    {
        # Directories
        for entry in "${dir}"/*/ "${dir}"/.*/; do
            [ -d "$entry" ] || continue
            local name
            name="$(basename "$entry")"
            [ "$name" = "." ] || [ "$name" = ".." ] && continue
            local skip=false
            for exc in "${EXCLUDE_DIRS[@]}"; do
                if [ "$name" = "$exc" ]; then skip=true; break; fi
            done
            if [ "$skip" = false ]; then
                echo "${name}/"
            fi
        done
    } | sort

    {
        # Files (regular + dotfiles)
        for entry in "${dir}"/* "${dir}"/.*; do
            [ -f "$entry" ] || continue
            local name
            name="$(basename "$entry")"
            [ "$name" = "." ] || [ "$name" = ".." ] && continue
            local skip=false
            for exc in "${EXCLUDE_DIRS[@]}"; do
                if [ "$name" = "$exc" ]; then skip=true; break; fi
            done
            if [ "$skip" = false ]; then
                echo "${name}"
            fi
        done
    } | sort
}

# Preview that handles both dirs and files
dir_preview() {
    local current_dir="$1"
    local entry="$2"

    if [[ "$entry" == "../" ]]; then
        # Show parent contents
        list_dir "$(dirname "$current_dir")"
        return
    fi

    local full_path="${current_dir}/${entry}"

    if [[ "$entry" == */ ]]; then
        # Directory — show its contents
        printf '\033[1;36m  %s\033[0m\n' "$entry"
        printf '\033[90m─────────────────────\033[0m\n'
        list_dir "$full_path"
    else
        # File — use the file preview script
        "${PREVIEW_SCRIPT}" "$full_path" preview
    fi
}
export -f dir_preview 2>/dev/null || true

CURRENT_DIR="."

# Main loop
while true; do
    # Resolve to absolute then back to relative for display
    abs_current="$(cd "${CURRENT_DIR}" && pwd)"
    rel_display="${abs_current#"${PROJECT_DIR}"}"
    rel_display="${rel_display:-/}"

    # Write a temp preview script that knows the current directory
    TEMP_PREVIEW=$(mktemp)
    cat > "${TEMP_PREVIEW}" <<PEOF
#!/usr/bin/env bash
entry="\$1"
current_dir="${abs_current}"
PREVIEW_SCRIPT="${PREVIEW_SCRIPT}"

if [[ "\$entry" == "../" ]]; then
    echo "  Go up to parent directory"
    exit 0
fi

full_path="\${current_dir}/\${entry}"

if [[ "\$entry" == */ ]]; then
    printf '\033[1;36m  %s\033[0m\n' "\$entry"
    printf '\033[90m─────────────────────\033[0m\n'
    ls -1 "\$full_path" 2>/dev/null | head -40
else
    "\${PREVIEW_SCRIPT}" "\$full_path" preview
fi
PEOF
    chmod +x "${TEMP_PREVIEW}"

    # Temp diff preview script
    TEMP_DIFF=$(mktemp)
    cat > "${TEMP_DIFF}" <<DEOF
#!/usr/bin/env bash
entry="\$1"
current_dir="${abs_current}"
PREVIEW_SCRIPT="${PREVIEW_SCRIPT}"

if [[ "\$entry" == */ ]] || [[ "\$entry" == "../" ]]; then
    echo "  Diff not available for directories"
    exit 0
fi

full_path="\${current_dir}/\${entry}"
"\${PREVIEW_SCRIPT}" "\$full_path" diff
DEOF
    chmod +x "${TEMP_DIFF}"

    selected=$(list_dir "${CURRENT_DIR}" | fzf \
        --ansi \
        --preview "${TEMP_PREVIEW} {}" \
        --preview-window 'right:60%:wrap' \
        --bind "ctrl-d:preview(${TEMP_DIFF} {})" \
        --bind "ctrl-h:abort" \
        --expect "ctrl-h" \
        --header "$(printf '  \033[36m%s\033[0m  Enter: open | Ctrl-d: diff | Ctrl-h: up | Esc: quit' "${rel_display}")" \
        --color='fg:#c0caf5,bg:#1a1b26,hl:#bb9af7,fg+:#c0caf5,bg+:#292e42,hl+:#7dcfff,info:#7aa2f7,prompt:#7dcfff,pointer:#ff007c,marker:#9ece6a,spinner:#9ece6a,header:#565f89' \
        --prompt '  ' \
        --pointer '▶' \
        --marker '✓' \
        --border none \
        --margin 0 \
        --padding 0 \
    ) || { rm -f "${TEMP_PREVIEW}" "${TEMP_DIFF}"; break; }

    rm -f "${TEMP_PREVIEW}" "${TEMP_DIFF}"

    # fzf --expect outputs two lines: the key pressed, then the selection
    key=$(echo "$selected" | head -1)
    choice=$(echo "$selected" | tail -1)

    # Ctrl-h: go up
    if [ "$key" = "ctrl-h" ]; then
        if [ "${abs_current}" != "${PROJECT_DIR}" ]; then
            CURRENT_DIR="$(dirname "${CURRENT_DIR}")"
        fi
        continue
    fi

    [ -z "$choice" ] && continue

    # "../" — go up
    if [ "$choice" = "../" ]; then
        if [ "${abs_current}" != "${PROJECT_DIR}" ]; then
            CURRENT_DIR="$(dirname "${CURRENT_DIR}")"
        fi
        continue
    fi

    # Directory — drill in
    if [[ "$choice" == */ ]]; then
        CURRENT_DIR="${CURRENT_DIR}/${choice%/}"
        continue
    fi

    # File — show full screen
    full_path="${CURRENT_DIR}/${choice}"
    clear

    has_diff=""
    git diff --quiet -- "${full_path}" 2>/dev/null || has_diff="1"
    has_staged=""
    git diff --cached --quiet -- "${full_path}" 2>/dev/null || has_staged="1"

    if [ -n "${has_diff}" ] || [ -n "${has_staged}" ]; then
        "${PREVIEW_SCRIPT}" "${full_path}" diff
    else
        "${PREVIEW_SCRIPT}" "${full_path}" preview
    fi

    printf '\n\033[90m  Press any key to return to browser...\033[0m'
    read -rsn1
done

clear
printf '\033[90m  File browser closed. Press up-arrow + Enter to reopen.\033[0m\n'
