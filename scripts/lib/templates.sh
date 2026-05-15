#!/usr/bin/env bash
# Template Rendering Library
# Handles template variable substitution and conditional blocks
#
# Usage: source ~/.claude/scripts/lib/templates.sh

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Source common library for utilities
# Use local variable to avoid overwriting caller's SCRIPT_DIR
# Handle both bash and zsh
if [[ -n "${BASH_SOURCE:-}" ]]; then
  _TEMPLATES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  _TEMPLATES_LIB_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
  _TEMPLATES_LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

source "${_TEMPLATES_LIB_DIR}/common.sh"

# =============================================================================
# Configuration
# =============================================================================

# Global templates directory
GLOBAL_TEMPLATES_DIR="${HOME}/.claude/templates"

# Project templates directory (override location)
PROJECT_TEMPLATES_DIR=".claude/templates"

# =============================================================================
# Template Discovery
# =============================================================================

# Find a template by category and name
# Checks project templates first, then global templates
# Usage: template_path=$(find_template "dockerfiles" "python-nix.dockerfile")
# Returns: Full path to template file, or empty string if not found
find_template() {
  local category="$1"
  local name="$2"
  local project_path="${PROJECT_TEMPLATES_DIR}/${category}/${name}"
  local global_path="${GLOBAL_TEMPLATES_DIR}/${category}/${name}"

  # Check project override first
  if [[ -f "$project_path" ]]; then
    print_debug "Found template in project: $project_path"
    echo "$project_path"
    return 0
  fi

  # Check global templates
  if [[ -f "$global_path" ]]; then
    print_debug "Found template in global: $global_path"
    echo "$global_path"
    return 0
  fi

  # Not found
  print_debug "Template not found: ${category}/${name}"
  return 1
}

# List all templates in a category
# Usage: templates=$(list_templates "dockerfiles")
# Returns: List of template names (one per line)
list_templates() {
  local category="$1"
  local templates=()

  # List global templates
  if [[ -d "${GLOBAL_TEMPLATES_DIR}/${category}" ]]; then
    while IFS= read -r -d '' file; do
      templates+=("$(basename "$file")")
    done < <(find "${GLOBAL_TEMPLATES_DIR}/${category}" -type f -print0 2>/dev/null)
  fi

  # List project templates (these override globals with same name)
  if [[ -d "${PROJECT_TEMPLATES_DIR}/${category}" ]]; then
    while IFS= read -r -d '' file; do
      local name
      name="$(basename "$file")"
      # Only add if not already in list (project overrides global)
      if [[ ! " ${templates[*]} " =~ " ${name} " ]]; then
        templates+=("$name")
      fi
    done < <(find "${PROJECT_TEMPLATES_DIR}/${category}" -type f -print0 2>/dev/null)
  fi

  # Output sorted list
  printf '%s\n' "${templates[@]}" | sort
}

# =============================================================================
# Variable Extraction and Validation
# =============================================================================

# Extract all variable references from a template
# Usage: vars=$(extract_template_vars "/path/to/template")
# Returns: List of variable names (one per line), sorted and unique
extract_template_vars() {
  local template_file="$1"

  if [[ ! -f "$template_file" ]]; then
    print_error "Template file not found: $template_file"
    return 1
  fi

  # Extract ${VAR} patterns, excluding:
  # - ${{ }} (GitHub Actions syntax)
  # - ${CI_*} (GitLab CI variables - should be preserved)
  # - ${!var} (indirect variable expansion)
  grep -oP '\$\{[A-Z_][A-Z0-9_]*\}' "$template_file" 2>/dev/null | \
    sed 's/\${\([^}]*\)}/\1/' | \
    grep -v '^CI_' | \
    sort -u || true
}

# Validate that all required variables are set
# Usage: validate_template_vars "/path/to/template" || exit 1
# Returns: 0 if all variables set, 1 if any missing
validate_template_vars() {
  local template_file="$1"
  local vars
  local missing=()

  vars=$(extract_template_vars "$template_file")

  while IFS= read -r var; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done <<< "$vars"

  if [[ ${#missing[@]} -gt 0 ]]; then
    print_error "Missing required template variables:"
    for var in "${missing[@]}"; do
      echo "  - $var" >&2
    done
    return 1
  fi

  return 0
}

# =============================================================================
# Conditional Block Processing
# =============================================================================

# Process conditional blocks in template
# Syntax: #IF:VARIABLE_NAME ... #ENDIF:VARIABLE_NAME
# Usage: processed=$(process_conditionals "$content")
# Returns: Template with conditionals evaluated
process_conditionals() {
  local content="$1"
  local result=""
  local in_conditional=false
  local conditional_var=""
  local conditional_active=false

  while IFS= read -r line; do
    # Check for #IF: directive (shell-agnostic approach)
    if [[ "$line" == "#IF:"* ]]; then
      conditional_var="${line#\#IF:}"
      conditional_var="${conditional_var%% *}"  # Remove any trailing content
      in_conditional=true

      # Check if variable is set and non-empty (shell-agnostic)
      local var_value
      eval "var_value=\"\${${conditional_var}:-}\""
      if [[ -n "$var_value" ]]; then
        conditional_active=true
      else
        conditional_active=false
      fi
      continue
    fi

    # Check for #ENDIF: directive
    if [[ "$line" == "#ENDIF:"* ]]; then
      in_conditional=false
      conditional_active=false
      conditional_var=""
      continue
    fi

    # Include line if not in conditional, or if conditional is active
    if [[ "$in_conditional" == "false" ]] || [[ "$conditional_active" == "true" ]]; then
      result+="$line"$'\n'
    fi
  done <<< "$content"

  echo -n "$result"
}

# =============================================================================
# Variable Substitution
# =============================================================================

# Substitute variables using envsubst (preferred) or sed (fallback)
# Usage: substituted=$(substitute_vars "$content")
# Returns: Content with variables substituted
substitute_vars() {
  local content="$1"

  # Get list of variables to substitute (exclude CI_* and GitHub Actions syntax)
  local var_list=""
  while IFS= read -r var; do
    if [[ -n "$var" ]] && [[ ! "$var" =~ ^CI_ ]]; then
      var_list+="\${$var} "
    fi
  done < <(echo "$content" | grep -oP '\$\{[A-Z_][A-Z0-9_]*\}' | sed 's/\${\([^}]*\)}/\1/' | sort -u)

  # Try envsubst if available
  if check_dependency "envsubst"; then
    # Use explicit variable list to preserve CI_* and ${{ }} patterns
    if [[ -n "$var_list" ]]; then
      echo "$content" | envsubst "$var_list"
    else
      echo "$content"
    fi
  else
    # Fallback to sed
    print_debug "envsubst not available, using sed fallback"
    local result="$content"

    while IFS= read -r var; do
      if [[ -n "$var" ]] && [[ ! "$var" =~ ^CI_ ]]; then
        local value="${!var:-}"
        # Escape special characters in value for sed
        value=$(echo "$value" | sed 's/[&/\]/\\&/g')
        result=$(echo "$result" | sed "s/\\\${$var}/$value/g")
      fi
    done < <(echo "$content" | grep -oP '\$\{[A-Z_][A-Z0-9_]*\}' | sed 's/\${\([^}]*\)}/\1/' | sort -u)

    echo "$result"
  fi
}

# =============================================================================
# Template Rendering
# =============================================================================

# Render a template to a file
# Usage: render_template "/path/to/template" "/path/to/output"
# Returns: 0 on success, 1 on error
render_template() {
  local template_file="$1"
  local output_file="$2"

  if [[ ! -f "$template_file" ]]; then
    print_error "Template file not found: $template_file"
    return 1
  fi

  # Read template content
  local content
  content=$(<"$template_file")

  # Process conditional blocks
  content=$(process_conditionals "$content")

  # Substitute variables
  content=$(substitute_vars "$content")

  # Write to output file
  echo "$content" > "$output_file"

  print_debug "Rendered template: $template_file -> $output_file"
  return 0
}

# Render a template to stdout
# Usage: output=$(render_template_stdout "/path/to/template")
# Returns: Rendered content on stdout
render_template_stdout() {
  local template_file="$1"

  if [[ ! -f "$template_file" ]]; then
    print_error "Template file not found: $template_file"
    return 1
  fi

  # Read template content
  local content
  content=$(<"$template_file")

  # Process conditional blocks
  content=$(process_conditionals "$content")

  # Substitute variables
  content=$(substitute_vars "$content")

  # Output to stdout
  echo "$content"
}

# Render a template with automatic template discovery
# Usage: render_template_by_name "dockerfiles" "python-nix.dockerfile" "/path/to/output"
# Returns: 0 on success, 1 on error
render_template_by_name() {
  local category="$1"
  local name="$2"
  local output_file="$3"

  local template_path
  template_path=$(find_template "$category" "$name") || {
    print_error "Template not found: ${category}/${name}"
    return 1
  }

  render_template "$template_path" "$output_file"
}

# =============================================================================
# Validation
# =============================================================================

# Validate a template file
# Checks:
# - File exists
# - All referenced variables are set
# - Conditional block syntax is valid
# Usage: validate_template "/path/to/template" || exit 1
# Returns: 0 if valid, 1 if invalid
validate_template() {
  local template_file="$1"

  if [[ ! -f "$template_file" ]]; then
    print_error "Template file not found: $template_file"
    return 1
  fi

  # Check conditional block pairing
  local if_count
  local endif_count
  if_count=$(grep -c "^#IF:" "$template_file" || true)
  endif_count=$(grep -c "^#ENDIF:" "$template_file" || true)

  if [[ $if_count -ne $endif_count ]]; then
    print_error "Mismatched #IF/#ENDIF blocks in template"
    print_error "  #IF: $if_count, #ENDIF: $endif_count"
    return 1
  fi

  # Validate variable references (optional - doesn't fail on missing vars)
  local vars
  vars=$(extract_template_vars "$template_file")
  local missing_count=0

  while IFS= read -r var; do
    if [[ -z "${!var:-}" ]]; then
      ((missing_count++))
      print_debug "Variable not set: $var"
    fi
  done <<< "$vars"

  if [[ $missing_count -gt 0 ]]; then
    print_warning "Template has $missing_count unset variables (use validate_template_vars to enforce)"
  fi

  return 0
}

# =============================================================================
# Initialization
# =============================================================================

print_debug "templates.sh library loaded"

# Export functions for use in subshells (bash only)
if [[ -z "${ZSH_VERSION:-}" ]]; then
  export -f find_template list_templates extract_template_vars validate_template_vars 2>/dev/null || true
  export -f process_conditionals substitute_vars 2>/dev/null || true
  export -f render_template render_template_stdout render_template_by_name 2>/dev/null || true
  export -f validate_template 2>/dev/null || true
fi
