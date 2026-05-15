#!/usr/bin/env bash
# validate-pr-title.sh - Validate PR/MR title follows conventional commits format
# Usage: ./validate-pr-title.sh --title "<pr-title>"
# Exit codes: 0=valid, 1=invalid

set -euo pipefail

TITLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --title <title>" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TITLE" ]]; then
  echo "❌ Error: No title provided"
  echo "Usage: $0 --title \"<pr-title>\""
  exit 1
fi

# Conventional commits regex pattern
# Format: type(scope): description
# or: type: description
# or: type(scope)!: description (breaking)
# or: type!: description (breaking)
PATTERN='^(feat|fix|docs|chore|refactor|perf|test|ci|build|revert)(\([a-z0-9\-]+\))?(!)?: .+$'

if [[ "$TITLE" =~ $PATTERN ]]; then
  TYPE="${BASH_REMATCH[1]}"
  SCOPE="${BASH_REMATCH[2]}"
  BREAKING="${BASH_REMATCH[3]}"

  echo "✅ PR title is valid"
  echo "   Type: $TYPE"
  [[ -n "$SCOPE" ]] && echo "   Scope: ${SCOPE//[()]/}"
  [[ -n "$BREAKING" ]] && echo "   Breaking: Yes"
  exit 0
else
  echo "❌ PR title does not follow conventional commits format"
  echo ""
  echo "Title: $TITLE"
  echo ""
  echo "Expected format:"
  echo "  type(scope): description"
  echo "  type: description"
  echo "  type!: description (breaking change)"
  echo ""
  echo "Valid types:"
  echo "  feat, fix, docs, chore, refactor, perf, test, ci, build, revert"
  echo ""
  echo "Examples:"
  echo "  feat(auth): add OAuth2 authentication"
  echo "  fix(api): resolve race condition"
  echo "  feat!: migrate to new API (breaking)"
  echo ""
  exit 1
fi
