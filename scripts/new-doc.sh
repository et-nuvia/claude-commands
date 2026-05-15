#!/usr/bin/env bash
# Global document creation script for V4 naming convention
# Format: <TASK_ID>-<DATETIME>-<TYPE>-<description>.md
#
# Usage:
#   new-doc.sh --type <TYPE> --description <desc> [--new | --id TASK_ID] [--status STATUS] [--json]
#
# Modes:
#   Interactive (default): Creates file on disk, updates indexes, prints summary
#   JSON (--json):         Returns filepath + template content as JSON. Does NOT write the file.
#                          The caller (LLM) writes the completed document directly.
#
# Automatically detects project docs folder from current directory

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Source shared utilities
source "${HOME}/.claude/scripts/common.sh"
source "${HOME}/.claude/scripts/doc-utils.sh"

# macOS/BSD sed compatibility: sed -i requires '' on macOS
if [[ "$(uname -s)" == "Darwin" ]]; then
    sedi() { sed -i '' "$@"; }
else
    sedi() { sed -i "$@"; }
fi

# Parse arguments
TYPE=""
DESCRIPTION=""
MODE=""
TASK_ID=""
STATUS="active"
OUTPUT_MODE="interactive"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)
            TYPE=$(echo "$2" | tr '[:lower:]' '[:upper:]')
            shift 2
            ;;
        --description)
            DESCRIPTION="$2"
            shift 2
            ;;
        --new)
            MODE="new"
            shift
            ;;
        --id)
            MODE="existing"
            TASK_ID="$2"
            shift 2
            ;;
        --seq)
            # Backward compatibility: treat --seq as --id
            MODE="existing"
            TASK_ID="$2"
            shift 2
            ;;
        --status)
            STATUS="$2"
            shift 2
            ;;
        --json)
            OUTPUT_MODE="json"
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: $0 --type <TYPE> --description <desc> [--new | --id TASK_ID] [--status STATUS] [--json]

Create documentation with V4 naming: <TASK_ID>-<DATETIME>-<TYPE>-<description>.md

Flags:
  --type TYPE        3-letter document type (see list below)
  --description DESC Kebab-case description
  --new              Create new work item (compute Task ID from datetime+description)
  --id ID            Add to existing work item (6-char hex Task ID, e.g. A3F2B9)
  --status           'active' or 'completed' (default: active)
  --json             Return filepath + template as JSON without writing the file

Document Types:
  INC    Incident (primary)
  TSK    Task (primary)
  FRV    Feature Review (related)
  FND    Findings (related)
  FIX    Fix (related)
  RCA    Root Cause Analysis (related)
  DEP    Deployment (related)
  CRV    Code Review (related)
  RSK    Risk Analysis (related)
  AUD    Audit (related)
  IMP    Implementation Guide (related)
  RSC    Research (related)
  LRN    Lessons Learned (related)
  PLN    Plan (related)
  RSP    Response (related)
  SUM    Summary (related)
  SVC    Service (standalone)
  RUN    Execution Run (related)
  SCR    Script/Automation (standalone)
  REF    Reference (standalone knowledge base article)
  REV    Feature Review (standalone)
  RFA    Refactor Analysis (standalone)
  PERF   Performance Analysis (standalone)
  DEAD   Dead Code Removal (standalone)
  AUDIT  Coverage Audit (standalone)
  NET    Network Audit (standalone)
  TSP    Test Plan (related)
  TSR    Test Results (related)

Examples:
  # New incident (auto-generates Task ID)
  $0 --type INC --description webservices-down --new

  # Add findings to existing work item A3F2B9
  $0 --type FND --description webservices-investigation --id A3F2B9

  # Get JSON for LLM to write directly (no file created)
  $0 --type TSK --description fix-login-bug --new --json
EOF
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown argument '$1'${NC}" >&2
            exit 1
            ;;
    esac
done

# Validate required flags
if [[ -z "$TYPE" ]]; then
    echo -e "${RED}Error: --type is required${NC}" >&2
    echo "Usage: $0 --type <TYPE> --description <desc> [--new | --id TASK_ID]" >&2
    exit 1
fi

if [[ -z "$DESCRIPTION" ]]; then
    echo -e "${RED}Error: --description is required${NC}" >&2
    echo "Usage: $0 --type <TYPE> --description <desc> [--new | --id TASK_ID]" >&2
    exit 1
fi

# Find docs directory
DOCS_DIR=$(find_docs_dir)

if [[ "$OUTPUT_MODE" != "json" ]]; then
    echo -e "${GREEN}✓${NC} Using docs directory: ${DOCS_DIR}"

    # Regenerate documentation BEFORE reading to ensure accuracy
    echo -e "${BLUE}Regenerating documentation for accurate tracking...${NC}"
    "${HOME}/.claude/scripts/update-docs.sh" --docs-dir "${DOCS_DIR}" 2>&1 | grep -E "✓|⚠️|Error|Found:" || true
    echo ""
fi

# If no mode specified, prompt (interactive only)
if [[ -z "${MODE}" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Default to new in JSON mode — no interactive prompts
        MODE="new"
    else
        echo -e "${BLUE}Create new work item or add to existing?${NC}"
        echo "  N - New work item (auto-generate Task ID)"
        echo "  TASK_ID - Existing work item (6-char hex, e.g. A3F2B9)"
        read -p "Choice [N/Task ID]: " CHOICE

        if [[ "${CHOICE}" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            MODE="existing"
            TASK_ID="${CHOICE}"
        else
            MODE="new"
        fi
    fi
fi

# Validate type
VALID_TYPES=("INC" "RCA" "TSK" "FND" "FIX" "DEP" "CRV" "RSK" "AUD" "IMP" "RSC" "LRN" "PLN" "RSP" "UPD" "SUM" "SVC" "RUN" "SCR" "REF" "FRV" "REV" "RFA" "PERF" "DEAD" "AUDIT" "NET" "TSP" "TSR" "QST" "DES" "DSN" "ART" "ARC")
if [[ ! " ${VALID_TYPES[@]} " =~ " ${TYPE} " ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        jq -nc --arg t "$TYPE" '{status:"error",message:"Invalid document type",type:$t}'
        exit 1
    fi
    echo -e "${RED}Error: Invalid type '${TYPE}'${NC}"
    echo "Valid types: ${VALID_TYPES[*]}"
    exit 1
fi

# Validate status
if [[ "${STATUS}" != "active" && "${STATUS}" != "completed" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        jq -nc '{status:"error",message:"Status must be active or completed"}'
        exit 1
    fi
    echo -e "${RED}Error: Status must be 'active' or 'completed'${NC}"
    exit 1
fi

# Validate description
if [[ ! "${DESCRIPTION}" =~ ^[a-z0-9-]+$ ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        jq -nc '{status:"error",message:"Description must be lowercase kebab-case"}'
        exit 1
    fi
    echo -e "${RED}Error: Description must be lowercase kebab-case${NC}"
    exit 1
fi

# Generate datetime
DATETIME=$(date +%y%m%d%H%M)

# Determine Task ID
if [[ "${MODE}" == "new" ]]; then
    TASK_ID=$(compute_task_id "$DATETIME" "$DESCRIPTION")
    if [[ "$OUTPUT_MODE" != "json" ]]; then
        echo -e "${YELLOW}Generated new Task ID: ${TASK_ID}${NC}"
    fi
else
    # Validate Task ID format
    TASK_ID=$(normalize_task_id "$TASK_ID") || exit 1

    EXISTING=$(find "${DOCS_DIR}/active" "${DOCS_DIR}/completed" -name "${TASK_ID}-*" 2>/dev/null | head -1 || true)
    if [[ -z "${EXISTING}" ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            # In JSON mode, proceed without prompting — caller has context
            true
        else
            echo -e "${YELLOW}Warning: No existing documents for Task ID ${TASK_ID}${NC}"
            read -p "Continue? [y/N]: " CONFIRM
            if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
    else
        if [[ "$OUTPUT_MODE" != "json" ]]; then
            echo -e "${GREEN}Adding to existing work item ${TASK_ID}${NC}"
            find "${DOCS_DIR}/active" "${DOCS_DIR}/completed" -name "${TASK_ID}-*" -exec basename {} \; | sort
        fi
    fi
fi

# Generate filename
FILENAME="${TASK_ID}-${DATETIME}-${TYPE}-${DESCRIPTION}.md"

# Calculate date-based folder (YYYY-MM from datetime)
YEAR_MONTH=$(compute_year_month "$DATETIME")
TARGET_DIR="${DOCS_DIR}/${STATUS}/${YEAR_MONTH}"
FILEPATH="${TARGET_DIR}/${FILENAME}"

# Check if exists
if [[ -f "${FILEPATH}" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        jq -nc --arg p "$FILEPATH" '{status:"error",message:"File already exists",filepath:$p}'
        exit 1
    fi
    echo -e "${RED}Error: File already exists: ${FILEPATH}${NC}"
    exit 1
fi

# Format datetime for display
YEAR="20${DATETIME:0:2}"
MONTH="${DATETIME:2:2}"
DAY="${DATETIME:4:2}"
HOUR="${DATETIME:6:2}"
MIN="${DATETIME:8:2}"
DISPLAY_DATE="${YEAR}-${MONTH}-${DAY} ${HOUR}:${MIN}"

# Build template content with placeholders replaced
TEMPLATE_PATH="${HOME}/.claude/templates/task-${TYPE}.md"
TEMPLATE_CONTENT=""

# Find related documents for this work item
RELATED_DOCS=$(find "${DOCS_DIR}/active" "${DOCS_DIR}/completed" -name "${TASK_ID}-*" 2>/dev/null | xargs -I {} basename {} | sort || echo "(This is the first document)")

if [[ -f "${TEMPLATE_PATH}" ]]; then
    # Read template and replace placeholders in memory
    TEMPLATE_CONTENT=$(cat "${TEMPLATE_PATH}")
    TEMPLATE_CONTENT=$(echo "$TEMPLATE_CONTENT" | sed "s/\[TASK_ID\]/${TASK_ID}/g")
    TEMPLATE_CONTENT=$(echo "$TEMPLATE_CONTENT" | sed "s/\[SEQNUM\]/${TASK_ID}/g")
    TEMPLATE_CONTENT=$(echo "$TEMPLATE_CONTENT" | sed "s|\[FOLDER\]|${TARGET_DIR}|g")
    TEMPLATE_CONTENT=$(echo "$TEMPLATE_CONTENT" | sed "s/\[YYYY-MM-DD HH:MM\]/${DISPLAY_DATE}/g")
    TEMPLATE_CONTENT=$(echo "$TEMPLATE_CONTENT" | sed "s/\[YYYY-MM-DD\]/$(date +%Y-%m-%d)/g")
    TEMPLATE_CONTENT=$(echo "$TEMPLATE_CONTENT" | sed "s/\[Brief Description\]/${DESCRIPTION}/g")

    # Resolve [EXTERNAL_TRACKING_BLOCK] to the right backend partial.
    # Source of truth: PROJECT.yaml task_management.backend (asana | gitlab).
    # Fallback: macOS=asana (work), other=gitlab (home).
    if [[ "$TEMPLATE_CONTENT" == *"[EXTERNAL_TRACKING_BLOCK]"* ]]; then
        EXT_BACKEND=""
        if [[ -f "PROJECT.yaml" ]] && declare -f yaml_get &>/dev/null; then
            EXT_BACKEND=$(yaml_get '.task_management.backend // ""' PROJECT.yaml 2>/dev/null)
        fi
        if [[ -z "$EXT_BACKEND" ]]; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                EXT_BACKEND="asana"
            else
                EXT_BACKEND="gitlab"
            fi
        fi

        EXT_PARTIAL_PATH="${HOME}/.claude/templates/external-tracking-${EXT_BACKEND}.md"
        if [[ -f "${EXT_PARTIAL_PATH}" ]]; then
            # Use awk to read the partial file and replace the placeholder line.
            # Avoids passing multi-line content through -v (which BSD awk rejects).
            TEMPLATE_CONTENT=$(awk -v partial="$EXT_PARTIAL_PATH" '
                /\[EXTERNAL_TRACKING_BLOCK\]/ {
                    while ((getline line < partial) > 0) print line
                    close(partial)
                    next
                }
                { print }
            ' <<< "$TEMPLATE_CONTENT")
        fi
    fi

    # Append related documents section
    TEMPLATE_CONTENT="${TEMPLATE_CONTENT}

---

## Related Documents (Work Item ${TASK_ID})

Find all related documents:
\`\`\`bash
find docs -name \"${TASK_ID}-*\"
\`\`\`

Current documents:
\`\`\`
${RELATED_DOCS}
\`\`\`"
else
    # Fallback to minimal structure if no template
    TEMPLATE_CONTENT="# Work Item ${TASK_ID}: ${DESCRIPTION}

**Type**: ${TYPE}
**Work Item**: ${TASK_ID}
**Folder**: ${TARGET_DIR}
**Created**: ${DISPLAY_DATE}
**Status**: ${STATUS}
**Filename**: ${FILENAME}

---

## Summary

[Brief description]

---

## Related Documents (Work Item ${TASK_ID})

Find all related documents:
\`\`\`bash
find docs -name \"${TASK_ID}-*\"
\`\`\`

Current documents:
\`\`\`
${RELATED_DOCS}
\`\`\`

---

## Details

[Detailed information]

---

**Created**: ${DISPLAY_DATE}
**Work Item**: ${TASK_ID}
**Type**: ${TYPE}"
fi

# ============================================================================
# JSON mode: return everything the LLM needs, don't write the file
# ============================================================================
if [[ "$OUTPUT_MODE" == "json" ]]; then
    mkdir -p "${TARGET_DIR}"
    jq -nc \
        --arg status "success" \
        --arg task_id "$TASK_ID" \
        --arg filepath "$FILEPATH" \
        --arg filename "$FILENAME" \
        --arg docs_dir "$DOCS_DIR" \
        --arg target_dir "$TARGET_DIR" \
        --arg display_date "$DISPLAY_DATE" \
        --arg type "$TYPE" \
        --arg description "$DESCRIPTION" \
        --arg mode "$MODE" \
        --arg template "$TEMPLATE_CONTENT" \
        --arg related_docs "$RELATED_DOCS" \
        '{
            status: $status,
            task_id: $task_id,
            filepath: $filepath,
            filename: $filename,
            docs_dir: $docs_dir,
            target_dir: $target_dir,
            display_date: $display_date,
            type: $type,
            description: $description,
            mode: $mode,
            template: $template,
            related_docs: $related_docs
        }'
    exit 0
fi

# ============================================================================
# Interactive mode: write file to disk, update indexes
# ============================================================================

echo "$TEMPLATE_CONTENT" > "${FILEPATH}"

# Confirm action
if [[ "${MODE}" == "new" ]]; then
    echo -e "${GREEN}✓${NC} New work item: ${TASK_ID}"
else
    echo -e "${GREEN}✓${NC} Added to work item: ${TASK_ID}"
fi

# Regenerate documentation to include the newly created document
echo ""
echo -e "${BLUE}Updating documentation with new document...${NC}"
"${HOME}/.claude/scripts/update-docs.sh" --docs-dir "${DOCS_DIR}" 2>&1 | grep -E "✓|⚠️|Error" || true

# Success
echo ""
echo -e "${GREEN}✓${NC} Created: ${FILENAME}"
echo -e "${GREEN}✓${NC} Location: ${STATUS}/${YEAR_MONTH}/"
echo -e "${GREEN}✓${NC} Timestamp: ${DISPLAY_DATE}"
echo -e "${GREEN}✓${NC} Full path: ${FILEPATH}"
echo ""
echo -e "${BLUE}All documents for work item ${TASK_ID}:${NC}"
find "${DOCS_DIR}/active" "${DOCS_DIR}/completed" -name "${TASK_ID}-*" -exec basename {} \; | sort
