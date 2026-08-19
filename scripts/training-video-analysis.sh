#!/usr/bin/env bash
set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: requires bash >= 4 (on macOS: brew install bash)" >&2
  exit 1
fi

# Training Video Impact Analysis
# Analyzes code changes to determine which training videos need updating
# Usage: ./scripts/training-video-analysis.sh --from-version <ver> --to-version <ver>
# Copy to project: cp ~/.claude/scripts/training-video-analysis.sh ./scripts/

# Enable bash array compatibility in zsh
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt KSH_ARRAYS
fi

FROM_VERSION=""
TO_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-version) FROM_VERSION="$2"; shift 2 ;;
    --to-version)   TO_VERSION="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 --from-version <ver> --to-version <ver>" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$FROM_VERSION" || -z "$TO_VERSION" ]]; then
  echo "Error: --from-version and --to-version are required" >&2
  echo "Usage: $0 --from-version <ver> --to-version <ver>" >&2
  exit 1
fi

MANIFEST_FILE="training-videos.yaml"
REPORT_FILE="training-video-impact-report.md"
UPDATES_FILE="training-video-updates-required.txt"

# Colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# Check prerequisites
# ─────────────────────────────────────────────────────────────
if [[ ! -f "${MANIFEST_FILE}" ]]; then
    echo -e "${RED}Error: ${MANIFEST_FILE} not found${NC}"
    echo "Create a training video manifest first. See /training-videos skill."
    exit 1
fi

if ! command -v yq &> /dev/null; then
    echo -e "${YELLOW}Warning: yq not installed, using basic parsing${NC}"
    USE_YQ=false
else
    USE_YQ=true
fi

# ─────────────────────────────────────────────────────────────
# Get changed files
# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}Analyzing changes from ${FROM_VERSION} to ${TO_VERSION}...${NC}"

CHANGED_FILES=$(git diff --name-only "${FROM_VERSION}..${TO_VERSION}" 2>/dev/null || {
    echo -e "${RED}Error: Could not get diff between versions${NC}"
    exit 1
})

if [[ -z "${CHANGED_FILES}" ]]; then
    echo -e "${GREEN}No files changed between versions${NC}"
    exit 0
fi

CHANGED_COUNT=$(echo "${CHANGED_FILES}" | wc -l | tr -d ' ')
echo -e "Found ${CHANGED_COUNT} changed files"

# ─────────────────────────────────────────────────────────────
# Parse manifest and analyze impact
# ─────────────────────────────────────────────────────────────

# Arrays to hold results
declare -A HIGH_PRIORITY
declare -A MEDIUM_PRIORITY
declare -A LOW_PRIORITY
declare -A NO_CHANGES
declare -A VIDEO_TITLES
declare -A VIDEO_LAST_VERSION
declare -A VIDEO_CHANGES

# Parse videos from manifest (simplified without yq)
parse_manifest() {
    local current_video=""
    local in_files=false
    local in_features=false
    local in_components=false
    local in_endpoints=false

    while IFS= read -r line; do
        # Video ID
        if [[ "${line}" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"?([^\"]+)\"? ]]; then
            current_video="${BASH_REMATCH[1]}"
            VIDEO_CHANGES["${current_video}"]=""
        fi

        # Title
        if [[ -n "${current_video}" && "${line}" =~ ^[[:space:]]*title:[[:space:]]*\"?([^\"]+)\"? ]]; then
            VIDEO_TITLES["${current_video}"]="${BASH_REMATCH[1]}"
        fi

        # Last updated version
        if [[ -n "${current_video}" && "${line}" =~ ^[[:space:]]*last_updated_version:[[:space:]]*\"?([^\"]+)\"? ]]; then
            VIDEO_LAST_VERSION["${current_video}"]="${BASH_REMATCH[1]}"
        fi

        # Track sections
        if [[ "${line}" =~ ^[[:space:]]*files: ]]; then
            in_files=true
            in_features=false
            in_components=false
            in_endpoints=false
        elif [[ "${line}" =~ ^[[:space:]]*features: ]]; then
            in_files=false
            in_features=true
            in_components=false
            in_endpoints=false
        elif [[ "${line}" =~ ^[[:space:]]*components: ]]; then
            in_files=false
            in_features=false
            in_components=true
            in_endpoints=false
        elif [[ "${line}" =~ ^[[:space:]]*endpoints: ]]; then
            in_files=false
            in_features=false
            in_components=false
            in_endpoints=true
        elif [[ "${line}" =~ ^[[:space:]]*[a-z_]+: && ! "${line}" =~ ^[[:space:]]*- ]]; then
            in_files=false
            in_features=false
            in_components=false
            in_endpoints=false
        fi

        # Parse file patterns
        if [[ "${in_files}" == true && "${line}" =~ ^[[:space:]]*-[[:space:]]*\"?([^\"]+)\"? ]]; then
            local pattern="${BASH_REMATCH[1]}"
            check_pattern_match "${current_video}" "${pattern}" "CONTENT"
        fi

        # Parse components
        if [[ "${in_components}" == true && "${line}" =~ ^[[:space:]]*-[[:space:]]*\"?([^\"]+)\"? ]]; then
            local component="${BASH_REMATCH[1]}"
            check_component_match "${current_video}" "${component}"
        fi

    done < "${MANIFEST_FILE}"
}

check_pattern_match() {
    local video="$1"
    local pattern="$2"
    local change_type="$3"

    # Convert glob to regex
    local regex="${pattern//\*\*/.*}"
    regex="${regex//\*/[^/]*}"

    while IFS= read -r changed_file; do
        if [[ "${changed_file}" =~ ${regex} ]]; then
            VIDEO_CHANGES["${video}"]+="${change_type}: ${changed_file}\n"
        fi
    done <<< "${CHANGED_FILES}"
}

check_component_match() {
    local video="$1"
    local component="$2"

    while IFS= read -r changed_file; do
        if [[ "${changed_file}" =~ ${component} ]]; then
            VIDEO_CHANGES["${video}"]+="FUNCTIONALITY: ${component} (${changed_file})\n"
        fi
    done <<< "${CHANGED_FILES}"
}

# Run analysis
parse_manifest

# ─────────────────────────────────────────────────────────────
# Categorize results by priority
# ─────────────────────────────────────────────────────────────
for video in "${!VIDEO_TITLES[@]}"; do
    changes="${VIDEO_CHANGES[${video}]:-}"

    if [[ -z "${changes}" ]]; then
        NO_CHANGES["${video}"]=1
    elif [[ "${changes}" =~ CONTENT ]]; then
        HIGH_PRIORITY["${video}"]=1
    elif [[ "${changes}" =~ FUNCTIONALITY ]]; then
        MEDIUM_PRIORITY["${video}"]=1
    else
        LOW_PRIORITY["${video}"]=1
    fi
done

# ─────────────────────────────────────────────────────────────
# Generate report
# ─────────────────────────────────────────────────────────────
{
    echo "# Training Video Impact Analysis"
    echo ""
    echo "**Comparing:** ${FROM_VERSION} → ${TO_VERSION}"
    echo "**Generated:** $(date -Iseconds)"
    echo "**Changed files:** ${CHANGED_COUNT}"
    echo ""

    if [[ ${#HIGH_PRIORITY[@]} -gt 0 ]]; then
        echo "## ⚠️ High Priority - Direct Content Changes"
        echo ""
        for video in "${!HIGH_PRIORITY[@]}"; do
            echo "### ${VIDEO_TITLES[${video}]}"
            echo "- **Video ID:** ${video}"
            echo "- **Last Updated:** ${VIDEO_LAST_VERSION[${video}]:-unknown}"
            echo "- **Changes:**"
            echo -e "${VIDEO_CHANGES[${video}]}" | sed 's/^/  - /'
            echo ""
        done
    fi

    if [[ ${#MEDIUM_PRIORITY[@]} -gt 0 ]]; then
        echo "## ⚡ Medium Priority - Functionality Changes"
        echo ""
        for video in "${!MEDIUM_PRIORITY[@]}"; do
            echo "### ${VIDEO_TITLES[${video}]}"
            echo "- **Video ID:** ${video}"
            echo "- **Last Updated:** ${VIDEO_LAST_VERSION[${video}]:-unknown}"
            echo "- **Changes:**"
            echo -e "${VIDEO_CHANGES[${video}]}" | sed 's/^/  - /'
            echo ""
        done
    fi

    if [[ ${#LOW_PRIORITY[@]} -gt 0 ]]; then
        echo "## 📝 Low Priority - Indirect Changes"
        echo ""
        for video in "${!LOW_PRIORITY[@]}"; do
            echo "### ${VIDEO_TITLES[${video}]}"
            echo "- **Video ID:** ${video}"
            echo "- **Last Updated:** ${VIDEO_LAST_VERSION[${video}]:-unknown}"
            echo "- **Changes:**"
            echo -e "${VIDEO_CHANGES[${video}]}" | sed 's/^/  - /'
            echo ""
        done
    fi

    if [[ ${#NO_CHANGES[@]} -gt 0 ]]; then
        echo "## ✅ No Changes Detected"
        echo ""
        for video in "${!NO_CHANGES[@]}"; do
            echo "- ${VIDEO_TITLES[${video}]} (${video})"
        done
        echo ""
    fi

    echo "## Summary"
    echo ""
    echo "| Priority | Count |"
    echo "|----------|-------|"
    echo "| High (Content) | ${#HIGH_PRIORITY[@]} |"
    echo "| Medium (Functionality) | ${#MEDIUM_PRIORITY[@]} |"
    echo "| Low (Indirect) | ${#LOW_PRIORITY[@]} |"
    echo "| No Changes | ${#NO_CHANGES[@]} |"
    echo "| **Total** | **$((${#HIGH_PRIORITY[@]} + ${#MEDIUM_PRIORITY[@]} + ${#LOW_PRIORITY[@]} + ${#NO_CHANGES[@]}))** |"

} > "${REPORT_FILE}"

# ─────────────────────────────────────────────────────────────
# Generate updates required file (for CI)
# ─────────────────────────────────────────────────────────────
{
    for video in "${!HIGH_PRIORITY[@]}"; do
        echo "HIGH:${video}"
    done
    for video in "${!MEDIUM_PRIORITY[@]}"; do
        echo "MEDIUM:${video}"
    done
    for video in "${!LOW_PRIORITY[@]}"; do
        echo "LOW:${video}"
    done
} > "${UPDATES_FILE}"

# ─────────────────────────────────────────────────────────────
# Print summary to console
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  TRAINING VIDEO IMPACT ANALYSIS${NC}"
echo -e "${BOLD}  ${FROM_VERSION} → ${TO_VERSION}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [[ ${#HIGH_PRIORITY[@]} -gt 0 ]]; then
    echo -e "${RED}⚠️  HIGH PRIORITY (${#HIGH_PRIORITY[@]}):${NC}"
    for video in "${!HIGH_PRIORITY[@]}"; do
        echo -e "   ${RED}•${NC} ${VIDEO_TITLES[${video}]} (${video})"
    done
    echo ""
fi

if [[ ${#MEDIUM_PRIORITY[@]} -gt 0 ]]; then
    echo -e "${YELLOW}⚡ MEDIUM PRIORITY (${#MEDIUM_PRIORITY[@]}):${NC}"
    for video in "${!MEDIUM_PRIORITY[@]}"; do
        echo -e "   ${YELLOW}•${NC} ${VIDEO_TITLES[${video}]} (${video})"
    done
    echo ""
fi

if [[ ${#LOW_PRIORITY[@]} -gt 0 ]]; then
    echo -e "${BLUE}📝 LOW PRIORITY (${#LOW_PRIORITY[@]}):${NC}"
    for video in "${!LOW_PRIORITY[@]}"; do
        echo -e "   ${BLUE}•${NC} ${VIDEO_TITLES[${video}]} (${video})"
    done
    echo ""
fi

TOTAL_UPDATES=$((${#HIGH_PRIORITY[@]} + ${#MEDIUM_PRIORITY[@]} + ${#LOW_PRIORITY[@]}))

if [[ ${TOTAL_UPDATES} -eq 0 ]]; then
    echo -e "${GREEN}✓ No training videos need updating${NC}"
else
    echo -e "📄 Full report: ${REPORT_FILE}"
    echo -e "📋 Update list: ${UPDATES_FILE}"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"

# Exit with code indicating if updates needed
if [[ ${#HIGH_PRIORITY[@]} -gt 0 ]]; then
    exit 2  # High priority updates needed
elif [[ ${TOTAL_UPDATES} -gt 0 ]]; then
    exit 1  # Some updates needed
else
    exit 0  # No updates needed
fi
