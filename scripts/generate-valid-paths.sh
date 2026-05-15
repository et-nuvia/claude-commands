#!/usr/bin/env bash
set -euo pipefail

# generate-valid-paths.sh - Extract all valid paths from PROJECT.yaml schema
# Usage:
#   generate-valid-paths.sh [schema_file]
#
# Output: One path per line, sorted
#   .name
#   .version_file
#   .testing.command
#   .testing.coverage_command
#   .secrets.backend
#   .secrets.infisical.project_id
#   etc.

SCHEMA_FILE="${1:-${HOME}/.claude/schemas/project.schema.json}"

# Fail early - require jq
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq required for JSON processing" >&2
    exit 1
fi

if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "ERROR: Schema file not found: $SCHEMA_FILE" >&2
    exit 1
fi

# Extract all paths in a single jq call (recursive, no subshell explosion)
jq -r '
  # Resolve a $ref like "#/$defs/foo" to the actual definition
  def resolve_ref:
    if has("$ref") then
      .["$ref"] | ltrimstr("#/") | split("/") | reduce .[] as $seg (
        $ENV_SCHEMA; .[$seg]
      )
    else .
    end;

  # Recursively extract dotted paths from a schema node
  def extract(prefix):
    (if has("$ref") then resolve_ref else . end) as $node |
    ($node.properties // {}) | to_entries[] |
    .key as $key | .value as $prop |
    "\(prefix).\($key)",
    # Inline properties
    (if $prop | has("properties") then
      $prop | extract("\(prefix).\($key)")
    else empty end),
    # $ref on property
    (if $prop | has("$ref") then
      $prop | resolve_ref | extract("\(prefix).\($key)")
    else empty end),
    # Array items with properties
    (if ($prop.items // null) | type == "object" and has("properties") then
      $prop.items | extract("\(prefix).\($key)")
    else empty end),
    # Array items with $ref
    (if ($prop.items // null) | type == "object" and has("$ref") then
      $prop.items | resolve_ref | extract("\(prefix).\($key)")
    else empty end);

  # Store full schema for $ref resolution via $ENV trick — not possible,
  # so we pass the schema as input and use . as root
  . as $root |
  def resolve_ref_root:
    if has("$ref") then
      .["$ref"] | ltrimstr("#/") | split("/") | reduce .[] as $seg (
        $root; .[$seg]
      )
    else .
    end;

  def extract_root(prefix):
    (if has("$ref") then resolve_ref_root else . end) as $node |
    ($node.properties // {}) | to_entries[] |
    .key as $key | .value as $prop |
    "\(prefix).\($key)",
    (if $prop | has("properties") then
      $prop | extract_root("\(prefix).\($key)")
    else empty end),
    (if $prop | has("$ref") then
      $prop | resolve_ref_root | extract_root("\(prefix).\($key)")
    else empty end),
    (if ($prop.items // null) | type == "object" and has("properties") then
      $prop.items | extract_root("\(prefix).\($key)")
    else empty end),
    (if ($prop.items // null) | type == "object" and has("$ref") then
      $prop.items | resolve_ref_root | extract_root("\(prefix).\($key)")
    else empty end);

  extract_root("")
' "$SCHEMA_FILE" | sort -u
