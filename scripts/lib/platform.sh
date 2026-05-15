#!/usr/bin/env bash
# platform.sh - Cross-platform helper functions
# Source this file for portable sed, date, and numfmt operations
# Works on both macOS (Darwin) and Linux

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
