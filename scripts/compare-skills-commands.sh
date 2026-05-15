#!/usr/bin/env bash
# Compare Skills vs Commands
# Identifies identical content, differences, and orphaned files

set -euo pipefail

SKILLS_DIR="${HOME}/.claude/skills"
COMMANDS_DIR="${HOME}/.claude/commands"
OUTPUT_FILE="${HOME}/.claude/skills-commands-comparison.md"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
  echo -e "${BLUE}=== $1 ===${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}"
}

# Function to extract content from YAML skill (removing YAML frontmatter)
extract_skill_content() {
  local file="$1"
  # Skip name, description, user_invocable lines and prompt: line, extract content after
  awk '/^prompt: \|$/,0' "$file" | tail -n +2
}

# Function to extract content from Markdown command (removing frontmatter)
extract_command_content() {
  local file="$1"
  # Skip YAML frontmatter between --- markers
  awk '/^---$/,/^---$/ {next} {print}' "$file"
}

# Function to normalize whitespace for comparison
normalize_content() {
  # Remove leading/trailing whitespace, normalize multiple spaces
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g' | grep -v '^$'
}

# Function to compare two files
compare_files() {
  local skill_file="$1"
  local command_file="$2"

  local skill_content
  local command_content

  skill_content=$(extract_skill_content "$skill_file" | normalize_content)
  command_content=$(extract_command_content "$command_file" | normalize_content)

  if [[ "$skill_content" == "$command_content" ]]; then
    echo "identical"
  else
    # Calculate similarity percentage (rough estimate)
    local skill_lines
    local command_lines
    local common_lines

    skill_lines=$(echo "$skill_content" | wc -l)
    command_lines=$(echo "$command_content" | wc -l)
    common_lines=$(comm -12 <(echo "$skill_content" | sort) <(echo "$command_content" | sort) | wc -l)

    if [[ $skill_lines -eq 0 ]]; then
      echo "different:0"
    else
      local similarity=$((common_lines * 100 / skill_lines))
      echo "different:$similarity"
    fi
  fi
}

# Function to find matching command for a skill
find_matching_command() {
  local skill_name="$1"

  # Direct match
  if [[ -f "${COMMANDS_DIR}/${skill_name}.md" ]]; then
    echo "${skill_name}.md"
    return
  fi

  # Common variations
  local variations=(
    "${skill_name//_/-}.md"
    "${skill_name//-/_}.md"
  )

  for var in "${variations[@]}"; do
    if [[ -f "${COMMANDS_DIR}/${var}" ]]; then
      echo "$var"
      return
    fi
  done

  echo ""
}

# Initialize output file
cat > "$OUTPUT_FILE" <<'EOF'
# Skills vs Commands Comprehensive Comparison

Generated: $(date +"%Y-%m-%d %H:%M:%S")

## Summary

This report compares all skill files against command files to identify:
- Identical content (safe to delete skill)
- Similar content with differences (needs review)
- Skills without matching commands (needs command creation)
- Commands without matching skills (command-only implementations)

---

EOF

# Arrays to track results
declare -a IDENTICAL_MATCHES=()
declare -a DIFFERENT_MATCHES=()
declare -a SKILLS_WITHOUT_COMMANDS=()
declare -a COMMANDS_WITHOUT_SKILLS=()

print_header "Comparing Skills vs Commands"

# Process each skill
while IFS= read -r skill_file; do
  skill_basename=$(basename "$skill_file")
  skill_name="${skill_basename%.*}"

  # Find matching command
  matching_command=$(find_matching_command "$skill_name")

  if [[ -n "$matching_command" ]]; then
    command_file="${COMMANDS_DIR}/${matching_command}"

    # Compare content
    result=$(compare_files "$skill_file" "$command_file")

    if [[ "$result" == "identical" ]]; then
      print_success "IDENTICAL: ${skill_name} ↔ ${matching_command}"
      IDENTICAL_MATCHES+=("${skill_name}|${matching_command}")
    else
      similarity="${result#*:}"
      print_warning "DIFFERENT: ${skill_name} ↔ ${matching_command} (${similarity}% similar)"
      DIFFERENT_MATCHES+=("${skill_name}|${matching_command}|${similarity}")
    fi
  else
    print_error "NO COMMAND: ${skill_name}"
    SKILLS_WITHOUT_COMMANDS+=("${skill_name}")
  fi
done < <(find "$SKILLS_DIR" -name "*.yaml" -o -name "*.md" | sort)

echo ""
print_header "Finding Commands Without Skills"

# Process each command to find orphans
while IFS= read -r command_file; do
  command_basename=$(basename "$command_file")
  command_name="${command_basename%.*}"

  # Check if skill exists
  skill_exists=false
  for match in "${IDENTICAL_MATCHES[@]}" "${DIFFERENT_MATCHES[@]}"; do
    if [[ "$match" == *"|${command_basename}" ]]; then
      skill_exists=true
      break
    fi
  done

  if [[ "$skill_exists" == false ]]; then
    # Also check if skill name matches
    if [[ ! -f "${SKILLS_DIR}/${command_name}.yaml" ]] && [[ ! -f "${SKILLS_DIR}/${command_name}.md" ]]; then
      COMMANDS_WITHOUT_SKILLS+=("${command_name}")
    fi
  fi
done < <(find "$COMMANDS_DIR" -name "*.md" | sort)

# Write detailed results to file
{
  echo "## Statistics"
  echo ""
  echo "- **Total Skills:** $(find "$SKILLS_DIR" -name "*.yaml" -o -name "*.md" | wc -l)"
  echo "- **Total Commands:** $(find "$COMMANDS_DIR" -name "*.md" | wc -l)"
  echo "- **Identical Matches:** ${#IDENTICAL_MATCHES[@]}"
  echo "- **Different Matches:** ${#DIFFERENT_MATCHES[@]}"
  echo "- **Skills Without Commands:** ${#SKILLS_WITHOUT_COMMANDS[@]}"
  echo "- **Commands Without Skills:** ${#COMMANDS_WITHOUT_SKILLS[@]}"
  echo ""
  echo "---"
  echo ""

  # Identical matches
  echo "## ✅ Identical Matches (${#IDENTICAL_MATCHES[@]})"
  echo ""
  echo "These skills have identical content to their commands. **SAFE TO DELETE SKILL.**"
  echo ""
  echo "| Skill | Command | Action |"
  echo "|-------|---------|--------|"

  for match in "${IDENTICAL_MATCHES[@]}"; do
    IFS='|' read -r skill command <<< "$match"
    echo "| ${skill} | ${command} | ✅ Delete skill |"
  done

  echo ""
  echo "---"
  echo ""

  # Different matches
  echo "## ⚠️  Different Matches (${#DIFFERENT_MATCHES[@]})"
  echo ""
  echo "These skills have matching commands but with content differences. **NEEDS REVIEW.**"
  echo ""
  echo "| Skill | Command | Similarity | Action |"
  echo "|-------|---------|------------|--------|"

  for match in "${DIFFERENT_MATCHES[@]}"; do
    IFS='|' read -r skill command similarity <<< "$match"
    echo "| ${skill} | ${command} | ${similarity}% | 🔍 Review differences |"
  done

  echo ""
  echo "---"
  echo ""

  # Skills without commands
  echo "## 🆕 Skills Without Commands (${#SKILLS_WITHOUT_COMMANDS[@]})"
  echo ""
  echo "These skills do not have matching commands. **NEEDS COMMAND CREATION.**"
  echo ""
  echo "| Skill | Suggested Command | Priority |"
  echo "|-------|-------------------|----------|"

  for skill in "${SKILLS_WITHOUT_COMMANDS[@]}"; do
    # Determine priority based on name
    priority="Medium"
    if [[ "$skill" =~ (test|deploy|infra|pipeline) ]]; then
      priority="High"
    elif [[ "$skill" =~ (rca|incident|security) ]]; then
      priority="Medium"
    else
      priority="Low"
    fi

    echo "| ${skill} | /${skill} | ${priority} |"
  done

  echo ""
  echo "---"
  echo ""

  # Commands without skills
  echo "## 📋 Commands Without Skills (${#COMMANDS_WITHOUT_SKILLS[@]})"
  echo ""
  echo "These commands exist without matching skills. **COMMAND-ONLY IMPLEMENTATIONS.**"
  echo ""
  echo "| Command | Notes |"
  echo "|---------|-------|"

  for command in "${COMMANDS_WITHOUT_SKILLS[@]}"; do
    echo "| ${command} | Command-only |"
  done

  echo ""
  echo "---"
  echo ""

  # Recommendations
  echo "## 🎯 Recommendations"
  echo ""
  echo "### Immediate Actions"
  echo ""
  echo "1. **Delete ${#IDENTICAL_MATCHES[@]} identical skills**"
  echo "   - Content is identical to commands"
  echo "   - Commands are canonical"
  echo "   - No risk of data loss"
  echo ""
  echo "2. **Review ${#DIFFERENT_MATCHES[@]} different matches**"
  echo "   - Compare content manually"
  echo "   - Port improvements to commands"
  echo "   - Then delete skills"
  echo ""
  echo "3. **Create commands for ${#SKILLS_WITHOUT_COMMANDS[@]} orphaned skills**"
  echo "   - Focus on high priority first"
  echo "   - Then delete skills after command creation"
  echo ""
  echo "### Next Steps"
  echo ""
  echo "1. Review this comparison report"
  echo "2. Examine different matches for improvements"
  echo "3. Delete identical skills"
  echo "4. Update commands to use detect-environment.sh"
  echo "5. Create missing commands (if needed)"
  echo ""

} >> "$OUTPUT_FILE"

# Print summary
echo ""
print_header "Comparison Complete"
echo ""
echo "Results written to: ${OUTPUT_FILE}"
echo ""
echo "Summary:"
echo "  ✅ Identical matches: ${#IDENTICAL_MATCHES[@]}"
echo "  ⚠️  Different matches: ${#DIFFERENT_MATCHES[@]}"
echo "  🆕 Skills without commands: ${#SKILLS_WITHOUT_COMMANDS[@]}"
echo "  📋 Commands without skills: ${#COMMANDS_WITHOUT_SKILLS[@]}"
echo ""
