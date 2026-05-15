#!/usr/bin/env bash
set -euo pipefail

# update-index.sh - Regenerate DOCUMENT-INDEX.md in descending order
# Usage: update-index.sh [--docs-dir <dir>]

DOCS_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docs-dir) DOCS_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--docs-dir <dir>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
cd "$DOCS_DIR"

[[ ! -d "docs" ]] && { echo "Error: docs/ directory not found"; exit 1; }

# macOS/BSD compatibility
if [[ "$(uname -s)" == "Darwin" ]]; then
    sedi() { sed -i '' "$@"; }
else
    sedi() { sed -i "$@"; }
fi

# Portable title case: capitalize first letter of each word
title_case() {
    echo "$1" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

echo "Regenerating DOCUMENT-INDEX.md..."

# Backup (only if file exists)
BACKUP_FILE=""
if [[ -f "docs/DOCUMENT-INDEX.md" ]]; then
  BACKUP_FILE="docs/.DOCUMENT-INDEX.md.backup.$(date +%Y%m%d-%H%M%S)"
  cp docs/DOCUMENT-INDEX.md "$BACKUP_FILE"
  echo "Created backup: $(basename "$BACKUP_FILE")"
fi

# Get next sequence
NEXT_SEQ=$(grep "^\*\*Next Available\*\*:" docs/SEQUENCE-TRACKER.md 2>/dev/null | grep -oE '[0-9]{4}' || echo "0013")

# Create temp file for collecting data
TEMP_DATA=$(mktemp)
trap "rm -f $TEMP_DATA" EXIT

# Scan all docs and write to temp file (using process substitution to avoid subshell)
while read -r filepath; do
  filename=$(basename "$filepath")
  seq=$(echo "$filename" | grep -oE '^[0-9]{4}' || true)
  [[ -z "$seq" ]] && continue

  # Extract parts - handle both V3 (12-digit YYYYMMDDHHMM) and V4 (10-digit YYMMDDHHMM) datetime
  datetime=$(echo "$filename" | sed -E 's/^[0-9]{4}-([0-9]{10,12})-.*/\1/')
  type=$(echo "$filename" | sed -E 's/^[0-9]{4}-[0-9]{10,12}-([A-Z]{3,}).*/\1/')
  desc=$(echo "$filename" | sed -E 's/^[0-9]{4}-[0-9]{10,12}-[A-Z]{3,}-(.*)\.md$/\1/')

  status="completed"
  [[ "$filepath" =~ /active/ ]] && status="active"

  # Check if task is on hold
  if [[ "$status" == "active" ]] && grep -q "^## Task On Hold" "$filepath" 2>/dev/null; then
    status="on-hold"
  fi

  range=$(dirname "$filepath" | xargs basename)
  location="$status/$range"

  # Format datetime (V3: 12-digit YYYYMMDDHHMM, V4: 10-digit YYMMDDHHMM)
  if [[ ${#datetime} -eq 12 ]]; then
    year="${datetime:0:4}"
    month="${datetime:4:2}"
    day="${datetime:6:2}"
    hour="${datetime:8:2}"
    min="${datetime:10:2}"
  else
    year="20${datetime:0:2}"
    month="${datetime:2:2}"
    day="${datetime:4:2}"
    hour="${datetime:6:2}"
    min="${datetime:8:2}"
  fi
  display_date="$year-$month-$day $hour:$min"

  echo "$seq|$type|$display_date|$status|$location|$filename|$desc" >> $TEMP_DATA
done < <(find docs/active docs/completed -name "*.md" -type f 2>/dev/null)

# Get statistics (xargs trims whitespace from macOS wc -l)
total_docs=$(wc -l < $TEMP_DATA | xargs)
active_docs=$( (grep '|active|' $TEMP_DATA || true) | wc -l | xargs)
on_hold_docs=$( (grep '|on-hold|' $TEMP_DATA || true) | wc -l | xargs)
completed_docs=$( (grep '|completed|' $TEMP_DATA || true) | wc -l | xargs)
total_work_items=$(cut -d'|' -f1 $TEMP_DATA | sort -u | wc -l | xargs)
active_work_items=$( (grep '|active|' $TEMP_DATA || true) | cut -d'|' -f1 | sort -u | wc -l | xargs)
on_hold_work_items=$( (grep '|on-hold|' $TEMP_DATA || true) | cut -d'|' -f1 | sort -u | wc -l | xargs)
completed_work_items=$( (grep '|completed|' $TEMP_DATA || true) | cut -d'|' -f1 | sort -u | wc -l | xargs)
last_seq=$(cut -d'|' -f1 $TEMP_DATA | sort -rn | head -1)

echo "  Found: $total_work_items work items ($total_docs documents)"
echo "  Active: $active_work_items work items ($active_docs docs)"
echo "  On Hold: $on_hold_work_items work items ($on_hold_docs docs)"
echo "  Completed: $completed_work_items work items ($completed_docs docs)"

# Generate index
cat > docs/DOCUMENT-INDEX.md << HEADER
# Document Index - Master Reference

**Last Updated**: $(date +%Y-%m-%d)
**Total Documents**: $total_docs files
**Total Work Items**: $total_work_items (sequences 0001-$last_seq)
**Next Available Sequence**: $NEXT_SEQ

---

## Key Concept

**One task ID = one work item** (can have multiple document types)

---

## Quick Stats

| Status | Documents | Work Items |
|--------|-----------|------------|
| Active | $active_docs docs | $active_work_items work items |
| On Hold | $on_hold_docs docs | $on_hold_work_items work items |
| Completed | $completed_docs docs | $completed_work_items work items |
| **Total** | **$total_docs docs** | **$total_work_items work items** |

---

## Work Items (Most Recent First)

HEADER

# Process each work item in descending order
for seq in $(cut -d'|' -f1 $TEMP_DATA | sort -rn | uniq); do
  # Get all docs for this work item
  work_item_data=$(grep "^$seq|" $TEMP_DATA)
  doc_count=$(echo "$work_item_data" | wc -l | xargs)

  # Determine status
  status_icon="✅"
  status_word="Completed"
  if echo "$work_item_data" | grep -q '|on-hold|'; then
    status_icon="⏸️"
    status_word="On Hold"
  elif echo "$work_item_data" | grep -q '|active|'; then
    status_icon="🔄"
    status_word="Active"
  fi

  # Get types
  types=$(echo "$work_item_data" | cut -d'|' -f2 | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

  # Get primary description (prefer TSK or INC)
  primary_desc=$(echo "$work_item_data" | grep -E '\|TSK\||\|INC\|' | head -1 | cut -d'|' -f7 || true)
  [[ -z "$primary_desc" ]] && primary_desc=$(echo "$work_item_data" | head -1 | cut -d'|' -f7)

  # Format theme (title case, portable)
  theme=$(title_case "$(echo "$primary_desc" | sed 's/-/ /g')")

  # Write work item section
  cat >> docs/DOCUMENT-INDEX.md << ITEM_HEADER

### Work Item $seq: $theme ($doc_count documents) $status_icon

| Type | Date | Status | Location | Filename |
|------|------|--------|----------|----------|
ITEM_HEADER

  # Write each document
  echo "$work_item_data" | while IFS='|' read -r s type display_date status location filename desc; do
    doc_status="✅ Completed"
    [[ "$status" == "on-hold" ]] && doc_status="⏸️ On Hold"
    [[ "$status" == "active" ]] && doc_status="🔄 Active"
    echo "| $type | $display_date | $doc_status | $location/ | $filename |" >> docs/DOCUMENT-INDEX.md
  done

  cat >> docs/DOCUMENT-INDEX.md << ITEM_FOOTER

**Theme**: $theme
**Types**: $types
**Status**: $status_icon $status_word
ITEM_FOOTER
done

# Add footer
cat >> docs/DOCUMENT-INDEX.md << 'FOOTER'

---

## Maintenance

**Last Generated**: TIMESTAMP
**Generator**: ~/.claude/scripts/update-docs.sh
**Method**: Automated scan of docs/ structure

To regenerate: `~/.claude/scripts/update-docs.sh`
FOOTER

sedi "s/TIMESTAMP/$(date -Iseconds)/" docs/DOCUMENT-INDEX.md

# Verify all documents are in the new index
if [[ -n "$BACKUP_FILE" ]]; then
  echo "Verifying all documents are indexed..."

  # Get all document files
  ALL_DOCS=$(find docs/active docs/completed -name "*.md" -type f 2>/dev/null | sort)
  MISSING_DOCS=""

  # Check each document is mentioned in the new index
  while IFS= read -r doc_path; do
    doc_filename=$(basename "$doc_path")
    if ! grep -q "$doc_filename" docs/DOCUMENT-INDEX.md; then
      MISSING_DOCS="${MISSING_DOCS}${doc_filename}\n"
    fi
  done <<< "$ALL_DOCS"

  if [[ -z "$MISSING_DOCS" ]]; then
    # All documents accounted for - safe to delete backup
    rm "$BACKUP_FILE"
    echo "✓ Backup removed (all documents verified in index)"

    # Clean up old backups (keep none since we verified)
    OLD_BACKUPS=$(find docs -name ".DOCUMENT-INDEX.md.backup.*" -type f 2>/dev/null)
    if [[ -n "$OLD_BACKUPS" ]]; then
      echo "$OLD_BACKUPS" | while IFS= read -r old_backup; do
        rm "$old_backup"
        echo "Removed old backup: $(basename "$old_backup")"
      done
    fi
  else
    echo "⚠️  Warning: Some documents not found in new index:"
    echo -e "$MISSING_DOCS" | sed 's/^/  - /'
    echo "Backup kept: $BACKUP_FILE"
  fi
fi

echo "✓ DOCUMENT-INDEX.md regenerated (most recent first)"
