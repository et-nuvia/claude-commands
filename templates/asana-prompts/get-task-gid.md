# Get Asana Task GID from Local Document

Use this pattern to extract the Asana task GID from a local task document.

## Logic

```bash
# 1. Find task document by task ID
SEQUENCE="0002"
TASK_DOC=$(find docs/active -name "${SEQUENCE}-*-TSK-*.md" | head -1)

if [[ -z "$TASK_DOC" ]]; then
  echo "Error: Task document not found for task ID $SEQUENCE"
  exit 1
fi

# 2. Extract Asana Task GID from document
TASK_GID=$(grep -A 10 "^## External Tracking" "$TASK_DOC" | \
           grep "^- Task GID:" | \
           sed 's/- Task GID: \[\?\([0-9]*\)\]\?/\1/' | \
           tr -d '[]')

# 3. Check if GID exists
if [[ -z "$TASK_GID" ]]; then
  echo "No Asana task linked to this document - skipping Asana sync"
  exit 0
fi

echo "$TASK_GID"
```

## MCP Integration Pattern

For task commands, extract the GID before calling MCP tools:

```markdown
## Get Asana Task GID

1. Read the current task document (docs/active/<range>/<task_id>-*-TSK-*.md)
2. Look for "External Tracking > Asana > Task GID" field
3. Extract the numeric GID (remove brackets if present)
4. If GID not found: Skip Asana operations (not linked to Asana task)
5. If GID found: Use it for MCP tool calls

**Expected format in document**:
```markdown
## External Tracking

**Asana**:
- Task GID: 1234567890
- Task URL: https://app.asana.com/0/PROJECT_ID/TASK_ID
```

## When to Store Task GID

Task GID should be stored in the document when:
1. **Capturing from Asana**: `/task-capture <asana-url>` creates doc with GID
2. **Creating in Asana**: `/task-create` returns GID, store it in doc
3. **Manual linking**: User can manually add GID to existing doc

## URL to GID Extraction

If you have an Asana URL, extract the GID:

```bash
# URL format: https://app.asana.com/0/PROJECT_ID/TASK_ID
# Or: https://app.asana.com/0/PROJECT_ID/TASK_ID/f

ASANA_URL="https://app.asana.com/0/1234567890/9876543210"
TASK_GID=$(echo "$ASANA_URL" | sed -E 's|.*/([0-9]+)(/.*)?$|\1|')
# Result: 9876543210
```

## Example: Extracting from task-capture Input

```bash
# User provides: /task-capture https://app.asana.com/0/1234567890/9876543210
# Or: /task-capture 9876543210

INPUT="$1"

if [[ "$INPUT" =~ ^https?://app\.asana\.com ]]; then
  # It's a URL - extract GID
  TASK_GID=$(echo "$INPUT" | sed -E 's|.*/([0-9]+)(/.*)?$|\1|')
elif [[ "$INPUT" =~ ^[0-9]+$ ]]; then
  # It's already a GID
  TASK_GID="$INPUT"
else
  echo "Error: Invalid Asana task reference. Provide URL or numeric GID."
  exit 1
fi
```

## Storing GID in Document

After fetching or creating an Asana task, store the GID:

```bash
# Update the External Tracking section
sed -i '' "s/- Task GID: \[.*\]/- Task GID: ${TASK_GID}/" "$TASK_DOC"
sed -i '' "s/- Task URL: \[.*\]/- Task URL: https:\/\/app.asana.com\/0\/PROJECT_ID\/${TASK_GID}/" "$TASK_DOC"
```

## Validation

Before using a GID with MCP tools:

```markdown
1. Check GID is numeric: `[[ "$TASK_GID" =~ ^[0-9]+$ ]]`
2. Check GID is not empty: `[[ -n "$TASK_GID" ]]`
3. If validation fails: Skip Asana operation, log warning
```

## Example Usage in Task Commands

```markdown
## Step: Get Asana Task GID

1. Read task document for current sequence
2. Extract Asana Task GID from External Tracking section
3. If no GID found: Skip Asana sync (not linked)
4. If GID found: Validate it's numeric
5. Use GID for subsequent MCP tool calls
```
