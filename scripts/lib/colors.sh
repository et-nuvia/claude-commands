#!/usr/bin/env bash
# colors.sh - Terminal color codes shared by ~/.claude/scripts.
#
# Sourced by the rotate-*.sh / verify-*.sh family. Colors are emitted only when
# stdout is a TTY and NO_COLOR is unset, so JSON/piped output stays clean.

# Guard against double-sourcing.
[[ -n "${__CLAUDE_COLORS_SH_LOADED:-}" ]] && return 0
__CLAUDE_COLORS_SH_LOADED=1

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    MAGENTA=$'\033[0;35m'
    PURPLE="$MAGENTA"
    CYAN=$'\033[0;36m'
    WHITE=$'\033[0;37m'
    GRAY=$'\033[0;90m'
    GREY="$GRAY"
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
    RESET="$NC"
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' PURPLE='' CYAN='' WHITE=''
    GRAY='' GREY='' BOLD='' DIM='' NC='' RESET=''
fi

export RED GREEN YELLOW BLUE MAGENTA PURPLE CYAN WHITE GRAY GREY BOLD DIM NC RESET
