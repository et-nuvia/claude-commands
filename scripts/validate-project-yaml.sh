#!/usr/bin/env bash
set -euo pipefail

# validate-project-yaml.sh - Validate PROJECT.yaml against schema
# Usage:
#   validate-project-yaml.sh [path/to/PROJECT.yaml]
#
# Output:
#   true - If validation passes
#   false - If validation fails, followed by list of invalid paths
#
# Exit codes:
#   0 - Valid
#   1 - Invalid

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_YAML="${1:-PROJECT.yaml}"

# Check if Python validation script exists
if [[ ! -f "${SCRIPT_DIR}/validate-project-yaml.py" ]]; then
    echo "ERROR: Python validation script not found" >&2
    exit 1
fi

# Call Python validation script
"${SCRIPT_DIR}/validate-project-yaml.py" "$PROJECT_YAML"
