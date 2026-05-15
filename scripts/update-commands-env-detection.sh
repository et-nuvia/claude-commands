#!/usr/bin/env bash
# Update commands to use centralized environment detection

set -euo pipefail

COMMANDS_DIR="${HOME}/.claude/commands"
DETECT_SCRIPT="\${HOME}/.claude/scripts/detect-environment.sh"

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

# Pattern 1: Replace uname -s environment detection
update_uname_pattern() {
  local file="$1"

  # Pattern: if [[ "$(uname -s)" == "Darwin" ]]; then ENV_TYPE="work" else ENV_TYPE="home" fi
  if grep -q 'uname -s' "$file" 2>/dev/null; then
    # Create temp file
    local temp_file="${file}.tmp"

    # Replace the pattern
    awk '
      /if \[\[ "\$\(uname -s\)" == "Darwin" \]\]; then/ {
        indent = match($0, /[^ ]/)
        spaces = substr($0, 1, indent-1)
        print spaces "# Detect environment using centralized script"
        print spaces "ENV_TYPE=$(\"${HOME}/.claude/scripts/detect-environment.sh\" environment)"
        # Skip next lines until fi
        while (getline > 0) {
          if (/^[[:space:]]*fi[[:space:]]*$/) break
        }
        next
      }
      { print }
    ' "$file" > "$temp_file"

    if [[ -s "$temp_file" ]]; then
      mv "$temp_file" "$file"
      print_success "Updated uname pattern in $(basename "$file")"
      return 0
    else
      rm -f "$temp_file"
      return 1
    fi
  fi
  return 1
}

# Pattern 2: Replace inline uname checks
update_inline_uname() {
  local file="$1"

  if grep -q 'uname -s.*Darwin' "$file" 2>/dev/null; then
    sed -i.bak \
      -e 's/if \[\[ "\$(uname -s)" == "Darwin" \]\]; then SECRETS_BACKEND="aws" else SECRETS_BACKEND="infisical" fi/SECRETS_BACKEND=$(\"${HOME}\/.claude\/scripts\/detect-environment.sh\" secrets-backend)/g' \
      -e 's/if \[\[ "\$(uname -s)" == "Darwin" \]\]; then DEFAULT_BACKEND="asana" else DEFAULT_BACKEND="gitlab" fi/DEFAULT_BACKEND=$(\"${HOME}\/.claude\/scripts\/detect-environment.sh\" task-backend)/g' \
      "$file"

    if ! diff -q "$file" "${file}.bak" >/dev/null 2>&1; then
      rm -f "${file}.bak"
      print_success "Updated inline uname in $(basename "$file")"
      return 0
    else
      mv "${file}.bak" "$file"
      return 1
    fi
  fi
  return 1
}

# Pattern 3: Add script usage comment at top
add_usage_comment() {
  local file="$1"

  # Check if already has the comment
  if grep -q "detect-environment.sh" "$file" 2>/dev/null; then
    return 1
  fi

  # Check if file uses environment detection
  if grep -qE '(uname|PROJECT\.yaml|git.*platform)' "$file" 2>/dev/null; then
    # Find where to insert (after frontmatter)
    local insert_line=$(awk '/^---$/{c++; if(c==2){print NR+1; exit}}' "$file")

    if [[ -n "$insert_line" ]]; then
      # macOS/BSD sed compatibility
      if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "${insert_line}i\\
\\
<!-- Use centralized environment detection: ~/.claude/scripts/detect-environment.sh -->\\
<!-- Available: environment, git-platform, task-backend, secrets-backend, etc. -->" "$file"
      else
        sed -i "${insert_line}i\\
\\
<!-- Use centralized environment detection: ~/.claude/scripts/detect-environment.sh -->\\
<!-- Available: environment, git-platform, task-backend, secrets-backend, etc. -->" "$file"
      fi

      print_info "Added usage comment to $(basename "$file")"
      return 0
    fi
  fi
  return 1
}

# Main update function
update_command() {
  local file="$1"
  local updated=false

  if update_uname_pattern "$file"; then
    updated=true
  fi

  if update_inline_uname "$file"; then
    updated=true
  fi

  if [[ "$updated" == true ]]; then
    echo "  → $(basename "$file")"
  fi
}

# Process all commands
main() {
  print_info "Updating commands to use detect-environment.sh"
  echo ""

  local count=0

  # Update commands with uname -s
  echo "Phase 1: Updating uname -s patterns..."
  for file in "${COMMANDS_DIR}"/*.md; do
    if update_command "$file"; then
      ((count++))
    fi
  done

  echo ""
  print_success "Updated $count command files"
  echo ""
  print_info "Next: Manually update PROJECT.yaml parsing patterns"
}

main "$@"
