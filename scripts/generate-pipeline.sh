#!/usr/bin/env bash
#
# generate-pipeline.sh - Generate CI/CD pipeline from templates
#
# This script generates CI/CD pipeline configurations (GitHub Actions or GitLab CI)
# using parameterized templates. It supports auto-detection of platform and language.
#
# Usage:
#   generate-pipeline.sh [OPTIONS]
#
# Options:
#   --platform <name>     Force platform (github, gitlab)
#   --language <name>     Force language (python, nodejs)
#   --output <path>       Output path (default: auto-detect)
#   --dry-run             Print to stdout instead of writing file
#   --force               Overwrite existing file without prompting
#   -h, --help            Show this help message
#
# Examples:
#   generate-pipeline.sh                                 # Auto-detect and generate
#   generate-pipeline.sh --platform github               # Force GitHub Actions
#   generate-pipeline.sh --dry-run                       # Preview without writing
#   generate-pipeline.sh --platform gitlab --language python
#
# Environment Variables (can be set to override defaults):
#   PROJECT_NAME            - Project name (default: directory name)
#   STAGING_BRANCH          - Staging branch name (default: dev)
#   PRODUCTION_BRANCH       - Production branch name (default: main)
#   REGISTRY_URL            - Docker registry URL
#   TEST_COMMAND            - Test command (language-specific default)
#   LINT_COMMAND            - Lint command (language-specific default)
#   TYPECHECK_COMMAND       - Type check command (language-specific default)
#   MIN_COVERAGE            - Minimum coverage % (default: 80)
#   INCLUDE_SECURITY        - Include security scanning job
#   INCLUDE_MIGRATIONS      - Include database migration jobs
#   INCLUDE_E2E             - Include E2E testing job
#   INCLUDE_NOTIFICATIONS   - Include notification jobs

set -euo pipefail

# Get script directory for sourcing libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh" || {
    echo "Error: Failed to load common.sh library" >&2
    exit 1
}

# shellcheck source=lib/templates.sh
source "${SCRIPT_DIR}/lib/templates.sh" || {
    print_error "Failed to load templates.sh library"
    exit 1
}

# shellcheck source=lib/yaml.sh
source "${SCRIPT_DIR}/lib/yaml.sh" || {
    print_error "Failed to load yaml.sh library"
    exit 1
}

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

PLATFORM=""
LANGUAGE=""
OUTPUT_FILE=""
DRY_RUN=false
FORCE=false

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

show_help() {
    cat << EOF
generate-pipeline.sh - Generate CI/CD pipeline from templates

Usage:
  generate-pipeline.sh [OPTIONS]

Options:
  --platform <name>     Force platform (github, gitlab)
  --language <name>     Force language (python, nodejs)
  --output <path>       Output path (default: auto-detect)
  --dry-run             Print to stdout instead of writing file
  --force               Overwrite existing file without prompting
  -h, --help            Show this help message

Examples:
  generate-pipeline.sh                                 # Auto-detect and generate
  generate-pipeline.sh --platform github               # Force GitHub Actions
  generate-pipeline.sh --dry-run                       # Preview without writing
  generate-pipeline.sh --platform gitlab --language python

Environment Variables:
  PROJECT_NAME, STAGING_BRANCH, PRODUCTION_BRANCH, REGISTRY_URL,
  TEST_COMMAND, LINT_COMMAND, TYPECHECK_COMMAND, MIN_COVERAGE,
  INCLUDE_SECURITY, INCLUDE_MIGRATIONS, INCLUDE_E2E, INCLUDE_NOTIFICATIONS

Platform Detection:
  1. Reads from PROJECT.yaml (git.platform)
  2. Parses git remote URL (github.com or gitlab)
  3. Falls back to --platform flag

Language Detection:
  1. Reads from PROJECT.yaml (tech_stack.languages[0])
  2. Checks for marker files (pyproject.toml, package.json)
  3. Falls back to --language flag

Output Path:
  GitHub: .github/workflows/ci-cd.yml
  GitLab: .gitlab-ci.yml
EOF
}

detect_platform() {
    local platform=""

    # Strategy 1: Read from PROJECT.yaml
    if [[ -f "PROJECT.yaml" ]]; then
        platform=$(yaml_get '.git.platform // ""' PROJECT.yaml)
        if [[ -n "$platform" ]]; then
            echo "$platform"
            return 0
        fi
    fi

    # Strategy 2: Parse git remote URL
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ -z "$remote_url" ]]; then
        print_error "No git remote found. Cannot detect platform."
        print_info "Run: git remote add origin <url>"
        print_info "Or use: --platform github|gitlab"
        return 1
    fi

    # Check URL patterns
    if [[ "$remote_url" =~ github\.com ]]; then
        echo "github"
    elif [[ "$remote_url" =~ gitlab ]] || [[ "$remote_url" =~ git\. ]]; then
        echo "gitlab"
    else
        print_warning "Cannot detect platform from remote: $remote_url"
        print_info "Use --platform github|gitlab"
        return 1
    fi
}

detect_language() {
    local language=""

    # Strategy 1: Read from PROJECT.yaml
    if [[ -f "PROJECT.yaml" ]]; then
        language=$(yaml_get '.tech_stack.languages[0] // ""' PROJECT.yaml)
        if [[ -n "$language" ]]; then
            echo "$language"
            return 0
        fi
    fi

    # Strategy 2: Check for language marker files
    if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
        echo "python"
    elif [[ -f "package.json" ]]; then
        echo "nodejs"
    else
        print_warning "Cannot detect language"
        print_info "Create pyproject.toml or package.json"
        print_info "Or use: --language python|nodejs"
        return 1
    fi
}

validate_platform() {
    local platform="$1"
    if [[ "$platform" != "github" && "$platform" != "gitlab" ]]; then
        print_error "Invalid platform: $platform"
        print_info "Valid platforms: github, gitlab"
        return 1
    fi
}

validate_language() {
    local language="$1"
    if [[ "$language" != "python" && "$language" != "nodejs" ]]; then
        print_error "Invalid language: $language"
        print_info "Valid languages: python, nodejs"
        return 1
    fi
}

read_project_config() {
    if [[ ! -f "PROJECT.yaml" ]]; then
        print_debug "PROJECT.yaml not found, using defaults"
        return 0
    fi

    print_debug "Loading configuration from PROJECT.yaml"

    # Read CI configuration
    export STAGING_BRANCH="${STAGING_BRANCH:-$(yaml_get_default '.ci.branches.staging' 'dev' PROJECT.yaml)}"
    export PRODUCTION_BRANCH="${PRODUCTION_BRANCH:-$(yaml_get_default '.ci.branches.production' 'main' PROJECT.yaml)}"

    # Read Docker registry configuration
    export REGISTRY_URL="${REGISTRY_URL:-$(yaml_get '.docker.registry.url // ""' PROJECT.yaml)}"

    # Check for optional features
    local migrations_enabled
    migrations_enabled=$(yaml_get_default '.databases[0].migrations.enabled' 'false' PROJECT.yaml)
    if [[ "$migrations_enabled" == "true" ]]; then
        export INCLUDE_MIGRATIONS="true"
    fi

    # Read test commands
    local project_test_cmd
    project_test_cmd=$(yaml_get '.testing.command // ""' PROJECT.yaml)
    if [[ -n "$project_test_cmd" ]]; then
        export TEST_COMMAND="$project_test_cmd"
    fi

    local project_min_coverage
    project_min_coverage=$(yaml_get '.testing.min_coverage // ""' PROJECT.yaml)
    if [[ -n "$project_min_coverage" ]]; then
        export MIN_COVERAGE="$project_min_coverage"
    fi

    print_debug "Configuration loaded from PROJECT.yaml"
}

export_template_vars() {
    # Required variables
    export PROJECT_NAME="${PROJECT_NAME:-$(basename "$(pwd)")}"
    export STAGING_BRANCH="${STAGING_BRANCH:-dev}"
    export PRODUCTION_BRANCH="${PRODUCTION_BRANCH:-main}"
    export MIN_COVERAGE="${MIN_COVERAGE:-80}"

    # Optional conditional variables (for #IF blocks)
    export INCLUDE_SECURITY="${INCLUDE_SECURITY:-}"
    export INCLUDE_MIGRATIONS="${INCLUDE_MIGRATIONS:-}"
    export INCLUDE_E2E="${INCLUDE_E2E:-}"
    export INCLUDE_NOTIFICATIONS="${INCLUDE_NOTIFICATIONS:-}"

    # Language-specific commands
    if [[ "$LANGUAGE" == "python" ]]; then
        export LINT_COMMAND="${LINT_COMMAND:-ruff check .}"
        export TEST_COMMAND="${TEST_COMMAND:-pytest}"
        export TYPECHECK_COMMAND="${TYPECHECK_COMMAND:-pyright}"
        export FORMAT_COMMAND="${FORMAT_COMMAND:-ruff format --check .}"
    elif [[ "$LANGUAGE" == "nodejs" ]]; then
        export LINT_COMMAND="${LINT_COMMAND:-npm run lint}"
        export TEST_COMMAND="${TEST_COMMAND:-npm test}"
        export TYPECHECK_COMMAND="${TYPECHECK_COMMAND:-npm run typecheck}"
        export FORMAT_COMMAND="${FORMAT_COMMAND:-npm run format:check}"
    fi

    # Platform-specific (GitHub needs AWS role for OIDC)
    if [[ "$PLATFORM" == "github" ]]; then
        export AWS_ROLE_ARN="${AWS_ROLE_ARN:-}"
    fi
}

#------------------------------------------------------------------------------
# Argument Parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

#------------------------------------------------------------------------------
# Main Logic
#------------------------------------------------------------------------------

# Auto-detect platform if not specified
if [[ -z "$PLATFORM" ]]; then
    print_info "Auto-detecting platform..."
    PLATFORM=$(detect_platform)
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    print_success "Detected platform: $PLATFORM"
else
    validate_platform "$PLATFORM" || exit 1
fi

# Auto-detect language if not specified
if [[ -z "$LANGUAGE" ]]; then
    print_info "Auto-detecting language..."
    LANGUAGE=$(detect_language)
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    print_success "Detected language: $LANGUAGE"
else
    validate_language "$LANGUAGE" || exit 1
fi

# Read configuration from PROJECT.yaml
read_project_config

# Export template variables
export_template_vars

# Construct template name
TEMPLATE_NAME="${PLATFORM}-${LANGUAGE}.yml"

# Find template
TEMPLATE_PATH=$(find_template "pipelines" "${TEMPLATE_NAME}")
if [[ $? -ne 0 ]]; then
    print_error "Template not found: ${TEMPLATE_NAME}"
    print_info "Available templates:"
    list_templates "pipelines"
    exit 1
fi

# Determine output path based on platform
if [[ -z "$OUTPUT_FILE" ]]; then
    if [[ "$PLATFORM" == "github" ]]; then
        OUTPUT_FILE=".github/workflows/ci-cd.yml"
    elif [[ "$PLATFORM" == "gitlab" ]]; then
        OUTPUT_FILE=".gitlab-ci.yml"
    fi
fi

# Render template
if [[ "$DRY_RUN" == "true" ]]; then
    print_info "Platform: $PLATFORM"
    print_info "Language: $LANGUAGE"
    print_info "Template: $TEMPLATE_NAME"
    echo ""
    render_template_stdout "$TEMPLATE_PATH"
else
    # Check for existing file
    if [[ -f "$OUTPUT_FILE" ]] && [[ "$FORCE" != "true" ]]; then
        confirm_overwrite "$OUTPUT_FILE" || exit 0
    fi

    # Create directory if needed
    ensure_directory "$(dirname "$OUTPUT_FILE")"

    # Render to file
    render_template "$TEMPLATE_PATH" "$OUTPUT_FILE"

    print_success "Generated pipeline: $OUTPUT_FILE"
    print_info "Platform: $PLATFORM"
    print_info "Language: $LANGUAGE"
    print_info "Template: $TEMPLATE_NAME"
fi
