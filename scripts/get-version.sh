#!/usr/bin/env bash
set -euo pipefail

# get-version.sh - Get version from git tags or legacy version files
# PRIMARY: Git tags (conventional commits)
# FALLBACK: Version files (for projects not using git tags yet)

# Capture script name early (before functions, where $0 may change in zsh)
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Usage function
usage() {
  cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Get version from git tags (primary) or version files (legacy fallback)

VERSION STRATEGY:
  1. Git tags (RECOMMENDED): Uses git describe --tags
  2. Version files (LEGACY): Falls back to PROJECT.yaml version_file

OPTIONS:
  -f, --file PATH      Force reading from specific file (skip git tags)
  -g, --git-only       Only use git tags, fail if not available
  -q, --quiet          Suppress warnings
  -h, --help           Show this help message

EXAMPLES:
  ${SCRIPT_NAME}                    # Try git tags, fallback to PROJECT.yaml
  ${SCRIPT_NAME} -g                 # Git tags only (recommended)
  ${SCRIPT_NAME} -f package.json    # Force read from file (legacy)

GIT TAGS (Recommended):
  - Derived from conventional commits (feat:, fix:, BREAKING CHANGE:)
  - Single source of truth
  - No merge conflicts
  - Automatic versioning

VERSION FILES (Legacy Fallback):
  - Plain text (VERSION file)
  - package.json (JSON)
  - pyproject.toml (TOML)
  - Cargo.toml (TOML)
  - pom.xml (XML)
  - build.gradle / build.gradle.kts (Gradle)

EXIT CODES:
  0 - Success
  1 - Version not found or invalid format
  2 - PROJECT.yaml not found (when needed)
  3 - Missing required tools

EOF
  exit 0
}

# Parse arguments
VERSION_FILE=""
QUIET=false
GIT_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -f|--file)
      VERSION_FILE="$2"
      shift 2
      ;;
    -g|--git-only)
      GIT_ONLY=true
      shift
      ;;
    -q|--quiet)
      QUIET=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# Error handling
error() {
  if [[ "$QUIET" == false ]]; then
    echo -e "${RED}Error: $1${NC}" >&2
  fi
  exit "${2:-1}"
}

warn() {
  if [[ "$QUIET" == false ]]; then
    echo -e "${YELLOW}Warning: $1${NC}" >&2
  fi
}

# STRATEGY 1: Try git tags first (RECOMMENDED)
if [[ -z "$VERSION_FILE" ]]; then
  # Check if we're in a git repo
  if git rev-parse --git-dir &>/dev/null; then
    # Get latest version tag repo-wide (not branch-specific)
    # Uses git tag -l instead of git describe because tags created on one branch
    # (e.g. prod) aren't ancestors of other branches using squash merges
    GIT_VERSION=$(git tag -l "v*" --sort=-v:refname | head -1)
    if [[ -n "$GIT_VERSION" ]]; then
      # Clean version (remove 'v' prefix if present)
      VERSION="${GIT_VERSION#v}"

      if [[ "$QUIET" == false ]]; then
        echo -e "${GREEN}Using git tag: $GIT_VERSION${NC}" >&2
      fi

      echo "$VERSION"
      exit 0
    else
      # No tags yet
      if [[ "$GIT_ONLY" == true ]]; then
        error "No git tags found. Create a tag with: git tag v0.1.0" 1
      fi

      warn "No git tags found, falling back to version file"
    fi
  else
    warn "Not a git repository, falling back to version file"
  fi
fi

# Git-only mode: fail if we got here
if [[ "$GIT_ONLY" == true ]]; then
  error "Git-only mode but no git tags available" 1
fi

# STRATEGY 2: Fall back to version files (LEGACY)
if [[ -z "$VERSION_FILE" ]]; then
  if [[ ! -f "PROJECT.yaml" ]]; then
    error "PROJECT.yaml not found and no git tags available" 2
  fi

  # Check if yq is available
  if ! command -v yq &> /dev/null; then
    error "yq is required but not installed" 3
  fi

  VERSION_FILE=$(yaml_get '.version_file' PROJECT.yaml)

  if [[ "$VERSION_FILE" == "null" ]] || [[ -z "$VERSION_FILE" ]]; then
    error "No git tags and version_file not set in PROJECT.yaml" 1
  fi

  warn "Using legacy version file: $VERSION_FILE (consider migrating to git tags)"
fi

# Check if version file exists
if [[ ! -f "$VERSION_FILE" ]]; then
  error "Version file not found: $VERSION_FILE" 1
fi

# Detect format and parse version
case "$VERSION_FILE" in
  # Plain text VERSION file
  VERSION|version|VERSION.txt)
    VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    ;;

  # package.json
  package.json|*/package.json)
    if ! command -v jq &> /dev/null; then
      error "jq is required to parse package.json" 3
    fi
    VERSION=$(jq -r '.version' "$VERSION_FILE" 2>/dev/null)
    if [[ "$VERSION" == "null" ]] || [[ -z "$VERSION" ]]; then
      error "No version field found in $VERSION_FILE" 1
    fi
    ;;

  # pyproject.toml
  pyproject.toml|*/pyproject.toml)
    # Try [project] section first (PEP 621)
    VERSION=$(grep -E -A 20 '^\[project\]' "$VERSION_FILE" | grep -E '^version[[:space:]]*=' | head -1 | sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/' || true)

    # Fallback to [tool.poetry] section
    if [[ -z "$VERSION" ]]; then
      VERSION=$(grep -E -A 20 '^\[tool\.poetry\]' "$VERSION_FILE" | grep -E '^version[[:space:]]*=' | head -1 | sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/' || true)
    fi

    if [[ -z "$VERSION" ]]; then
      error "No version found in $VERSION_FILE (checked [project] and [tool.poetry] sections)" 1
    fi
    ;;

  # Cargo.toml
  Cargo.toml|*/Cargo.toml)
    VERSION=$(grep -E -A 10 '^\[package\]' "$VERSION_FILE" | grep -E '^version[[:space:]]*=' | head -1 | sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')
    if [[ -z "$VERSION" ]]; then
      error "No version found in [package] section of $VERSION_FILE" 1
    fi
    ;;

  # pom.xml (Maven)
  pom.xml|*/pom.xml)
    if ! command -v xmllint &> /dev/null; then
      error "xmllint is required to parse pom.xml (install libxml2)" 3
    fi
    # Get version from project.version, excluding parent.version
    VERSION=$(xmllint --xpath "/*[local-name()='project']/*[local-name()='version']/text()" "$VERSION_FILE" 2>/dev/null)
    if [[ -z "$VERSION" ]]; then
      error "No version found in $VERSION_FILE" 1
    fi
    ;;

  # build.gradle or build.gradle.kts (Gradle)
  build.gradle|build.gradle.kts|*/build.gradle|*/build.gradle.kts)
    VERSION=$(grep -E "^[[:space:]]*version[[:space:]]*[=:]" "$VERSION_FILE" | sed -E "s/.*[=:][[:space:]]*['\"]([^'\"]+)['\"].*/\1/" | head -1)
    if [[ -z "$VERSION" ]]; then
      error "No version found in $VERSION_FILE" 1
    fi
    ;;

  # Unknown format - try as plain text
  *)
    if [[ "$QUIET" == false ]]; then
      echo -e "${YELLOW}Warning: Unknown version file format, trying as plain text${NC}" >&2
    fi
    VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    if [[ -z "$VERSION" ]]; then
      error "Could not parse version from $VERSION_FILE" 1
    fi
    ;;
esac

# Validate version format (basic semantic versioning check)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  if [[ "$QUIET" == false ]]; then
    echo -e "${YELLOW}Warning: Version doesn't follow semantic versioning (X.Y.Z): $VERSION${NC}" >&2
  fi
fi

# Output version
echo "$VERSION"
exit 0
