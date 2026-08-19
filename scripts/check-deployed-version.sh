#!/usr/bin/env bash
# check-deployed-version.sh - Verify deployed version matches expected
# Usage: ./scripts/check-deployed-version.sh --url <url> --expected-version <ver> [--version-path <path>]
# Returns: JSON status to stdout
# Exit codes: 0=verified, 1=mismatch, 2=error

set -euo pipefail

BASE_URL=""
VERSION_PATH="/api/version"
EXPECTED_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)              BASE_URL="$2";          shift 2 ;;
    --version-path)     VERSION_PATH="$2";      shift 2 ;;
    --expected-version) EXPECTED_VERSION="$2";  shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--url <url>] [--version-path <path>] [--expected-version <ver>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "⚠️  No URL provided - skipping version verification" >&2
  cat <<EOF
{
  "verified": false,
  "expected": "$EXPECTED_VERSION",
  "deployed": "unknown",
  "matches": false,
  "status": "skipped"
}
EOF
  exit 0
fi

if [[ -z "$EXPECTED_VERSION" ]]; then
  echo "❌ Usage: $0 --url <url> --expected-version <ver> [--version-path <path>]" >&2
  exit 2
fi

VERSION_ENDPOINT="${BASE_URL}${VERSION_PATH}"
DEPLOYED_VERSION=""
VERIFIED=false

echo "Checking deployed version..." >&2
echo "  Endpoint: $VERSION_ENDPOINT" >&2
echo "  Expected: $EXPECTED_VERSION" >&2

# Try to get version from endpoint
RESPONSE=$(curl -s --connect-timeout 5 --max-time 15 "$VERSION_ENDPOINT" 2>/dev/null || echo "")
if [[ -n "$RESPONSE" ]]; then
  DEPLOYED_VERSION=$(echo "$RESPONSE" | jq -r '.version // .tag // empty' 2>/dev/null || echo "")
fi

if [[ -z "$DEPLOYED_VERSION" ]]; then
  echo "⚠️  Could not query deployed version" >&2
  cat <<EOF
{
  "verified": false,
  "expected": "$EXPECTED_VERSION",
  "deployed": "unknown",
  "error": "Could not query version endpoint"
}
EOF
  exit 1
fi

echo "  Deployed: $DEPLOYED_VERSION" >&2

# Extract base semver (handle staging metadata like 1.2.3-staging.1234)
BASE_VERSION=$(echo "$EXPECTED_VERSION" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "$EXPECTED_VERSION")

# Check if deployed version contains expected base version.
# Guard against an empty BASE_VERSION (extraction failed) — an empty pattern
# matches everything and would falsely report the version as verified.
if [[ -n "$BASE_VERSION" ]] && echo "$DEPLOYED_VERSION" | grep -qF "$BASE_VERSION"; then
  echo "✓ Version verified (contains $BASE_VERSION)" >&2
  VERIFIED=true
  EXIT_CODE=0
else
  echo "⚠️  Version mismatch" >&2
  EXIT_CODE=1
fi

# Output JSON result
cat <<EOF
{
  "verified": $([[ "$VERIFIED" == true ]] && echo "true" || echo "false"),
  "expected": "$EXPECTED_VERSION",
  "expected_base": "$BASE_VERSION",
  "deployed": "$DEPLOYED_VERSION",
  "matches": $([[ "$VERIFIED" == true ]] && echo "true" || echo "false")
}
EOF

exit "$EXIT_CODE"
