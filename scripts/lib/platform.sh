#!/usr/bin/env bash
# platform.sh - Cross-platform helper functions
# Source this file for portable sed, date, and numfmt operations
# Works on both macOS (Darwin) and Linux

# Kernel/OS axis only — darwin | linux | wsl | unknown.
#
# This answers "what syntax and capabilities does this machine have"
# (sed -i '', date -v, launchd vs systemd), NEVER "which environment am I
# in". Policy — git host, registry, secrets backend, task tracker, deploy
# method — is declared in the profile; read it via load-profile.sh, not here.
__env_platform_cache=""
env_platform() {
    if [[ -n "$__env_platform_cache" ]]; then
        printf '%s\n' "$__env_platform_cache"
        return 0
    fi
    local kernel
    kernel=$(uname -s 2>/dev/null || echo unknown)
    case "$kernel" in
        Darwin) __env_platform_cache="darwin" ;;
        Linux)
            # Both WSL1 and WSL2 stamp the marker into the kernel release
            # string; /proc/version is the fallback for older builds.
            if [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]] \
               || grep -qi microsoft /proc/version 2>/dev/null; then
                __env_platform_cache="wsl"
            else
                __env_platform_cache="linux"
            fi
            ;;
        *) __env_platform_cache="unknown" ;;
    esac
    printf '%s\n' "$__env_platform_cache"
}

# Portable sed -i (macOS requires '' argument)
# Usage: sedi 's/foo/bar/' file.txt
sedi() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Portable relative date calculation
# Usage: portable_date_relative -3       # 3 days ago
#        portable_date_relative 7 "%Y-%m-%d"  # 7 days from now
portable_date_relative() {
    local days="$1"
    local format="${2:-%Y-%m-%d}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS date -v requires explicit +/- prefix; bare numbers need +
        [[ "$days" =~ ^[0-9] ]] && days="+${days}"
        date -v "${days}d" "+$format"
    else
        date -d "${days} days" "+$format"
    fi
}

# Portable epoch-to-date conversion
# Usage: portable_date_parse 1709251200
#        portable_date_parse 1709251200 "%Y-%m-%d %H:%M"
portable_date_parse() {
    local epoch="$1"
    local format="${2:-%Y-%m-%d}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        date -r "$epoch" "+$format"
    else
        date -d "@$epoch" "+$format"
    fi
}

# Portable human-readable byte formatting (numfmt fallback)
# Usage: human_bytes 1048576  → "1.0MiB"
human_bytes() {
    local bytes="$1"
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec-i --suffix=B "$bytes"
    else
        awk -v b="$bytes" 'BEGIN {split("B KiB MiB GiB TiB",u); for(i=1;b>=1024&&i<5;i++)b/=1024; printf "%.1f%s",b,u[i]}'
    fi
}
