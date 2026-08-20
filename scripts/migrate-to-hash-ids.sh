#!/usr/bin/env bash
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$_SD}"
# migrate-to-hash-ids.sh
# One-time migration: converts 4-digit seqnum documents to 6-char hash-based Task IDs
# with date-based YYYY-MM subfolders.
#
# Usage:
#   migrate-to-hash-ids.sh [--dry-run] [docs_dir]
#
# Algorithm:
#   Pass 1: Build mapping (old_basename → new_hash + new_path)
#   Pass 2: git mv files to new locations
#   Pass 3: Update internal content (Work Item, Related To, Folder fields)
#   Pass 4: Remove empty old folders, regenerate indexes

set -euo pipefail

# Source shared utilities
source "${SCRIPT_DIR}/common.sh"

# Parse args
DRY_RUN=false
DOCS_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) DOCS_DIR="$1"; shift ;;
  esac
done

DOCS_DIR="${DOCS_DIR:-docs}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN MODE — no files will be modified ==="
  echo ""
fi

echo "Migration: 4-digit seqnums → 6-char hash Task IDs"
echo "Docs directory: $DOCS_DIR"

# Detect git repo root (docs may be inside a repo)
REPO_ROOT=$(git -C "$DOCS_DIR" rev-parse --show-toplevel 2>/dev/null || \
            git -C "$(dirname "$(realpath "$DOCS_DIR")")" rev-parse --show-toplevel 2>/dev/null || \
            dirname "$(realpath "$DOCS_DIR")")
echo "Git repo root: $REPO_ROOT"
echo ""

# macOS/BSD sed compatibility (PLATFORM axis — see lib/platform.sh)
source "${SCRIPT_DIR}/lib/platform.sh"
if env_is_darwin; then
  sedi() { sed -i '' "$@"; }
else
  sedi() { sed -i "$@"; }
fi

# ============================================================
# Pass 1: Build complete mapping (no file changes)
# ============================================================
echo "Pass 1: Building mapping of old filenames → new hashes..."

# Associative arrays:
#   SEQNUM_FILES[4digit_seqnum] = newline-separated list of file paths
#   SEQNUM_PRIMARY[4digit_seqnum] = path to TSK/INC (primary doc)
#   SEQNUM_HASH[4digit_seqnum] = computed Task ID for entire group
#   OLD_HASH_MAP[old_basename] = new_6char_hash
#   OLD_PATH_MAP[old_path] = new_path

declare -A SEQNUM_FILES=()    # old_seqnum → list of file paths
declare -A SEQNUM_PRIMARY=()  # old_seqnum → path to TSK/INC
declare -A SEQNUM_HASH=()     # old_seqnum → computed Task ID
declare -A OLD_HASH_MAP=()    # old_basename → new_hash (for ALL files)
declare -A OLD_PATH_MAP=()    # old_path → new_path
declare -i doc_count=0        # count of documents found

echo "  Step 1: Collecting files and grouping by seqnum..."

# Step 1: Collect all files and group by seqnum
while IFS= read -r old_path; do
  [[ -z "$old_path" ]] && continue

  old_basename=$(basename "$old_path")
  old_id="${old_basename:0:4}"
  doc_type="${old_basename:16:3}"

  # Add to group (newline-separated list)
  SEQNUM_FILES["$old_id"]+="$old_path"$'\n'
  doc_count=$((doc_count + 1))

  # Track primary (TSK or INC) - first one found wins
  if [[ "$doc_type" == "TSK" ]] || [[ "$doc_type" == "INC" ]]; then
    if [[ -z "${SEQNUM_PRIMARY[$old_id]:-}" ]]; then
      SEQNUM_PRIMARY["$old_id"]="$old_path"
    fi
  fi

done < <(find "$DOCS_DIR" -type f -name "[0-9][0-9][0-9][0-9]-*-[A-Z][A-Z][A-Z]-*" 2>/dev/null | sort || true)

echo "  Step 2: Computing Task ID for each work item group..."

# Step 2: Compute hash for each work item group (from primary doc)
for old_id in $(printf '%s\n' "${!SEQNUM_FILES[@]}" | sort); do
  primary="${SEQNUM_PRIMARY[$old_id]:-}"

  if [[ -z "$primary" ]]; then
    # No TSK/INC found - use first file in group
    echo "  ⚠️  Warning: No TSK/INC found for seqnum $old_id, using first file"
    primary=$(echo "${SEQNUM_FILES[$old_id]}" | head -1)
  fi

  # Extract datetime and slug from PRIMARY doc only
  primary_basename=$(basename "$primary")
  primary_datetime="${primary_basename:5:10}"
  primary_slug_with_ext="${primary_basename:20}"

  # Split slug from extension
  if [[ "$primary_slug_with_ext" =~ ^(.+)(\.[^.]+)$ ]]; then
    primary_slug="${BASH_REMATCH[1]}"
  else
    primary_slug="$primary_slug_with_ext"
  fi

  # Compute hash from PRIMARY's datetime+slug ONLY
  group_hash=$(compute_task_id "$primary_datetime" "$primary_slug")
  SEQNUM_HASH["$old_id"]="$group_hash"

  echo "  Work item $old_id → Task ID $group_hash (from: $(basename "$primary"))"
done

echo "  Step 3: Mapping all files to new paths with shared Task ID..."

# Step 3: Map all files to their new paths using group's shared hash
for old_id in $(printf '%s\n' "${!SEQNUM_FILES[@]}" | sort); do
  group_hash="${SEQNUM_HASH[$old_id]}"

  # Get primary doc for this group to determine folder
  primary_path="${SEQNUM_PRIMARY[$old_id]:-}"
  if [[ -z "$primary_path" ]]; then
    primary_path=$(echo "${SEQNUM_FILES[$old_id]}" | head -1)
  fi
  primary_basename=$(basename "$primary_path")
  primary_datetime="${primary_basename:5:10}"

  # All files in this group go to the same year-month folder (based on primary)
  year_month=$(compute_year_month "$primary_datetime")

  # Process each file in the group
  while IFS= read -r old_path; do
    [[ -z "$old_path" ]] && continue

    old_basename=$(basename "$old_path")
    datetime="${old_basename:5:10}"      # Each file keeps its own datetime
    doc_type="${old_basename:16:3}"
    slug_with_ext="${old_basename:20}"

    # Split slug from extension
    if [[ "$slug_with_ext" =~ ^(.+)(\.[^.]+)$ ]]; then
      slug="${BASH_REMATCH[1]}"
      extension="${BASH_REMATCH[2]}"
    else
      slug="$slug_with_ext"
      extension=""
    fi

    # New basename: GROUP hash + file's own datetime + file's type/slug/ext
    new_basename="${group_hash}-${datetime}-${doc_type}-${slug}${extension}"

    # Determine active or completed from path
    if [[ "$old_path" == *"/active/"* ]]; then
      status_dir="active"
    elif [[ "$old_path" == *"/completed/"* ]]; then
      status_dir="completed"
    else
      status_dir="active"
    fi

    new_dir="${DOCS_DIR}/${status_dir}/${year_month}"
    new_path="${new_dir}/${new_basename}"

    OLD_HASH_MAP["$old_basename"]="$group_hash"
    OLD_PATH_MAP["$old_path"]="$new_path"

  done <<< "${SEQNUM_FILES[$old_id]}"
done

# Also populate SEQ_TSK_HASH for Pass 3 (content updates)
declare -A SEQ_TSK_HASH=()
declare -A SEQ_FOLDER=()
for old_id in "${!SEQNUM_HASH[@]}"; do
  SEQ_TSK_HASH["$old_id"]="${SEQNUM_HASH[$old_id]}"

  # Get primary to determine folder
  primary_path="${SEQNUM_PRIMARY[$old_id]:-}"
  if [[ -z "$primary_path" ]]; then
    primary_path=$(echo "${SEQNUM_FILES[$old_id]}" | head -1)
  fi
  primary_basename=$(basename "$primary_path")
  primary_datetime="${primary_basename:5:10}"
  year_month=$(compute_year_month "$primary_datetime")

  if [[ "$primary_path" == *"/active/"* ]]; then
    status_dir="active"
  elif [[ "$primary_path" == *"/completed/"* ]]; then
    status_dir="completed"
  else
    status_dir="active"
  fi

  SEQ_FOLDER["$old_id"]="${DOCS_DIR}/${status_dir}/${year_month}"
done

total=$doc_count
echo "  Found $total documents to migrate"

if [[ $total -eq 0 ]]; then
  echo "  Nothing to migrate — no 4-digit seqnum documents found."
  exit 0
fi

# Show mapping summary
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "Planned renames:"
  for old_path in $(printf '%s\n' "${!OLD_PATH_MAP[@]}" | sort); do
    new_path="${OLD_PATH_MAP[$old_path]}"
    echo "  $(basename "$old_path")"
    echo "    → $(basename "$new_path")"
    echo "    → folder: $(dirname "$new_path")"
  done
  echo ""
fi

# ============================================================
# Pass 2: Move files (git mv)
# ============================================================
echo "Pass 2: Moving files..."

rename_count=0
for old_path in $(printf '%s\n' "${!OLD_PATH_MAP[@]}" | sort); do
  new_path="${OLD_PATH_MAP[$old_path]}"
  new_dir=$(dirname "$new_path")

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  would move: $old_path → $new_path"
  else
    mkdir -p "$new_dir"
    git -C "$REPO_ROOT" mv "$old_path" "$new_path"
    echo "  moved: $(basename "$old_path") → $(basename "$new_path")"
  fi
  rename_count=$((rename_count + 1))
done

echo "  $rename_count files $( [[ "$DRY_RUN" == "true" ]] && echo "would be renamed" || echo "renamed")"

# ============================================================
# Pass 3: Update content in migrated files
# ============================================================
echo ""
echo "Pass 3: Updating internal content..."

update_count=0
for old_path in $(printf '%s\n' "${!OLD_PATH_MAP[@]}" | sort); do
  new_path="${OLD_PATH_MAP[$old_path]}"
  old_basename=$(basename "$old_path")
  new_basename=$(basename "$new_path")

  # Extract old seqnum from old basename
  old_id="${old_basename:0:4}"
  new_hash="${OLD_HASH_MAP[$old_basename]}"
  new_dir=$(dirname "$new_path")

  # Determine the TSK hash for this work item's cross-references
  tsk_hash="${SEQ_TSK_HASH[$old_id]:-$new_hash}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  would update: $new_basename"
    echo "    Work Item: $old_id → $new_hash"
    echo "    Related To: TSK $old_id → TSK $tsk_hash"
    echo "    Folder: (insert) $new_dir"
  else
    # Update Work Item field: "**Work Item**: NNNN" → "**Work Item**: NEWHASH"
    sedi "s/^\*\*Work Item\*\*: ${old_id}$/**Work Item**: ${new_hash}/" "$new_path"

    # Update Related To field: "**Related To**: TSK NNNN" → "**Related To**: TSK TSKHASH"
    sedi "s/^\*\*Related To\*\*: TSK ${old_id}$/**Related To**: TSK ${tsk_hash}/" "$new_path"

    # Insert Folder field after Work Item line if not already present
    # Uses newline variable for portable sed append (BSD + GNU compatible)
    if ! grep -q '^\*\*Folder\*\*:' "$new_path"; then
      sedi "/^\*\*Work Item\*\*: ${new_hash}$/a\\
**Folder**: ${new_dir}" "$new_path"
    fi

    # Update ALL known old filename references in this document body
    # (self-references AND cross-references to other migrated documents)
    for known_old in "${!OLD_HASH_MAP[@]}"; do
      known_new_hash="${OLD_HASH_MAP[$known_old]}"
      # known_old format: NNNN-DATETIME-TYPE-slug.md
      known_new="${known_new_hash}${known_old:4}"  # replace 4-char prefix with new hash
      if [[ "$known_old" != "$known_new" ]] && grep -qF "$known_old" "$new_path" 2>/dev/null; then
        old_escaped=$(printf '%s\n' "$known_old" | sed 's/[[\.*^$()+?{|]/\\&/g')
        new_escaped=$(printf '%s\n' "$known_new" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sedi "s/${old_escaped}/${new_escaped}/g" "$new_path" || true
      fi
    done

    if [[ "$old_basename" != "$new_basename" ]]; then
      # Self-reference fallback (already handled above, but keep for clarity)
      true
    fi

    echo "  updated: $new_basename"
  fi
  update_count=$((update_count + 1))
done

echo "  $update_count files $( [[ "$DRY_RUN" == "true" ]] && echo "would be updated" || echo "updated")"

# ============================================================
# Pass 4: Cleanup empty old folders + regenerate indexes
# ============================================================
echo ""
echo "Pass 4: Cleanup and index regeneration..."

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  would remove: $DOCS_DIR/active/0000-0099 (if empty)"
  echo "  would remove: $DOCS_DIR/completed/0000-0099 (if empty)"
  echo "  would regenerate: SEQUENCE-TRACKER.md and DOCUMENT-INDEX.md"
else
  # Remove old range folders if empty
  for old_range_dir in "$DOCS_DIR/active/0000-0099" "$DOCS_DIR/completed/0000-0099"; do
    if [[ -d "$old_range_dir" ]]; then
      remaining=$(find "$old_range_dir" -type f 2>/dev/null | wc -l || echo 0)
      if [[ $remaining -eq 0 ]]; then
        git -C "$REPO_ROOT" rm -r --cached --ignore-unmatch "$old_range_dir" 2>/dev/null || true
        rmdir "$old_range_dir" 2>/dev/null || true
        echo "  removed empty dir: $old_range_dir"
      else
        echo "  skipping non-empty dir: $old_range_dir ($remaining files remain)"
      fi
    fi
  done

  # Regenerate documentation indexes
  echo "  Regenerating SEQUENCE-TRACKER.md and DOCUMENT-INDEX.md..."
  "${HOME}/.claude/scripts/update-docs.sh" --docs-dir "$DOCS_DIR" 2>&1 | grep -E "✓|⚠️|Error|Found:" || true
fi

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN COMPLETE ==="
  echo "Summary: $rename_count files would be renamed, $update_count cross-references would be updated"
  echo "Run without --dry-run to execute migration."
else
  echo "=== MIGRATION COMPLETE ==="
  echo "Summary: $rename_count files moved, $update_count files updated"
fi
