#!/usr/bin/env bash
#
# generate-dockerfile.sh - Generate Dockerfile from templates
#
# This script generates production-ready Dockerfiles using parameterized templates.
# It supports auto-detection of project language/framework and reads configuration
# from PROJECT.yaml if available.
#
# Usage:
#   generate-dockerfile.sh [OPTIONS]
#
# Options:
#   --template <name>     Force template (python-dhi, nodejs-dhi, generic-dhi)
#   --output <path>       Output path (default: ./Dockerfile)
#   --dry-run             Print to stdout instead of writing file
#   --force               Overwrite existing file without prompting
#   -h, --help            Show this help message
#
# Examples:
#   generate-dockerfile.sh                           # Auto-detect and generate
#   generate-dockerfile.sh --template python-dhi     # Force Python template
#   generate-dockerfile.sh --dry-run                 # Preview without writing
#   generate-dockerfile.sh --output backend/Dockerfile --force
#
# Environment Variables (can be set to override defaults):
#   USER_ID         - User ID for non-root user (default: 1000)
#   GROUP_ID        - Group ID for non-root user (default: 1000)
#   SOURCE_DIR      - Source directory (default: src)
#   TEST_DIR        - Test directory (default: tests)
#   TEST_COMMAND    - Test command (default: pytest)
#   MIN_COVERAGE    - Minimum coverage % (default: 80)
#   PYTHON_MODULE   - Python module name (default: app)
#   NODE_PORT       - Node.js port (default: 3000)
#   BUILD_CMD       - Build command (default: npm run build)
#   START_CMD       - Start command (default: node server.js)

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

# Source project-config library if available (optional)
if [[ -f "${SCRIPT_DIR}/lib/project-config.sh" ]]; then
    # shellcheck source=lib/project-config.sh
    source "${SCRIPT_DIR}/lib/project-config.sh" || {
        print_warning "Failed to load project-config.sh (continuing anyway)"
    }
fi

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

TEMPLATE=""
OUTPUT_PATH="./Dockerfile"
DRY_RUN=false
FORCE=false

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

show_help() {
    cat << EOF
generate-dockerfile.sh - Generate Dockerfile from templates

Usage:
  generate-dockerfile.sh [OPTIONS]

Options:
  --template <name>     Force template (python-dhi, nodejs-dhi, generic-dhi)
  --output <path>       Output path (default: ./Dockerfile)
  --dry-run             Print to stdout instead of writing file
  --force               Overwrite existing file without prompting
  -h, --help            Show this help message

Examples:
  generate-dockerfile.sh                           # Auto-detect and generate
  generate-dockerfile.sh --template python-dhi     # Force Python template
  generate-dockerfile.sh --dry-run                 # Preview without writing
  generate-dockerfile.sh --output backend/Dockerfile --force

Environment Variables (override defaults):
  USER_ID, GROUP_ID, SOURCE_DIR, TEST_DIR, TEST_COMMAND, MIN_COVERAGE,
  PYTHON_MODULE, NODE_PORT, BUILD_CMD, START_CMD

Template Variables:
  All templates:
    USER_ID=${USER_ID:-1000}       Group_ID=${GROUP_ID:-1000}
    TEST_DIR=${TEST_DIR:-tests}    MIN_COVERAGE=${MIN_COVERAGE:-80}

  Python template:
    SOURCE_DIR=${SOURCE_DIR:-src}  PYTHON_MODULE=${PYTHON_MODULE:-app}
    TEST_COMMAND=${TEST_COMMAND:-pytest}

  Node.js template:
    NODE_PORT=${NODE_PORT:-3000}   BUILD_CMD=${BUILD_CMD:-npm run build}
    START_CMD=${START_CMD:-node server.js}

  Generic template:
    TEST_COMMAND=${TEST_COMMAND:-pytest}

Available templates:
  - generic-dhi     Base DHI multi-stage build
  - python-dhi      Python with uv, pytest, pyproject.toml
  - nodejs-dhi      Node.js/Next.js with npm/yarn/pnpm

For more information, see: ~/.claude/docs/generators.md
EOF
}

detect_language() {
    local detected=""

    # Python detection
    if [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "requirements.txt" ]]; then
        detected="python"
        print_info "Detected Python project"
        echo "$detected"
        return 0
    fi

    # Node.js detection
    if [[ -f "package.json" ]]; then
        detected="nodejs"
        print_info "Detected Node.js project"
        echo "$detected"
        return 0
    fi

    # Go detection
    if [[ -f "go.mod" ]]; then
        print_warning "Go projects detected but not yet supported by templates"
        print_info "Hint: Use --template generic-dhi and customize manually"
        return 1
    fi

    # Rust detection
    if [[ -f "Cargo.toml" ]]; then
        print_warning "Rust projects detected but not yet supported by templates"
        print_info "Hint: Use --template generic-dhi and customize manually"
        return 1
    fi

    # No language detected
    print_warning "Could not detect project language"
    print_info "Looked for: pyproject.toml, package.json, go.mod, Cargo.toml"
    return 1
}

select_template() {
    local language="$1"
    local template_name=""

    case "$(to_lowercase "$language")" in
        python|py)
            template_name="python-dhi"
            ;;
        nodejs|node|javascript|js|typescript|ts)
            template_name="nodejs-dhi"
            ;;
        generic|default)
            template_name="generic-dhi"
            ;;
        *)
            print_error "Unknown language: $language"
            print_info "Supported: python, nodejs, generic"
            return 1
            ;;
    esac

    echo "$template_name"
}

read_project_config() {
    # Try to read PROJECT.yaml if it exists
    if [[ ! -f "PROJECT.yaml" ]]; then
        print_info "No PROJECT.yaml found, using defaults"
        return 0
    fi

    print_info "Reading configuration from PROJECT.yaml"

    # Check if yq is available
    if ! check_dependency "yq"; then
        print_warning "yq not installed, cannot read PROJECT.yaml"
        print_info "Install with: brew install yq  (or: apt-get install yq)"
        return 0
    fi

    # Read docker.build configuration if available
    local config_source_dir config_test_dir config_test_cmd config_coverage

    config_source_dir=$(yaml_get '.docker.build.source_dir // ""' PROJECT.yaml)
    config_test_dir=$(yaml_get '.docker.build.test_dir // ""' PROJECT.yaml)
    config_test_cmd=$(yaml_get '.docker.build.test_command // ""' PROJECT.yaml)
    config_coverage=$(yaml_get '.docker.build.min_coverage // ""' PROJECT.yaml)

    # Only override if values exist in config
    if [[ -n "$config_source_dir" ]]; then
        SOURCE_DIR="$config_source_dir"
        print_info "Using SOURCE_DIR from PROJECT.yaml: $SOURCE_DIR"
    fi

    if [[ -n "$config_test_dir" ]]; then
        TEST_DIR="$config_test_dir"
        print_info "Using TEST_DIR from PROJECT.yaml: $TEST_DIR"
    fi

    if [[ -n "$config_test_cmd" ]]; then
        TEST_COMMAND="$config_test_cmd"
        print_info "Using TEST_COMMAND from PROJECT.yaml: $TEST_COMMAND"
    fi

    if [[ -n "$config_coverage" ]]; then
        MIN_COVERAGE="$config_coverage"
        print_info "Using MIN_COVERAGE from PROJECT.yaml: $MIN_COVERAGE"
    fi

    # Read Python module name if available
    local config_python_module
    config_python_module=$(yaml_get '.docker.build.python_module // ""' PROJECT.yaml)
    if [[ -n "$config_python_module" ]]; then
        PYTHON_MODULE="$config_python_module"
        print_info "Using PYTHON_MODULE from PROJECT.yaml: $PYTHON_MODULE"
    fi

    # Read Node.js configuration if available
    local config_node_port config_build_cmd config_start_cmd
    config_node_port=$(yaml_get '.docker.build.node_port // ""' PROJECT.yaml)
    config_build_cmd=$(yaml_get '.docker.build.build_cmd // ""' PROJECT.yaml)
    config_start_cmd=$(yaml_get '.docker.build.start_cmd // ""' PROJECT.yaml)

    if [[ -n "$config_node_port" ]]; then
        NODE_PORT="$config_node_port"
        print_info "Using NODE_PORT from PROJECT.yaml: $NODE_PORT"
    fi

    if [[ -n "$config_build_cmd" ]]; then
        BUILD_CMD="$config_build_cmd"
        print_info "Using BUILD_CMD from PROJECT.yaml: $BUILD_CMD"
    fi

    if [[ -n "$config_start_cmd" ]]; then
        START_CMD="$config_start_cmd"
        print_info "Using START_CMD from PROJECT.yaml: $START_CMD"
    fi
}

export_template_variables() {
    # Export all template variables with defaults
    # These can be overridden by environment variables or PROJECT.yaml

    # Common variables
    export USER_ID="${USER_ID:-1000}"
    export GROUP_ID="${GROUP_ID:-1000}"
    export TEST_DIR="${TEST_DIR:-tests}"
    export MIN_COVERAGE="${MIN_COVERAGE:-80}"

    # Python-specific variables
    export SOURCE_DIR="${SOURCE_DIR:-src}"
    export PYTHON_MODULE="${PYTHON_MODULE:-app}"
    export TEST_COMMAND="${TEST_COMMAND:-pytest}"

    # Node.js-specific variables
    export NODE_PORT="${NODE_PORT:-3000}"
    export BUILD_CMD="${BUILD_CMD:-npm run build}"
    export START_CMD="${START_CMD:-node server.js}"

    print_info "Template variables exported:"
    print_info "  USER_ID=$USER_ID, GROUP_ID=$GROUP_ID"
    print_info "  SOURCE_DIR=$SOURCE_DIR, TEST_DIR=$TEST_DIR"
    print_info "  TEST_COMMAND=$TEST_COMMAND, MIN_COVERAGE=$MIN_COVERAGE"
    print_info "  PYTHON_MODULE=$PYTHON_MODULE"
    print_info "  NODE_PORT=$NODE_PORT, BUILD_CMD=$BUILD_CMD, START_CMD=$START_CMD"
}

generate_dockerfile() {
    local template_name="$1"
    local output_path="$2"

    print_info "Generating Dockerfile from template: $template_name"

    # Find the template (checks project override, then global)
    local template_path
    template_path=$(find_template "dockerfiles" "${template_name}.dockerfile")
    local find_result=$?

    if [[ $find_result -ne 0 ]]; then
        print_error "Template not found: ${template_name}.dockerfile"
        print_info "Available templates:"
        list_templates "dockerfiles" 2>/dev/null || print_info "  (cannot list templates)"
        print_info ""
        print_info "Searched in:"
        print_info "  - .claude/templates/dockerfiles/ (project override)"
        print_info "  - ~/.claude/templates/dockerfiles/ (global)"
        return 1
    fi

    print_success "Found template: $template_path"

    # Render the template
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "Dry run mode - outputting to stdout:"
        echo ""
        echo "# ============================================================"
        render_template_stdout "$template_path"
        echo "# ============================================================"
        echo ""
        print_success "Dry run complete (no file written)"
        return 0
    fi

    # Check if output file exists
    if [[ -f "$output_path" ]] && [[ "$FORCE" != "true" ]]; then
        if ! confirm_overwrite "$output_path"; then
            print_warning "Dockerfile generation cancelled"
            return 1
        fi
    fi

    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$output_path")
    if ! ensure_directory "$output_dir"; then
        print_error "Failed to create output directory: $output_dir"
        return 1
    fi

    # Render template to file
    if render_template "$template_path" "$output_path"; then
        print_success "Dockerfile generated: $output_path"
        print_info ""
        print_info "Next steps:"
        print_info "  1. Review and customize the Dockerfile if needed"
        print_info "  2. Build: docker build -t myapp:latest ."
        print_info "  3. Build with tests: docker build --build-arg RUN_TESTS=true -t myapp:latest ."
        print_info ""
        print_info "Template used: $template_name"
        return 0
    else
        print_error "Failed to generate Dockerfile"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --template)
                TEMPLATE="$2"
                shift 2
                ;;
            --output)
                OUTPUT_PATH="$2"
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
            *)
                print_error "Unknown option: $1"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done

    print_info "Dockerfile Generator"
    print_info "===================="
    echo ""

    # Read PROJECT.yaml configuration if available
    read_project_config

    # Determine template to use
    local template_name=""

    if [[ -n "$TEMPLATE" ]]; then
        # Template explicitly specified
        print_info "Using specified template: $TEMPLATE"
        template_name="$TEMPLATE"
    else
        # Auto-detect language
        print_info "Auto-detecting project language..."
        local detected_language
        if detected_language=$(detect_language); then
            # Select template based on detected language
            if template_name=$(select_template "$detected_language"); then
                print_success "Selected template: $template_name (for $detected_language)"
            else
                print_error "Failed to select template for language: $detected_language"
                exit 1
            fi
        else
            # Could not detect language
            print_error "Could not auto-detect project language"
            print_info ""
            print_info "Solutions:"
            print_info "  1. Specify template explicitly: --template python-dhi"
            print_info "  2. Add language marker file (pyproject.toml, package.json, etc.)"
            print_info "  3. Configure PROJECT.yaml with project metadata"
            print_info ""
            print_info "Available templates: generic-dhi, python-dhi, nodejs-dhi"
            exit 1
        fi
    fi

    # Export template variables
    export_template_variables

    # Generate Dockerfile
    if generate_dockerfile "$template_name" "$OUTPUT_PATH"; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"
