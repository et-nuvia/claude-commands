#!/usr/bin/env bash
set -euo pipefail

# scripts/version.sh - Git tag-based semantic version management
# Usage: ./scripts/version.sh [--command <show|calculate|create>] [--message <msg>]
#   Commands:
#     show              - Display current version from latest git tag
#     calculate         - Calculate next version based on commits since last tag
#     create            - Create git tag for current version (use after successful production deployment)

COMMAND="show"
MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command) COMMAND="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--command <show|bump-major|bump-minor|bump-patch|set>] [--message <msg>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get latest git tag (or default to v0.0.0 if no tags exist)
# Uses git tag -l (repo-wide) instead of git describe (branch-ancestry only)
# because tags created on prod aren't ancestors of staging/dev with squash merges
get_latest_tag() {
    local latest_tag=$(git tag -l "v*.*.*" --sort=-v:refname | head -1)

    if [[ -z "$latest_tag" ]]; then
        echo "v0.0.0"
    else
        echo "$latest_tag"
    fi
}

# Remove 'v' prefix from tag
strip_v_prefix() {
    local tag=$1
    echo "${tag#v}"
}

# Validate semantic version format
validate_version() {
    local version=$1
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid semantic version: $version"
        echo "Expected format: major.minor.patch (e.g., 1.2.3)"
        exit 1
    fi
}

# Parse semantic version into components
parse_version() {
    local version=$1
    MAJOR=$(echo "$version" | cut -d. -f1)
    MINOR=$(echo "$version" | cut -d. -f2)
    PATCH=$(echo "$version" | cut -d. -f3)
}

# Detect version bump type from conventional commits
# Parses both commit subjects AND bodies for semantic information
# Supports git trailers for explicit version control
detect_bump_type() {
    local commits=$1

    # Check for explicit version override via git trailer
    # Version-Bump: major|minor|patch takes precedence over all other logic
    if echo "$commits" | grep -qE "^Version-Bump: *(major|minor|patch)"; then
        local override=$(echo "$commits" | grep -oE "^Version-Bump: *(major|minor|patch)" | head -1 | awk '{print $2}')
        echo "$override"
        return
    fi

    # Check for breaking changes in subject (type!) or body (BREAKING CHANGE:)
    if echo "$commits" | grep -qiE "^[^:]+!:|BREAKING CHANGE:"; then
        echo "major"
        return
    fi

    # Check for Changelog trailer indicating breaking change
    if echo "$commits" | grep -qE "^Changelog: *breaking"; then
        echo "major"
        return
    fi

    # Check for features in subject (feat:) or Changelog trailer
    if echo "$commits" | grep -qiE "^feat(\(.+\))?:|^Changelog: *feature"; then
        echo "minor"
        return
    fi

    # Check for fixes in subject (fix:) or Changelog trailer
    if echo "$commits" | grep -qiE "^fix(\(.+\))?:|^Changelog: *fix"; then
        echo "patch"
        return
    fi

    # Default to patch for any commits (chore, docs, refactor, etc.)
    echo "patch"
}

# Calculate next version based on commits since last tag
# Now parses BOTH subject and body to extract semantic information from squash merges
calculate_next_version() {
    local last_tag=$(get_latest_tag)
    local current_version=$(strip_v_prefix "$last_tag")

    # Get commits since last tag - NOW INCLUDING BODY
    # Format: subject + body separated by --- for easier parsing
    local commits
    if [[ "$last_tag" == "v0.0.0" ]]; then
        commits=$(git log --pretty=format:"%s%n%b%n---" 2>/dev/null || echo "")
    else
        commits=$(git log ${last_tag}..HEAD --pretty=format:"%s%n%b%n---" 2>/dev/null || echo "")
    fi

    # If no new commits, return current version
    if [[ -z "$commits" ]]; then
        echo "$current_version"
        return
    fi

    # Detect bump type from commits (subjects + bodies + trailers)
    local bump_type=$(detect_bump_type "$commits")

    # Parse current version
    parse_version "$current_version"

    # Calculate new version
    case "$bump_type" in
        major)
            MAJOR=$((MAJOR + 1))
            MINOR=0
            PATCH=0
            ;;
        minor)
            MINOR=$((MINOR + 1))
            PATCH=0
            ;;
        patch)
            PATCH=$((PATCH + 1))
            ;;
    esac

    echo "${MAJOR}.${MINOR}.${PATCH}"
}

case "$COMMAND" in
    show)
        LATEST_TAG=$(get_latest_tag)
        CURRENT_VERSION=$(strip_v_prefix "$LATEST_TAG")

        if [[ "$LATEST_TAG" == "v0.0.0" ]]; then
            echo "${CURRENT_VERSION} (no tags found)"
        else
            echo "${CURRENT_VERSION}"
        fi
        ;;

    calculate)
        LAST_TAG=$(get_latest_tag)
        CURRENT_VERSION=$(strip_v_prefix "$LAST_TAG")
        NEXT_VERSION=$(calculate_next_version)

        echo "Current version (from git tag): ${CURRENT_VERSION}"
        echo ""

        # Get commits since last tag for display
        if [[ "$LAST_TAG" == "v0.0.0" ]]; then
            COMMITS=$(git log --oneline 2>/dev/null || echo "")
        else
            COMMITS=$(git log ${LAST_TAG}..HEAD --oneline 2>/dev/null || echo "")
        fi

        if [[ -z "$COMMITS" ]]; then
            echo "No new commits since last tag"
            echo "Next version: ${CURRENT_VERSION} (no change)"
        else
            echo "Commits since ${LAST_TAG}:"
            echo "$COMMITS" | head -10
            if [[ $(echo "$COMMITS" | wc -l) -gt 10 ]]; then
                echo "... and $(($(echo "$COMMITS" | wc -l) - 10)) more"
            fi
            echo ""

            # Detect bump type
            BUMP_TYPE=$(detect_bump_type "$COMMITS")
            echo "Detected: ${BUMP_TYPE} bump"
            echo ""
            echo -e "${GREEN}Next version: ${NEXT_VERSION}${NC}"
        fi
        ;;

    create)
        if [[ -z "$MESSAGE" ]]; then
            echo "Error: Tag message required"
            echo "Usage: ./scripts/version.sh --command create --message \"Production release description\""
            exit 1
        fi

        # Calculate version
        NEXT_VERSION=$(calculate_next_version)
        TAG_NAME="v${NEXT_VERSION}"

        # Check if tag already exists
        if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
            echo "Error: Tag $TAG_NAME already exists"
            exit 1
        fi

        # Create annotated tag
        git tag -a "$TAG_NAME" -m "${MESSAGE}"

        echo -e "${GREEN}✓ Created git tag: ${TAG_NAME}${NC}"
        echo ""
        echo "Next steps:"
        echo "  1. Push tag: git push origin ${TAG_NAME}"
        echo "  2. Tag will be visible in GitLab/GitHub releases"
        ;;

    *)
        echo "Error: Unknown command: $COMMAND"
        echo ""
        echo "Usage: ./scripts/version.sh [--command <show|calculate|create>] [--message <msg>]"
        echo ""
        echo "Commands:"
        echo "  show                      Display current version from latest git tag"
        echo "  calculate                 Calculate next version based on commits"
        echo "  create                    Create git tag (use after production deployment, requires --message)"
        echo ""
        echo "Examples:"
        echo "  ./scripts/version.sh --command show"
        echo "  ./scripts/version.sh --command calculate"
        echo "  ./scripts/version.sh --command create --message \"Production release 1.2.3\""
        echo ""
        echo "How it works:"
        echo "  - Git tags are the single source of truth for versions"
        echo "  - Conventional commits determine version bump type:"
        echo "    - BREAKING CHANGE or ! → major bump (1.2.3 → 2.0.0)"
        echo "    - feat: → minor bump (1.2.3 → 1.3.0)"
        echo "    - fix: → patch bump (1.2.3 → 1.2.4)"
        echo "  - Tags created automatically by CI/CD after successful production deployment"
        exit 1
        ;;
esac
