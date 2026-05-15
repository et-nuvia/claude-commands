#!/usr/bin/env bash
# Common Utilities Library
# Shared functions for all generator and detection scripts
#
# Usage: source ~/.claude/scripts/lib/common.sh

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# =============================================================================
# Color Codes
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# =============================================================================
# Print Functions
# All output goes to stderr to avoid polluting stdout (for scriptable use)
# =============================================================================

# Print error message in red with ✗ symbol
# Usage: print_error "Error message"
print_error() {
  echo -e "${RED}✗ $1${NC}" >&2
}

# Print success message in green with ✓ symbol
# Usage: print_success "Success message"
print_success() {
  echo -e "${GREEN}✓ $1${NC}" >&2
}

# Print warning message in yellow with ⚠ symbol
# Usage: print_warning "Warning message"
print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}" >&2
}

# Print info message in blue with ℹ symbol
# Usage: print_info "Info message"
print_info() {
  echo -e "${BLUE}ℹ $1${NC}" >&2
}

# Print debug message in cyan (only if DEBUG=1)
# Usage: print_debug "Debug message"
print_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo -e "${CYAN}[DEBUG] $1${NC}" >&2
  fi
}

# =============================================================================
# Dependency Checking
# =============================================================================

# Check if a command exists
# Usage: check_dependency "command_name" || install_instructions
# Returns: 0 if exists, 1 if not
check_dependency() {
  local cmd="$1"
  command -v "$cmd" &>/dev/null
}

# Require a command to exist, exit with error if not found
# Usage: require_command "yq" "Install with: brew install yq"
require_command() {
  local cmd="$1"
  local install_msg="${2:-Install $cmd first}"

  if ! check_dependency "$cmd"; then
    print_error "Required command not found: $cmd"
    print_info "$install_msg"
    exit 1
  fi
}

# Check for optional command and warn if not found
# Usage: check_optional "yq" "Some features require yq"
check_optional() {
  local cmd="$1"
  local msg="${2:-Optional: $cmd not found}"

  if ! check_dependency "$cmd"; then
    print_warning "$msg"
    return 1
  fi
  return 0
}

# =============================================================================
# File Operations
# =============================================================================

# Create directory if it doesn't exist
# Usage: ensure_directory "/path/to/dir"
ensure_directory() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    print_debug "Creating directory: $dir"
    mkdir -p "$dir" || {
      print_error "Failed to create directory: $dir"
      return 1
    }
  fi
}

# Prompt user before overwriting a file
# Usage: confirm_overwrite "/path/to/file" || return
# Returns: 0 if should overwrite, 1 if should skip
confirm_overwrite() {
  local file="$1"
  local force="${FORCE:-false}"

  if [[ ! -f "$file" ]]; then
    return 0  # File doesn't exist, safe to write
  fi

  if [[ "$force" == "true" ]]; then
    return 0  # Force flag set, overwrite
  fi

  print_warning "File already exists: $file"
  read -p "Overwrite? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    return 0  # User confirmed overwrite
  else
    print_info "Skipping: $file"
    return 1  # User declined
  fi
}

# Check if file is writable or can be created
# Usage: check_writable "/path/to/file" || exit 1
check_writable() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"

  if [[ -f "$file" ]]; then
    # File exists, check if writable
    [[ -w "$file" ]] || {
      print_error "File is not writable: $file"
      return 1
    }
  else
    # File doesn't exist, check if directory is writable
    [[ -w "$dir" ]] || {
      print_error "Directory is not writable: $dir"
      return 1
    }
  fi
  return 0
}

# =============================================================================
# User Interaction
# =============================================================================

# Ask yes/no question with default
# Usage: ask_yes_no "Continue?" "y" && do_something
# Returns: 0 for yes, 1 for no
ask_yes_no() {
  local question="$1"
  local default="${2:-n}"  # Default to "no"
  local prompt

  if [[ "$default" == "y" ]]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi

  read -p "$question $prompt: " -n 1 -r
  echo

  # If empty answer, use default
  if [[ -z "$REPLY" ]]; then
    [[ "$default" == "y" ]] && return 0 || return 1
  fi

  # Check user answer
  [[ $REPLY =~ ^[Yy]$ ]] && return 0 || return 1
}

# Prompt for input with default value
# Usage: result=$(prompt_with_default "Enter name" "default-name")
prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local result

  read -p "$prompt [$default]: " -r result
  echo "${result:-$default}"
}

# =============================================================================
# Validation
# =============================================================================

# Check if variable is set and not empty
# Usage: require_var "VAR_NAME" || exit 1
require_var() {
  local var_name="$1"
  local var_value="${!var_name:-}"

  if [[ -z "$var_value" ]]; then
    print_error "Required variable not set: $var_name"
    return 1
  fi
  return 0
}

# Validate that a file exists
# Usage: require_file "/path/to/file" || exit 1
require_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    print_error "Required file not found: $file"
    return 1
  fi
  return 0
}

# Validate that a directory exists
# Usage: require_directory "/path/to/dir" || exit 1
require_directory() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    print_error "Required directory not found: $dir"
    return 1
  fi
  return 0
}

# =============================================================================
# Utility Functions
# =============================================================================

# Get absolute path of a file or directory
# Usage: abs_path=$(get_absolute_path "relative/path")
get_absolute_path() {
  local path="$1"

  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  elif [[ -f "$path" ]]; then
    local dir
    local file
    dir="$(dirname "$path")"
    file="$(basename "$path")"
    echo "$(cd "$dir" && pwd)/$file"
  else
    print_error "Path does not exist: $path"
    return 1
  fi
}

# Join array elements with a delimiter
# Usage: result=$(join_by "," "${array[@]}")
join_by() {
  local delimiter="$1"
  shift
  local first="$1"
  shift
  printf "%s" "$first" "${@/#/$delimiter}"
}

# Trim whitespace from string
# Usage: trimmed=$(trim "  text  ")
trim() {
  local var="$1"
  # Remove leading whitespace
  var="${var#"${var%%[![:space:]]*}"}"
  # Remove trailing whitespace
  var="${var%"${var##*[![:space:]]}"}"
  echo "$var"
}

# Convert string to lowercase
# Usage: lower=$(to_lowercase "UPPERCASE")
to_lowercase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Convert string to uppercase
# Usage: upper=$(to_uppercase "lowercase")
to_uppercase() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

# =============================================================================
# Error Handling
# =============================================================================

# Display error and exit with code
# Usage: die "Error message" [exit_code]
die() {
  local msg="$1"
  local code="${2:-1}"
  print_error "$msg"
  exit "$code"
}

# Trap handler for cleanup on exit
# Usage: trap cleanup EXIT
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    print_error "Script failed with exit code: $exit_code"
  fi
}

# =============================================================================
# Generator Validation Functions
# =============================================================================

# Validate template exists
# Usage: validate_template_exists "/path/to/template.txt"
validate_template_exists() {
  local template_path="$1"

  if [[ ! -f "$template_path" ]]; then
    print_error "Template not found: $template_path"
    return 1
  fi

  return 0
}

# Validate required variables are set
# Usage: validate_required_vars "VAR1" "VAR2" "VAR3"
validate_required_vars() {
  local missing_vars=()

  for var_name in "$@"; do
    if [[ -z "${!var_name:-}" ]]; then
      missing_vars+=("$var_name")
    fi
  done

  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    print_error "Required variables not set: ${missing_vars[*]}"
    return 1
  fi

  return 0
}

# Validate output file (check conflicts and permissions)
# Usage: validate_output_file "/path/to/output.txt" --force
validate_output_file() {
  local output_path="$1"
  local force_flag="${2:-}"

  # Check if file exists
  if [[ -f "$output_path" ]]; then
    if [[ "$force_flag" != "--force" ]]; then
      print_error "Output file already exists: $output_path"
      print_info "Use --force to overwrite"
      return 1
    fi
  fi

  # Check if directory is writable
  local output_dir
  output_dir=$(dirname "$output_path")

  if [[ ! -d "$output_dir" ]]; then
    print_error "Output directory does not exist: $output_dir"
    return 1
  fi

  if [[ ! -w "$output_dir" ]]; then
    print_error "Output directory is not writable: $output_dir"
    return 1
  fi

  return 0
}

# Comprehensive validation for generator inputs
# Usage: validate_generator_inputs \
#   --template "/path/to/template" \
#   --output "/path/to/output" \
#   --force \
#   --required-vars "VAR1 VAR2"
validate_generator_inputs() {
  local template_path=""
  local output_path=""
  local force_flag=""
  local required_vars=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template)
        template_path="$2"
        shift 2
        ;;
      --output)
        output_path="$2"
        shift 2
        ;;
      --force)
        force_flag="--force"
        shift
        ;;
      --required-vars)
        required_vars="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  local has_error=false

  # Validate template if provided
  if [[ -n "$template_path" ]]; then
    if ! validate_template_exists "$template_path"; then
      has_error=true
    fi
  fi

  # Validate output file if provided
  if [[ -n "$output_path" ]]; then
    if ! validate_output_file "$output_path" "$force_flag"; then
      has_error=true
    fi
  fi

  # Validate required variables if provided
  if [[ -n "$required_vars" ]]; then
    # Convert space-separated string to array
    local vars_array
    IFS=' ' read -ra vars_array <<< "$required_vars"
    if ! validate_required_vars "${vars_array[@]}"; then
      has_error=true
    fi
  fi

  if [[ "$has_error" == "true" ]]; then
    return 1
  fi

  return 0
}

# =============================================================================
# Initialization
# =============================================================================

# Library loaded successfully
print_debug "common.sh library loaded"

# Export functions for use in subshells (bash only)
# Note: ZSH doesn't support export -f, but functions are available when sourced
if [[ -z "${ZSH_VERSION:-}" ]]; then
  export -f print_error print_success print_warning print_info print_debug 2>/dev/null || true
  export -f check_dependency require_command check_optional 2>/dev/null || true
  export -f ensure_directory confirm_overwrite check_writable 2>/dev/null || true
  export -f ask_yes_no prompt_with_default 2>/dev/null || true
  export -f require_var require_file require_directory 2>/dev/null || true
  export -f get_absolute_path join_by trim to_lowercase to_uppercase 2>/dev/null || true
  export -f validate_template_exists validate_required_vars validate_output_file validate_generator_inputs 2>/dev/null || true
  export -f die cleanup 2>/dev/null || true
fi
