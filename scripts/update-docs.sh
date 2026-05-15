#!/usr/bin/env bash
set -euo pipefail

# Combined Documentation Generator
# Generates both SEQUENCE-TRACKER.md and DOCUMENT-INDEX.md from single filesystem scan
# Usage: update-docs.sh [--docs-dir <dir>]
# Compatible with: bash 3.2+ (macOS), bash 5+ (Linux/WSL), zsh

# Source utility functions
source "$HOME/.claude/scripts/doc-utils.sh" 2>/dev/null || true

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
SEQUENCE_TEMPLATE="$HOME/.claude/templates/SEQUENCE-TRACKER.template.md"
INDEX_TEMPLATE="$HOME/.claude/templates/DOCUMENT-INDEX.template.md"
SEQUENCE_OUTPUT="${DOCS_DIR}/SEQUENCE-TRACKER.md"
INDEX_OUTPUT="${DOCS_DIR}/DOCUMENT-INDEX.md"

echo "Regenerating documentation from filesystem scan..."

# Clean up any stale backup files left by previous failed runs
find "$DOCS_DIR" -maxdepth 1 -name '.*.backup.*' -type f -delete 2>/dev/null || true

# Create backups for fast revert/comparison during this run
SEQUENCE_BACKUP=""
INDEX_BACKUP=""
if [[ -f "$SEQUENCE_OUTPUT" ]]; then
  SEQUENCE_BACKUP="${DOCS_DIR}/.SEQUENCE-TRACKER.md.backup"
  cp "$SEQUENCE_OUTPUT" "$SEQUENCE_BACKUP"
fi
if [[ -f "$INDEX_OUTPUT" ]]; then
  INDEX_BACKUP="${DOCS_DIR}/.DOCUMENT-INDEX.md.backup"
  cp "$INDEX_OUTPUT" "$INDEX_BACKUP"
fi

# Cleanup function — removes backups when script exits successfully
cleanup_backups() {
  [[ -n "${SEQUENCE_BACKUP:-}" ]] && rm -f "$SEQUENCE_BACKUP"
  [[ -n "${INDEX_BACKUP:-}" ]] && rm -f "$INDEX_BACKUP"
}
# Only clean up on EXIT with success (trap checks exit code)
trap 'if [[ $? -eq 0 ]]; then cleanup_backups; fi' EXIT

# Declare associative arrays for sequence data
declare -A sequences
declare -A seq_types
declare -A seq_titles
declare -A seq_status
declare -A seq_dates

# Declare array for all documents (for index)
declare -a all_docs_data
# Track seen filenames to prevent duplicates across branches
declare -A seen_filenames

# Portable title case function
title_case() {
    echo "$1" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# Function to process a document
process_document() {
  local filepath="$1"
  local filename=$(basename "$filepath")

  # Skip if we've already processed this filename (same doc on multiple branches)
  [[ -n "${seen_filenames[$filename]:-}" ]] && return
  seen_filenames["$filename"]=1

  # Extract Task ID (first 6 uppercase hex chars)
  local seq=$(echo "$filename" | grep -oE '^[A-F0-9]{6}' || true)
  [[ -z "$seq" ]] && return

  # Extract document type (3-letter code after datetime)
  # Handle both 10-digit (YYMMDDHHMM) and 12-digit (YYMMDDHHMMSS) timestamps
  local doc_type=$(echo "$filename" | grep -oE '[0-9]{10,12}-([A-Z]{3})-' | grep -oE '[A-Z]{3}' || true)
  [[ -z "$doc_type" ]] && return

  # Extract date (10 or 12 digit timestamp, take first 10 digits for comparison)
  local date=$(echo "$filename" | grep -oE '[0-9]{10,12}' | head -1 | cut -c1-10 || true)

  # Extract title (everything after type, before .md)
  local title=$(echo "$filename" | sed -E 's/^[A-F0-9]{6}-[0-9]{10,12}-[A-Z]{3}-(.*)\.md$/\1/' | tr '-' ' ')
  title=$(title_case "$title")

  # Determine status based on location
  local status="completed"
  if [[ "$filepath" == *"/active/"* ]]; then
    status="active"
    # Check if task is on hold
    if grep -q "^## Task On Hold" "$filepath" 2>/dev/null; then
      status="on-hold"
    fi
  elif [[ "$filepath" == *"/on-hold/"* ]]; then
    status="on-hold"
  fi

  # Extract range folder
  local range=$(dirname "$filepath" | xargs basename)
  local location="$status/$range"

  # Format datetime for display
  local year month day hour min display_date
  if [[ ${#date} -ge 10 ]]; then
    year="20${date:0:2}"
    month="${date:2:2}"
    day="${date:4:2}"
    hour="${date:6:2}"
    min="${date:8:2}"
    display_date="$year-$month-$day $hour:$min"
  else
    display_date="[invalid date]"
  fi

  # Store data for SEQUENCE-TRACKER
  sequences["$seq"]=1

  # Append document type if not already present
  if [[ -z "${seq_types[$seq]:-}" ]]; then
    seq_types["$seq"]="$doc_type"
  elif [[ ! "${seq_types[$seq]}" =~ $doc_type ]]; then
    seq_types["$seq"]="${seq_types[$seq]}/$doc_type"
  fi

  # Use first title found (usually TSK or INC)
  if [[ -z "${seq_titles[$seq]:-}" ]]; then
    seq_titles["$seq"]="$title"
  fi

  # Use most recent status (completed overrides active)
  if [[ "$status" == "completed" ]] || [[ -z "${seq_status[$seq]:-}" ]]; then
    seq_status["$seq"]="$status"
  fi

  # Store earliest date
  if [[ -z "${seq_dates[$seq]:-}" ]] || [[ "$date" < "${seq_dates[$seq]}" ]]; then
    seq_dates["$seq"]="$date"
  fi

  # Store data for DOCUMENT-INDEX (pipe-delimited)
  all_docs_data+=("$seq|$doc_type|$display_date|$status|$location|$filename|$title")
}

# Scan local filesystem
echo "Scanning local filesystem..."
while IFS= read -r filepath; do
  process_document "$filepath"
done < <(find "$DOCS_DIR"/{active,completed,on-hold} -type f -name "[A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9]-*.md" 2>/dev/null | sort || true)

# Scan current branch only via git ls-tree to catch docs that exist in the index
# but not in the working tree (e.g., docs/active that were moved on a peer branch).
# Previous behavior scanned every local + remote branch, which is O(branches × docs)
# bash work — on large repos that runs for 15–20 minutes per commit. Restrict to
# the current branch only; cross-branch reconciliation is the job of `git merge`,
# not the doc indexer.
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Scanning current branch index..."

  while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    # Skip files already picked up by the working-tree scan above.
    [[ -f "$filepath" ]] && continue

    filename=$(basename "$filepath")

    if [[ "$filepath" == *"/completed/"* ]]; then
      status_dir="completed"
    elif [[ "$filepath" == *"/on-hold/"* ]]; then
      status_dir="on-hold"
    else
      status_dir="active"
    fi

    branch_folder=$(echo "$filepath" | grep -oE '[0-9]{4}-[0-9]{2}/' | head -1 | tr -d '/' || echo "2026-02")
    simulated_path="$DOCS_DIR/$status_dir/$branch_folder/$filename"
    process_document "$simulated_path"
  done < <(git ls-tree -r --name-only HEAD -- "$DOCS_DIR/" 2>/dev/null | grep -E '/[A-F0-9]{6}-[0-9]{10,12}-[A-Z]{3}-.+\.md$' || true)
fi

# Sort sequences by datetime (extracted from task IDs via their earliest doc date)
sorted_seqs=($(printf '%s\n' "${!sequences[@]}" | sort))

echo "  Found: ${#sequences[@]} work items"

# Statistics — no sequential counter; sort by creation date
first_seq="${sorted_seqs[0]:-000000}"
last_seq="${sorted_seqs[-1]:-000000}"

# Count documents by status
total_docs=${#all_docs_data[@]}
active_docs=0
on_hold_docs=0
completed_docs=0
for data in "${all_docs_data[@]}"; do
  status=$(echo "$data" | cut -d'|' -f4)
  case "$status" in
    active) ((active_docs+=1)) ;;
    on-hold) ((on_hold_docs+=1)) ;;
    completed) ((completed_docs+=1)) ;;
  esac
done

# Count work items by status
active_work_items=0
on_hold_work_items=0
completed_work_items=0
for seq in "${sorted_seqs[@]}"; do
  status="${seq_status[$seq]}"
  case "$status" in
    active) ((active_work_items+=1)) ;;
    on-hold) ((on_hold_work_items+=1)) ;;
    completed) ((completed_work_items+=1)) ;;
  esac
done
total_work_items=${#sequences[@]}

echo "  Active: $active_work_items work items ($active_docs docs)"
echo "  On Hold: $on_hold_work_items work items ($on_hold_docs docs)"
echo "  Completed: $completed_work_items work items ($completed_docs docs)"

# ============================================================
# GENERATE SEQUENCE-TRACKER.md
# ============================================================

# Build active and completed sequences tables
active_table=""
completed_table=""
for seq in "${sorted_seqs[@]}"; do
  types="${seq_types[$seq]}"
  title="${seq_titles[$seq]}"
  status="${seq_status[$seq]}"

  # Add to appropriate table based on status
  if [[ "$status" == "completed" ]]; then
    completed_table+="| $seq | $types | $title |\n"
  else
    # Active or on-hold
    active_table+="| $seq | $types | $title |\n"
  fi
done

# Handle empty tables
if [[ -z "$active_table" ]]; then
  active_table="| (none) | - | - |\n"
fi
if [[ -z "$completed_table" ]]; then
  completed_table="| (none) | - | - |\n"
fi

# Get current date
last_updated=$(date +%Y-%m-%d)

# Load template
if [[ ! -f "$SEQUENCE_TEMPLATE" ]]; then
  echo "Error: Template not found: $SEQUENCE_TEMPLATE"
  exit 1
fi

template=$(cat "$SEQUENCE_TEMPLATE")

# Replace placeholders
output="$template"
output="${output//\{\{ACTIVE_SEQUENCES\}\}/$active_table}"
output="${output//\{\{COMPLETED_SEQUENCES\}\}/$completed_table}"
output="${output//\{\{LAST_UPDATED\}\}/$last_updated}"

# Write output
echo -e "$output" > "$SEQUENCE_OUTPUT"

# ============================================================
# GENERATE DOCUMENT-INDEX.md
# ============================================================

# Build work items section for index
work_items_section=""

# Process each work item in descending order
for seq in $(printf '%s\n' "${sorted_seqs[@]}" | sort -rn); do
  # Get all docs for this work item
  work_item_docs=()
  for data in "${all_docs_data[@]}"; do
    doc_seq=$(echo "$data" | cut -d'|' -f1)
    if [[ "$doc_seq" == "$seq" ]]; then
      work_item_docs+=("$data")
    fi
  done
  
  doc_count=${#work_item_docs[@]}
  
  # Determine status
  status="${seq_status[$seq]}"
  status_icon="✅"
  status_word="Completed"
  if [[ "$status" == "on-hold" ]]; then
    status_icon="⏸️"
    status_word="On Hold"
  elif [[ "$status" == "active" ]]; then
    status_icon="🔄"
    status_word="Active"
  fi

  # Get types
  types="${seq_types[$seq]}"
  
  # Get title
  theme="${seq_titles[$seq]}"

  # Write work item section
  work_items_section+="\n### Work Item $seq: $theme ($doc_count documents) $status_icon\n\n"
  work_items_section+="| Type | Date | Status | Location | Filename |\n"
  work_items_section+="|------|------|--------|----------|----------|\n"

  # Write each document
  for data in "${work_item_docs[@]}"; do
    IFS='|' read -r s type display_date doc_status location filename title_unused <<< "$data"
    
    doc_status_display="✅ Completed"
    [[ "$doc_status" == "on-hold" ]] && doc_status_display="⏸️ On Hold"
    [[ "$doc_status" == "active" ]] && doc_status_display="🔄 Active"
    
    work_items_section+="| $type | $display_date | $doc_status_display | $location/ | $filename |\n"
  done

  work_items_section+="\n**Theme**: $theme\n"
  work_items_section+="**Types**: $types\n"
  work_items_section+="**Status**: $status_icon $status_word\n"
done

# Load template
if [[ ! -f "$INDEX_TEMPLATE" ]]; then
  echo "Error: Template not found: $INDEX_TEMPLATE"
  exit 1
fi

index_template=$(cat "$INDEX_TEMPLATE")

# Replace placeholders
index_output="$index_template"
index_output="${index_output//\{\{LAST_UPDATED\}\}/$last_updated}"
index_output="${index_output//\{\{TOTAL_DOCS\}\}/$total_docs}"
index_output="${index_output//\{\{TOTAL_WORK_ITEMS\}\}/$total_work_items}"
index_output="${index_output//\{\{FIRST_SEQ\}\}/$first_seq}"
index_output="${index_output//\{\{LAST_SEQ\}\}/$last_seq}"
index_output="${index_output//\{\{ACTIVE_DOCS\}\}/$active_docs}"
index_output="${index_output//\{\{ACTIVE_WORK_ITEMS\}\}/$active_work_items}"
index_output="${index_output//\{\{ON_HOLD_DOCS\}\}/$on_hold_docs}"
index_output="${index_output//\{\{ON_HOLD_WORK_ITEMS\}\}/$on_hold_work_items}"
index_output="${index_output//\{\{COMPLETED_DOCS\}\}/$completed_docs}"
index_output="${index_output//\{\{COMPLETED_WORK_ITEMS\}\}/$completed_work_items}"
index_output="${index_output//\{\{WORK_ITEMS\}\}/$work_items_section}"
index_output="${index_output//\{\{TIMESTAMP\}\}/$(date -Iseconds)}"

# Write output
echo -e "$index_output" > "$INDEX_OUTPUT"

# ============================================================
# VERIFICATION
# ============================================================

echo "Verifying all work items are tracked..."
missing=0
for seq in "${sorted_seqs[@]}"; do
  if ! grep -q "^| $seq |" "$SEQUENCE_OUTPUT"; then
    echo "  ⚠️  Missing from SEQUENCE-TRACKER: $seq"
    ((missing+=1))
  fi
done

for data in "${all_docs_data[@]}"; do
  filename=$(echo "$data" | cut -d'|' -f6)
  if ! grep -q "$filename" "$INDEX_OUTPUT"; then
    echo "  ⚠️  Missing from DOCUMENT-INDEX: $filename"
    ((missing+=1))
  fi
done

if [[ $missing -eq 0 ]]; then
  echo "✓ All documents verified"
else
  echo "⚠️  $missing items could not be verified — restoring from backup"
  [[ -n "$SEQUENCE_BACKUP" && -f "$SEQUENCE_BACKUP" ]] && cp "$SEQUENCE_BACKUP" "$SEQUENCE_OUTPUT"
  [[ -n "$INDEX_BACKUP" && -f "$INDEX_BACKUP" ]] && cp "$INDEX_BACKUP" "$INDEX_OUTPUT"
fi

echo "✓ SEQUENCE-TRACKER.md regenerated"
echo "✓ DOCUMENT-INDEX.md regenerated"
