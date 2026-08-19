#!/usr/bin/env bash
set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: requires bash >= 4 (on macOS: brew install bash)" >&2
  exit 1
fi

# Update Sequence Tracker
# Auto-generates SEQUENCE-TRACKER.md from filesystem scan
# Usage: update-sequence-tracker.sh [--docs-dir <dir>]

# Source utility functions
source "$HOME/.claude/scripts/doc-utils.sh"

DOCS_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docs-dir) DOCS_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--docs-dir <dir>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DOCS_DIR" ]]; then
  DOCS_DIR="$(find_docs_dir 2>/dev/null || echo "docs")"
fi
TEMPLATE_FILE="$HOME/.claude/templates/SEQUENCE-TRACKER.template.md"
OUTPUT_FILE="${DOCS_DIR}/SEQUENCE-TRACKER.md"
BACKUP_FILE="${DOCS_DIR}/.SEQUENCE-TRACKER.md.backup.$(date +%Y%m%d-%H%M%S)"

echo "Regenerating SEQUENCE-TRACKER.md..."

# Create backup if file exists
if [[ -f "$OUTPUT_FILE" ]]; then
  cp "$OUTPUT_FILE" "$BACKUP_FILE"
  echo "Created backup: $(basename "$BACKUP_FILE")"
fi

# Scan all documents and build work item data
declare -A sequences
declare -A seq_types
declare -A seq_titles
declare -A seq_status
declare -A seq_dates

# Function to process a document
process_document() {
  local filepath="$1"
  local filename=$(basename "$filepath")

  # Extract Task ID (first 6 uppercase hex chars)
  local seq
  seq=$(echo "$filename" | grep -oE '^[A-F0-9]{6}') || true
  [[ -z "$seq" ]] && return

  # Extract document type (3-letter code after datetime)
  local doc_type
  doc_type=$(echo "$filename" | grep -oE '[0-9]{10,12}-([A-Z]{3})-' | grep -oE '[A-Z]{3}') || true
  [[ -z "$doc_type" ]] && return

  # Extract date (10 or 12 digit timestamp, take first 10 digits for comparison)
  local date
  date=$(echo "$filename" | grep -oE '[0-9]{10,12}' | head -1 | cut -c1-10) || true

  # Extract title (everything after type, before .md)
  local title
  title=$(echo "$filename" | sed -E 's/^[A-F0-9]{6}-[0-9]{10,12}-[A-Z]{3}-(.*)\.md$/\1/')

  # Replace hyphens with spaces and capitalize words
  title=$(echo "$title" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')

  # Determine status based on location
  local status
  if [[ "$filepath" == *"/completed/"* ]]; then
    status="Completed"
  elif [[ "$filepath" == *"/on-hold/"* ]]; then
    status="On Hold"
  else
    status="Active"
  fi

  # Store data
  sequences["$seq"]=1

  # Append document type if not already present
  if [[ -z "${seq_types[$seq]:-}" ]]; then
    seq_types["$seq"]="$doc_type"
  elif [[ ! "${seq_types[$seq]}" =~ $doc_type ]]; then
    seq_types["$seq"]="${seq_types[$seq]}/$doc_type"
  fi

  # Use first title found (usually TSK)
  if [[ -z "${seq_titles[$seq]:-}" ]]; then
    seq_titles["$seq"]="$title"
  fi

  # Use most recent status (completed overrides active)
  if [[ "$status" == "Completed" ]] || [[ -z "${seq_status[$seq]:-}" ]]; then
    seq_status["$seq"]="$status"
  fi

  # Store earliest date
  if [[ -z "${seq_dates[$seq]:-}" ]] || [[ "$date" < "${seq_dates[$seq]}" ]]; then
    seq_dates["$seq"]="$date"
  fi
}

# Scan local filesystem (date-based subfolders: YYYY-MM/)
echo "Scanning local filesystem..."
while IFS= read -r filepath; do
  process_document "$filepath"
done < <(find "$DOCS_DIR"/{active,completed,on-hold} -type f -name "[A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9]-*.md" 2>/dev/null | sort)

# Scan all git branches if in a git repo
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Scanning git branches..."

  # Get all remote and local branches
  all_branches=$(git for-each-ref --format='%(refname:short)' refs/heads/ refs/remotes/ | sort -u)

  for branch in $all_branches; do
    # List all V4 documents in this branch
    while IFS= read -r filepath; do
      # Skip if empty
      [[ -z "$filepath" ]] && continue

      # Extract just the filename
      filename=$(basename "$filepath")

      # Simulate the file being in the appropriate status directory
      if [[ "$filepath" == *"/completed/"* ]]; then
        status_dir="completed"
      elif [[ "$filepath" == *"/on-hold/"* ]]; then
        status_dir="on-hold"
      else
        status_dir="active"
      fi

      # Extract date-based folder from path (YYYY-MM format)
      local branch_folder
      branch_folder=$(echo "$filepath" | grep -oE '[0-9]{4}-[0-9]{2}/' | head -1 | tr -d '/' || echo "2026-02")

      # Create a simulated path for processing
      simulated_path="$DOCS_DIR/$status_dir/$branch_folder/$filename"

      # Process using our function
      process_document "$simulated_path"

    done < <(git ls-tree -r --name-only "$branch" -- "$DOCS_DIR/" 2>/dev/null | grep -E '/[A-F0-9]{6}-[0-9]{10,12}-[A-Z]{3}-.+\.md$' || true)
  done
fi

# Sort sequences (hex sort by creation date stored in seq_dates)
sorted_seqs=($(
  for seq in "${!sequences[@]}"; do
    echo "${seq_dates[$seq]:-0000000000} $seq"
  done | sort | awk '{print $2}'
))

# Build active sequences table
active_table=""
for seq in "${sorted_seqs[@]}"; do
  types="${seq_types[$seq]}"
  title="${seq_titles[$seq]}"
  status="${seq_status[$seq]}"

  active_table+="| $seq | $types | $title | $status |\n"
done

# Build history section
history=""
for seq in "${sorted_seqs[@]}"; do
  title="${seq_titles[$seq]}"
  date="${seq_dates[$seq]}"

  # Convert timestamp to readable date (YYMMDDHHMMSS -> YYYY-MM-DD)
  year="20${date:0:2}"
  month="${date:2:2}"
  day="${date:4:2}"
  readable_date="$year-$month-$day"

  history+="- $seq: $title (created $readable_date)\n"
done

# Get current date
last_updated=$(date +%Y-%m-%d)

# Load template
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Error: Template not found: $TEMPLATE_FILE"
  exit 1
fi

template=$(cat "$TEMPLATE_FILE")

# Replace placeholders
output="$template"
output="${output//\{\{ACTIVE_SEQUENCES\}\}/$active_table}"
output="${output//\{\{SEQUENCE_HISTORY\}\}/$history}"
output="${output//\{\{LAST_UPDATED\}\}/$last_updated}"

# Write output
echo -e "$output" > "$OUTPUT_FILE"

echo "  Found: ${#sequences[@]} work items"

# Verify all Task IDs are in tracker
echo "Verifying all work items are tracked..."
missing=0
for seq in "${sorted_seqs[@]}"; do
  if ! grep -q "^| $seq |" "$OUTPUT_FILE"; then
    echo "  ⚠️  Missing: $seq"
    missing=$((missing + 1))
  fi
done

if [[ $missing -eq 0 ]]; then
  # Remove backup if everything is good
  rm -f "$BACKUP_FILE"
  echo "✓ Backup removed (all work items verified)"
else
  echo "⚠️  $missing work items missing, keeping backup"
fi

echo "✓ SEQUENCE-TRACKER.md regenerated"
