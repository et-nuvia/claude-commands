#!/usr/bin/env bash
# Generate comprehensive skills-reference.md from command files
# Usage: ./scripts/generate-skills-reference.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(dirname "$SCRIPT_DIR")"
COMMANDS_DIR="${CLAUDE_DIR}/commands"
OUTPUT_FILE="${CLAUDE_DIR}/docs/skills-reference.md"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Generating Skills Reference from command files...${NC}"

# Check commands directory exists
if [[ ! -d "$COMMANDS_DIR" ]]; then
    echo -e "${RED}ERROR: Commands directory not found: $COMMANDS_DIR${NC}"
    exit 1
fi

# Count commands
TOTAL_COMMANDS=$(find "$COMMANDS_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
echo -e "${GREEN}Found $TOTAL_COMMANDS command files${NC}"

# Extract command info
declare -A commands
declare -A descriptions

while IFS= read -r cmd_file; do
    cmd_name=$(basename "$cmd_file" .md)

    # Try to get description from YAML frontmatter
    description=$(grep "^description:" "$cmd_file" | head -1 | sed 's/description: //' | sed 's/"//g' | sed "s/'//g" || echo "")

    # If no description in frontmatter, try first heading
    if [[ -z "$description" ]]; then
        description=$(grep "^# " "$cmd_file" | head -1 | sed 's/^# //' || echo "")
    fi

    # If still no description, use command name
    if [[ -z "$description" ]]; then
        description="$cmd_name"
    fi

    commands["$cmd_name"]="$cmd_file"
    descriptions["$cmd_name"]="$description"
done < <(find "$COMMANDS_DIR" -name "*.md" -type f | sort)

# Categorize commands
declare -A categories
categories=(
    ["task"]="Task Management"
    ["project"]="Project Setup & Configuration"
    ["test"]="Testing"
    ["git"]="Git Operations"
    ["deploy"]="Deployment"
    ["pipeline"]="CI/CD & Pipelines"
    ["infra"]="Infrastructure (Terraform)"
    ["db"]="Database Operations"
    ["security"]="Security"
    ["ops"]="Operations & Monitoring"
    ["rca"]="Incident Response (RCA)"
    ["docs"]="Documentation"
    ["docker"]="Docker & Containers"
    ["plan"]="Planning & Analysis"
    ["session"]="Session Management"
    ["review"]="Code Review"
    ["implement"]="Implementation"
    ["refactor"]="Code Quality"
    ["format"]="Formatting"
    ["fix"]="Code Fixes"
    ["find"]="Code Search"
    ["remove"]="Code Cleanup"
    ["add"]="Dependencies & Secrets"
    ["upgrade"]="Upgrades & Updates"
    ["rotate"]="Secret Rotation"
    ["training"]="Special Purpose"
    ["scaffold"]="Scaffolding"
    ["cleanproject"]="Project Cleanup"
    ["understand"]="Project Understanding"
    ["explain"]="Code Explanation"
    ["predict"]="Code Analysis"
    ["makefile"]="Build Automation"
    ["dockerfile"]="Docker Development"
    ["undo"]="Utility"
    ["execute"]="Execution"
    ["create"]="Creation"
    ["generate"]="Generation"
    ["contributing"]="Contribution"
    ["document"]="Documentation"
    ["release"]="Release Management"
    ["todos"]="TODO Management"
)

# Start generating markdown
cat > "$OUTPUT_FILE" << 'HEADER'
# Skills Reference Guide

Quick reference for all Claude Code skills organized by workflow phase.

**Auto-generated** from command files - DO NOT EDIT MANUALLY
**Generated**: TIMESTAMP
**Total Skills**: SKILL_COUNT

---

## Quick Navigation

- [Task Management](#task-management)
- [Project Setup](#project-setup--configuration)
- [Development](#development)
- [Testing](#testing)
- [Code Quality](#code-quality)
- [Git Operations](#git-operations)
- [Deployment](#deployment)
- [Infrastructure](#infrastructure-terraform)
- [Database](#database-operations)
- [Security](#security)
- [Operations](#operations--monitoring)
- [Documentation](#documentation)
- [Special Purpose](#special-purpose)

---

HEADER

# Update timestamp and count
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
sed -i.bak "s/TIMESTAMP/$TIMESTAMP/" "$OUTPUT_FILE"
sed -i.bak "s/SKILL_COUNT/$TOTAL_COMMANDS/" "$OUTPUT_FILE"
rm "${OUTPUT_FILE}.bak"

# Group commands by category
declare -A grouped_commands

for cmd_name in "${!commands[@]}"; do
    # Determine category based on command name prefix
    category="Other"

    if [[ "$cmd_name" =~ ^task- ]]; then
        category="Task Management"
    elif [[ "$cmd_name" =~ ^project- ]]; then
        category="Project Setup & Configuration"
    elif [[ "$cmd_name" =~ ^test- || "$cmd_name" =~ ^smoke- || "$cmd_name" == "test" ]]; then
        category="Testing"
    elif [[ "$cmd_name" =~ ^git- ]]; then
        category="Git Operations"
    elif [[ "$cmd_name" =~ ^deploy- ]]; then
        category="Deployment"
    elif [[ "$cmd_name" =~ ^pipeline- ]]; then
        category="CI/CD & Pipelines"
    elif [[ "$cmd_name" =~ ^infra- ]]; then
        category="Infrastructure (Terraform)"
    elif [[ "$cmd_name" =~ ^db- ]]; then
        category="Database Operations"
    elif [[ "$cmd_name" =~ ^security- ]]; then
        category="Security"
    elif [[ "$cmd_name" =~ ^ops- ]]; then
        category="Operations & Monitoring"
    elif [[ "$cmd_name" =~ ^rca- ]]; then
        category="Incident Response (RCA)"
    elif [[ "$cmd_name" =~ ^docs || "$cmd_name" == "document-api" || "$cmd_name" == "contributing" ]]; then
        category="Documentation"
    elif [[ "$cmd_name" =~ ^docker- || "$cmd_name" == "dockerfile-build" ]]; then
        category="Docker & Containers"
    elif [[ "$cmd_name" =~ ^plan- ]]; then
        category="Planning & Analysis"
    elif [[ "$cmd_name" =~ ^session- ]]; then
        category="Session Management"
    elif [[ "$cmd_name" =~ review ]]; then
        category="Code Review"
    elif [[ "$cmd_name" =~ implement ]]; then
        category="Implementation"
    elif [[ "$cmd_name" =~ refactor ]]; then
        category="Code Quality"
    elif [[ "$cmd_name" == "format" || "$cmd_name" == "make-it-pretty" ]]; then
        category="Formatting"
    elif [[ "$cmd_name" =~ ^fix- ]]; then
        category="Code Fixes"
    elif [[ "$cmd_name" =~ ^find- ]]; then
        category="Code Search"
    elif [[ "$cmd_name" =~ remove ]]; then
        category="Code Cleanup"
    elif [[ "$cmd_name" =~ add- ]]; then
        category="Dependencies & Secrets"
    elif [[ "$cmd_name" =~ upgrade ]]; then
        category="Upgrades & Updates"
    elif [[ "$cmd_name" =~ rotate ]]; then
        category="Secret Rotation"
    elif [[ "$cmd_name" == "training-videos" ]]; then
        category="Special Purpose"
    elif [[ "$cmd_name" == "scaffold" ]]; then
        category="Scaffolding"
    elif [[ "$cmd_name" == "cleanproject" ]]; then
        category="Project Cleanup"
    elif [[ "$cmd_name" == "understand" ]]; then
        category="Project Understanding"
    elif [[ "$cmd_name" =~ explain ]]; then
        category="Code Explanation"
    elif [[ "$cmd_name" =~ predict ]]; then
        category="Code Analysis"
    elif [[ "$cmd_name" =~ makefile ]]; then
        category="Build Automation"
    elif [[ "$cmd_name" == "undo" ]]; then
        category="Utility"
    elif [[ "$cmd_name" == "execute-tasks" ]]; then
        category="Execution"
    elif [[ "$cmd_name" == "create-pr" ]]; then
        category="Git Operations"
    elif [[ "$cmd_name" == "generate-changelog" ]]; then
        category="Git Operations"
    elif [[ "$cmd_name" == "release" ]]; then
        category="Release Management"
    elif [[ "$cmd_name" =~ todos ]]; then
        category="TODO Management"
    fi

    if [[ -z "${grouped_commands[$category]:-}" ]]; then
        grouped_commands[$category]="$cmd_name"
    else
        grouped_commands[$category]+=" $cmd_name"
    fi
done

# Output categories in order
declare -a category_order=(
    "Task Management"
    "Project Setup & Configuration"
    "Planning & Analysis"
    "Implementation"
    "Code Quality"
    "Code Fixes"
    "Code Search"
    "Code Cleanup"
    "Code Review"
    "Code Explanation"
    "Code Analysis"
    "Formatting"
    "Testing"
    "Git Operations"
    "Release Management"
    "Deployment"
    "CI/CD & Pipelines"
    "Infrastructure (Terraform)"
    "Database Operations"
    "Security"
    "Operations & Monitoring"
    "Incident Response (RCA)"
    "Docker & Containers"
    "Build Automation"
    "Documentation"
    "Dependencies & Secrets"
    "Secret Rotation"
    "Upgrades & Updates"
    "TODO Management"
    "Scaffolding"
    "Project Cleanup"
    "Project Understanding"
    "Session Management"
    "Execution"
    "Utility"
    "Special Purpose"
    "Other"
)

for category in "${category_order[@]}"; do
    if [[ -n "${grouped_commands[$category]:-}" ]]; then
        echo "" >> "$OUTPUT_FILE"
        echo "## $category" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"

        # Sort commands in this category
        for cmd_name in $(echo "${grouped_commands[$category]}" | tr ' ' '\n' | sort); do
            description="${descriptions[$cmd_name]}"
            echo "### \`/$cmd_name\`" >> "$OUTPUT_FILE"
            echo "$description" >> "$OUTPUT_FILE"
            echo "" >> "$OUTPUT_FILE"
        done
    fi
done

# Add footer
cat >> "$OUTPUT_FILE" << 'FOOTER'

---

## See Also

- [Task Management](reference/task-management.md) - Task management system details
- [Version Management](reference/version-management.md) - Semantic versioning
- [Deployment Scripts](reference/deployment-scripts.md) - Deployment automation
- [Testing Guide](reference/testing-smoke.md) - Smoke testing patterns
- [Monitoring Guide](reference/monitoring.md) - Application monitoring

---

## Regenerating This File

This file is auto-generated from command files. To regenerate:

```bash
~/.claude/scripts/generate-skills-reference.sh
```

**DO NOT EDIT MANUALLY** - Changes will be overwritten!
FOOTER

echo -e "${GREEN}✓ Generated: $OUTPUT_FILE${NC}"
echo -e "${BLUE}  Total commands: $TOTAL_COMMANDS${NC}"
echo -e "${BLUE}  Categories: ${#category_order[@]}${NC}"
