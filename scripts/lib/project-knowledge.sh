#!/usr/bin/env bash
# project-knowledge.sh - Load and query PROJECT-KNOWLEDGE.md
#
# Provides: pk_exists(), pk_load_full(), pk_load_section(), pk_load_subsection()
#
# Usage: source "${SCRIPT_DIR}/lib/project-knowledge.sh"

# Guard against double-sourcing
[[ -n "${_PROJECT_KNOWLEDGE_LOADED:-}" ]] && return 0
_PROJECT_KNOWLEDGE_LOADED=1

# Default location
_PK_FILE="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/docs/architecture/PROJECT-KNOWLEDGE.md"

# Check if PROJECT-KNOWLEDGE.md exists
# Usage: if pk_exists; then ...
pk_exists() {
    [[ -f "$_PK_FILE" ]]
}

# Load entire PROJECT-KNOWLEDGE.md content
# Usage: content=$(pk_load_full)
pk_load_full() {
    if ! pk_exists; then
        return 1
    fi
    cat "$_PK_FILE"
}

# Extract content under an H2 header (## Section Name)
# Returns everything from the H2 line until the next H2 or EOF
# Usage: content=$(pk_load_section "Domain Overview")
pk_load_section() {
    local section="$1"

    if ! pk_exists; then
        return 1
    fi

    sed -n "/^## ${section}$/,/^## /{ /^## ${section}$/d; /^## /d; p; }" "$_PK_FILE"
}

# Extract content under an H3 header within a specific H2 section
# Usage: content=$(pk_load_subsection "Core Workflows" "Patient Intake")
pk_load_subsection() {
    local section="$1"
    local subsection="$2"

    if ! pk_exists; then
        return 1
    fi

    # First extract the H2 section, then extract the H3 within it
    local section_content
    section_content=$(pk_load_section "$section")

    if [[ -z "$section_content" ]]; then
        return 1
    fi

    echo "$section_content" | sed -n "/^### ${subsection}$/,/^### /{ /^### ${subsection}$/d; /^### /d; p; }"
}

# Override the default PK file path
# Usage: pk_set_path "/path/to/PROJECT-KNOWLEDGE.md"
pk_set_path() {
    _PK_FILE="$1"
}
