#!/bin/bash
# =============================================================================
# Version Helper Library
# =============================================================================
# Version management using git tags as the source of truth.
# No VERSION file needed - version comes from git tags.
#
# Tag format: v1.2.3 (semantic versioning)
# Version string: 1.2.3 (without 'v' prefix)
#
# Usage:
#   source lib/version.sh
#   version_get_current          # Get current version from latest tag
#   version_bump "patch"         # Bump and create new tag
#   version_get_next "minor"     # Preview next version without tagging
# =============================================================================

# =============================================================================
# version_get_current - Get current version from latest git tag
# =============================================================================
# Returns version string (e.g., "1.4.1") from the latest v* tag.
# Falls back to 0.0.0 if no tags exist.
# =============================================================================
version_get_current() {
  local tag
  tag=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "")

  if [[ -z "$tag" ]]; then
    echo "0.0.0"
    return
  fi

  # Remove 'v' prefix
  echo "${tag#v}"
}

# =============================================================================
# version_get_next - Calculate next version without creating tag
# =============================================================================
# Arguments:
#   $1 - Bump type: major, minor, patch (default: patch)
#
# Returns:
#   Next version string (e.g., "1.4.2" if current is "1.4.1" and bump is patch)
# =============================================================================
version_get_next() {
  local bump_type="${1:-patch}"
  local current
  current=$(version_get_current)

  local major minor patch
  IFS='.' read -r major minor patch <<< "$current"

  # Default to 0 if empty
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  case "$bump_type" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
    *)
      echo "Error: Invalid bump type: $bump_type (use major, minor, or patch)" >&2
      return 1
      ;;
  esac

  echo "${major}.${minor}.${patch}"
}

# =============================================================================
# version_bump - Bump version and create git tag
# =============================================================================
# Arguments:
#   $1 - Bump type: major, minor, patch (default: patch)
#   $2 - (optional) Message for the tag
#
# Returns:
#   The new version string
#
# Side effects:
#   Creates a new git tag (v1.2.3 format)
# =============================================================================
version_bump() {
  local bump_type="${1:-patch}"
  local message="${2:-Release}"

  local next_version
  next_version=$(version_get_next "$bump_type")

  if [[ $? -ne 0 ]]; then
    return 1
  fi

  local tag="v${next_version}"

  echo "Creating tag: $tag" >&2
  git tag -a "$tag" -m "${message} ${next_version}"

  echo "$next_version"
}

# =============================================================================
# version_tag_exists - Check if a version tag exists
# =============================================================================
# Arguments:
#   $1 - Version string (e.g., "1.4.1") or tag (e.g., "v1.4.1")
#
# Returns:
#   0 if tag exists, 1 if not
# =============================================================================
version_tag_exists() {
  local version="$1"

  # Ensure v prefix
  if [[ ! "$version" =~ ^v ]]; then
    version="v$version"
  fi

  git rev-parse "$version" &>/dev/null
}

# =============================================================================
# version_get_build_string - Get full version string for builds
# =============================================================================
# For main/master: 1.4.1
# For staging: 1.4.1-staging.YYYYMMDD.HHMMSS
# For feature branches: 1.4.1-feature-name.YYYYMMDD.HHMMSS
# =============================================================================
version_get_build_string() {
  local base_version
  base_version=$(version_get_current)

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  local timestamp
  timestamp=$(date +%Y%m%d.%H%M%S)

  case "$branch" in
    main|master)
      echo "$base_version"
      ;;
    staging)
      echo "${base_version}-staging.${timestamp}"
      ;;
    *)
      # Sanitize branch name
      local branch_safe
      branch_safe=$(echo "$branch" | sed 's/\//-/g' | sed 's/[^a-zA-Z0-9-]//g')
      echo "${base_version}-${branch_safe}.${timestamp}"
      ;;
  esac
}

# =============================================================================
# version_auto_bump - Determine bump type from commit messages
# =============================================================================
# Analyzes commits since last tag:
#   - feat!: or BREAKING CHANGE → major
#   - feat: → minor
#   - fix:, perf:, refactor:, etc. → patch
#
# Returns:
#   Bump type (major, minor, or patch)
# =============================================================================
version_auto_bump_type() {
  local last_tag
  last_tag=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "")

  local range
  if [[ -n "$last_tag" ]]; then
    range="${last_tag}..HEAD"
  else
    range="HEAD"
  fi

  local commits
  commits=$(git log "$range" --oneline 2>/dev/null || echo "")

  # Check for breaking changes
  if echo "$commits" | grep -qiE '(BREAKING CHANGE|feat!:|fix!:)'; then
    echo "major"
    return
  fi

  # Check for features
  if echo "$commits" | grep -qE '^[a-f0-9]+ feat(\(|:)'; then
    echo "minor"
    return
  fi

  # Default to patch
  echo "patch"
}

# =============================================================================
# version_list_tags - List recent version tags
# =============================================================================
# Arguments:
#   $1 - (optional) Number of tags to show (default: 10)
# =============================================================================
version_list_tags() {
  local count="${1:-10}"

  git tag -l "v*" --sort=-version:refname | head -n "$count"
}
