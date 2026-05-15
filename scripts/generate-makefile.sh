#!/usr/bin/env bash
#
# generate-makefile.sh - Generate Makefiles for hierarchical project structure
#
# This script generates Makefiles using parameterized templates.  It supports
# auto-detection of components and generates both root and component Makefiles.
#
# Usage:
#   generate-makefile.sh [OPTIONS]
#
# Options:
#   --components <list>   Force components (format: name:path:language,...)
#   --root-only           Only generate root Makefile
#   --output-dir <path>   Output directory (default: current directory)
#   --dry-run             Print to stdout instead of writing files
#   --force               Overwrite existing files without prompting
#   -h, --help            Show this help message
#
# Examples:
#   generate-makefile.sh                                 # Auto-detect and generate
#   generate-makefile.sh --root-only                     # Only root Makefile
#   generate-makefile.sh --dry-run                       # Preview without writing
#   generate-makefile.sh --components "backend:backend:python,frontend:frontend:nodejs"
#
# Environment Variables (can be set to override defaults):
#   BACKEND_DIR     - Backend directory (default: backend)
#   FRONTEND_DIR    - Frontend directory (default: frontend)
#   APP_SERVICE     - Docker Compose app service name (default: backend)
#   SOURCE_DIR      - Source directory (default: src)
#   TEST_DIR        - Test directory (default: tests)
#   APP_PORT        - Application port (default: 8000 for Python, 3000 for Node.js)
#   FRONTEND_PORT   - Frontend port (default: 3000)
#   MIN_COVERAGE    - Minimum test coverage % (default: 80)

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

COMPONENTS=""
ROOT_ONLY=false
OUTPUT_DIR="."
DRY_RUN=false
FORCE=false

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

show_help() {
    cat << EOF
generate-makefile.sh - Generate Makefiles for hierarchical project structure

Usage:
  generate-makefile.sh [OPTIONS]

Options:
  --components <list>   Force components (format: name:path:language,...)
  --root-only           Only generate root Makefile
  --output-dir <path>   Output directory (default: current directory)
  --dry-run             Print to stdout instead of writing files
  --force               Overwrite existing files without prompting
  -h, --help            Show this help message

Examples:
  generate-makefile.sh                                 # Auto-detect and generate
  generate-makefile.sh --root-only                     # Only root Makefile
  generate-makefile.sh --dry-run                       # Preview without writing
  generate-makefile.sh --components "backend:backend:python,frontend:frontend:nodejs"

Environment Variables:
  BACKEND_DIR, FRONTEND_DIR, APP_SERVICE, SOURCE_DIR, TEST_DIR,
  APP_PORT, FRONTEND_PORT, MIN_COVERAGE

Component Detection:
  1. Reads from PROJECT.yaml (components array)
  2. Auto-detects from directory structure (backend/, frontend/)
  3. Falls back to --components flag

Component Format:
  name:path:language
  - name: Component name (backend, frontend, api, etc.)
  - path: Relative path to component directory
  - language: Language/framework (python, nodejs)

Generated Files:
  - Makefile (root orchestrator)
  - <component>/Makefile (component-specific targets)
EOF
}

detect_components() {
    local components=()

    # Strategy 1: Read from PROJECT.yaml
    if [[ -f "PROJECT.yaml" ]]; then
        local component_count
        component_count=$(yaml_get_default '.components | length' '0' PROJECT.yaml)
        if [[ "$component_count" -gt 0 ]]; then
            for ((i=0; i<component_count; i++)); do
                local name
                local path
                local language
                name=$(yaml_get ".components[$i].name" PROJECT.yaml)
                path=$(yaml_get ".components[$i].path" PROJECT.yaml)
                language=$(yaml_get ".components[$i].language" PROJECT.yaml)
                components+=("$name:$path:$language")
            done
            echo "${components[@]}"
            return 0
        fi
    fi

    # Strategy 2: Auto-detect from directory structure
    if [[ -d "backend" ]] && [[ -f "backend/pyproject.toml" || -f "backend/requirements.txt" ]]; then
        components+=("backend:backend:python")
    fi

    if [[ -d "frontend" ]] && [[ -f "frontend/package.json" ]]; then
        components+=("frontend:frontend:nodejs")
    fi

    if [[ ${#components[@]} -eq 0 ]]; then
        print_warning "No components detected"
        print_info "Add components to PROJECT.yaml or use --components"
        return 1
    fi

    echo "${components[@]}"
}

generate_component_makefile() {
    local name="$1"
    local path="$2"
    local language="$3"

    # Select template based on language
    local template_name=""
    if [[ "$language" == "python" ]]; then
        template_name="python-backend.mk"
    elif [[ "$language" == "nodejs" ]]; then
        template_name="nodejs-frontend.mk"
    else
        print_error "Unsupported language: $language"
        return 1
    fi

    # Export component-specific variables
    export APP_SERVICE="${name}"
    export COMPONENT="${name}"
    export SOURCE_DIR="${SOURCE_DIR:-src}"
    export TEST_DIR="${TEST_DIR:-tests}"
    export MIN_COVERAGE="${MIN_COVERAGE:-80}"

    # Set default ports based on language
    if [[ "$language" == "python" ]]; then
        export APP_PORT="${APP_PORT:-8000}"
    elif [[ "$language" == "nodejs" ]]; then
        export FRONTEND_PORT="${FRONTEND_PORT:-3000}"
    fi

    # Find template
    local template_path
    template_path=$(find_template "makefiles" "${template_name}")
    if [[ $? -ne 0 ]]; then
        print_error "Template not found: ${template_name}"
        return 1
    fi

    # Output path
    local output_file="${OUTPUT_DIR}/${path}/Makefile"

    # Render template
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "Would generate: $output_file"
        echo ""
        render_template_stdout "$template_path" | head -20
        echo "..."
    else
        # Check for existing file
        if [[ -f "$output_file" ]] && [[ "$FORCE" != "true" ]]; then
            confirm_overwrite "$output_file" || return 0
        fi

        # Create directory if needed
        ensure_directory "$(dirname "$output_file")"

        # Render to file
        render_template "$template_path" "$output_file"

        print_success "Generated: $output_file"
    fi
}

generate_root_makefile() {
    local components=("$@")

    # Set conditional variables based on detected components
    export HAS_BACKEND=""
    export HAS_FRONTEND=""
    export HAS_DATABASE=""
    export BACKEND_DIR="${BACKEND_DIR:-backend}"
    export FRONTEND_DIR="${FRONTEND_DIR:-frontend}"

    for component in "${components[@]}"; do
        IFS=':' read -r name path language <<< "$component"

        if [[ "$name" == "backend" ]]; then
            export HAS_BACKEND="true"
            export BACKEND_DIR="$path"
        fi

        if [[ "$name" == "frontend" ]]; then
            export HAS_FRONTEND="true"
            export FRONTEND_DIR="$path"
        fi

        # Check if database exists (from PROJECT.yaml)
        if [[ -f "PROJECT.yaml" ]]; then
            local db_count
            db_count=$(yaml_get_default '.databases | length' '0' PROJECT.yaml)
            if [[ "$db_count" -gt 0 ]]; then
                export HAS_DATABASE="true"
            fi
        fi
    done

    # Find root template
    local template_path
    template_path=$(find_template "makefiles" "root.mk")
    if [[ $? -ne 0 ]]; then
        print_error "Root template not found: root.mk"
        return 1
    fi

    local output_file="${OUTPUT_DIR}/Makefile"

    # Render template
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "Root Makefile (preview):"
        echo ""
        render_template_stdout "$template_path" | head -40
        echo "..."
    else
        # Check for existing file
        if [[ -f "$output_file" ]] && [[ "$FORCE" != "true" ]]; then
            confirm_overwrite "$output_file" || return 0
        fi

        # Render to file
        render_template "$template_path" "$output_file"

        print_success "Generated: $output_file"
    fi
}

#------------------------------------------------------------------------------
# Argument Parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --components)
            COMPONENTS="$2"
            shift 2
            ;;
        --root-only)
            ROOT_ONLY=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
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

# Detect or parse components
if [[ -n "$COMPONENTS" ]]; then
    # Parse comma-separated list
    IFS=',' read -ra component_array <<< "$COMPONENTS"
    print_info "Using provided components: ${#component_array[@]} component(s)"
else
    # Auto-detect
    print_info "Auto-detecting components..."
    component_array=($(detect_components))
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    print_success "Detected ${#component_array[@]} component(s)"
fi

# Show detected components
for component in "${component_array[@]}"; do
    IFS=':' read -r name path language <<< "$component"
    print_debug "Component: $name @ $path ($language)"
done

# Generate component Makefiles
if [[ "$ROOT_ONLY" != "true" ]]; then
    for component in "${component_array[@]}"; do
        IFS=':' read -r name path language <<< "$component"
        print_info "Generating Makefile for $name ($language)"
        generate_component_makefile "$name" "$path" "$language"
    done
fi

# Generate root Makefile
print_info "Generating root Makefile"
generate_root_makefile "${component_array[@]}"

if [[ "$DRY_RUN" != "true" ]]; then
    echo ""
    print_success "Makefile generation complete!"
    print_info "Run: make help"
fi
