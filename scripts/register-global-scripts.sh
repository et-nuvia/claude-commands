#!/usr/bin/env bash
set -euo pipefail

# Register global scripts from ~/.claude/scripts so they don't require approval
# Adds new scripts and removes scripts that no longer exist

SCRIPT_DIR="${HOME}/.claude/scripts"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "🔍 Scanning for global scripts in ${SCRIPT_DIR}..."

# Find all executable scripts
if [[ ! -d "${SCRIPT_DIR}" ]]; then
  echo "❌ Directory ${SCRIPT_DIR} does not exist"
  exit 1
fi

# Get list of executable scripts currently on filesystem
mapfile -t CURRENT_SCRIPTS < <(find "${SCRIPT_DIR}" -type f -name "*.sh" | while IFS= read -r f; do [[ -x "$f" ]] && echo "$f"; done | sort)

if [[ ${#CURRENT_SCRIPTS[@]} -eq 0 ]]; then
  echo "⚠️  No executable .sh scripts found in ${SCRIPT_DIR}"
  # Continue anyway to clean up old entries
fi

# Check if settings file exists
if [[ ! -f "${CLAUDE_SETTINGS}" ]]; then
  echo "⚠️  Claude settings file not found at ${CLAUDE_SETTINGS}"
  echo "Creating basic settings file..."
  mkdir -p "$(dirname "${CLAUDE_SETTINGS}")"
  echo '{}' > "${CLAUDE_SETTINGS}"
fi


# Check for jq
if ! command -v jq &> /dev/null; then
  echo "❌ jq is required but not installed"
  echo "Install with: sudo apt-get install jq (or appropriate package manager)"
  exit 1
fi

# Get existing auto-approve list
mapfile -t EXISTING_SCRIPTS < <(jq -r '.autoApprove.bash[]? // empty' "${CLAUDE_SETTINGS}")

# Separate global scripts from other entries
declare -a GLOBAL_IN_SETTINGS=()
declare -a NON_GLOBAL_ENTRIES=()

for entry in "${EXISTING_SCRIPTS[@]}"; do
  if [[ "${entry}" == "${SCRIPT_DIR}"* ]]; then
    GLOBAL_IN_SETTINGS+=("${entry}")
  else
    NON_GLOBAL_ENTRIES+=("${entry}")
  fi
done

# Find scripts to add (in filesystem but not in settings)
declare -a TO_ADD=()
for script in "${CURRENT_SCRIPTS[@]}"; do
  found=false
  for existing in "${GLOBAL_IN_SETTINGS[@]}"; do
    if [[ "${script}" == "${existing}" ]]; then
      found=true
      break
    fi
  done
  if [[ "${found}" == "false" ]]; then
    TO_ADD+=("${script}")
  fi
done

# Find scripts to remove (in settings but not in filesystem)
declare -a TO_REMOVE=()
for existing in "${GLOBAL_IN_SETTINGS[@]}"; do
  if [[ ! -f "${existing}" ]]; then
    TO_REMOVE+=("${existing}")
  fi
done

# Build the new list: non-global entries + current scripts
PATTERNS="["

# First add non-global entries to preserve them
for entry in "${NON_GLOBAL_ENTRIES[@]}"; do
  ESCAPED=$(printf '%s' "${entry}" | jq -R .)
  PATTERNS="${PATTERNS}${ESCAPED},"
done

# Then add current global scripts
for script in "${CURRENT_SCRIPTS[@]}"; do
  ESCAPED=$(printf '%s' "${script}" | jq -R .)
  PATTERNS="${PATTERNS}${ESCAPED},"
done

# Remove trailing comma and close array
PATTERNS="${PATTERNS%,}]"

# Handle empty array case
if [[ "${PATTERNS}" == "[" ]]; then
  PATTERNS="[]"
fi

# Update settings.json with the new clean list
jq --argjson patterns "${PATTERNS}" '
  .autoApprove = (.autoApprove // {}) |
  .autoApprove.bash = $patterns
' "${CLAUDE_SETTINGS}" > "${CLAUDE_SETTINGS}.tmp"

mv "${CLAUDE_SETTINGS}.tmp" "${CLAUDE_SETTINGS}"

# Report results
echo ""
if [[ ${#TO_ADD[@]} -eq 0 ]] && [[ ${#TO_REMOVE[@]} -eq 0 ]]; then
  echo "✅ No changes needed - all scripts are up to date"
else
  echo "✅ Successfully updated global scripts"
fi

if [[ ${#TO_ADD[@]} -gt 0 ]]; then
  echo ""
  echo "➕ Added ${#TO_ADD[@]} new script(s):"
  printf '   - %s\n' "${TO_ADD[@]}"
fi

if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
  echo ""
  echo "➖ Removed ${#TO_REMOVE[@]} missing script(s):"
  printf '   - %s\n' "${TO_REMOVE[@]}"
fi

echo ""
echo "📋 Currently registered global scripts (${#CURRENT_SCRIPTS[@]} total):"
printf '   - %s\n' "${CURRENT_SCRIPTS[@]}"
echo ""
echo "💡 These scripts will run without approval prompts"
