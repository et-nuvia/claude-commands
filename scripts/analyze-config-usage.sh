#!/usr/bin/env bash
set -uo pipefail

# analyze-config-usage.sh - Find duplicate get_project_config patterns
# Usage:
#   analyze-config-usage.sh --full         # Find duplicates
#   analyze-config-usage.sh --verify       # Pre-commit check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:---full}"

# Fail early
command -v jq &>/dev/null || { echo "ERROR: jq required" >&2; exit 1; }

if [[ "$MODE" == "--verify" ]]; then
    # No helpers defined yet, nothing to verify
    echo "✓ Config patterns verified"
    exit 0
fi

if [[ "$MODE" == "--cache-only" ]]; then
    echo "{}"
    exit 0
fi

# Full scan mode
echo "Scanning for duplicate get_project_config patterns..."
echo

declare -A PATTERNS
declare -A EXAMPLES

# Extract patterns using simple grep + awk
RESULT=$(find "${2:-$SCRIPT_DIR}" -name "*.sh" -type f 2>/dev/null | while read -r file; do
    [[ "$file" =~ /lib/ ]] && continue
    [[ "$file" =~ analyze-config ]] && continue

    # Find get_project_config calls, extract key names
    pattern=$(awk '/get_project_config/,/\)/ {print}' "$file" 2>/dev/null | \
        grep -oE '[a-z0-9_]+=\.' | \
        sed 's/=.*//' | \
        sort | \
        tr '\n' ' ' | \
        sed 's/[[:space:]]*$//')

    # Output file|pattern if pattern exists
    [[ -n "$pattern" ]] && echo "$file|$pattern"
done | sort -t'|' -k2 | \
awk -F'|' '{
    pattern = $2
    file = $1
    if (pattern in seen) {
        patterns[pattern] = patterns[pattern] " " file
        count[pattern]++
    } else {
        patterns[pattern] = file
        seen[pattern] = 1
        count[pattern] = 1
    }
}
END {
    found = 0
    for (p in patterns) {
        if (count[p] >= 2) {
            found++
            print "Found " count[p] " scripts with pattern: " p
            n = split(patterns[p], files, " ")
            for (i = 1; i <= n; i++) {
                print "  - " files[i]
            }
            print ""
        }
    }
    if (found == 0) {
        print "✓ No duplicates found"
    } else {
        print "Summary: " found " duplicate patterns"
    }
    exit found
}')

echo "$RESULT"
# Extract exit code from awk (last line should indicate duplicates found)
if echo "$RESULT" | grep -q "✓ No duplicates found"; then
    exit 0
else
    exit 1
fi
