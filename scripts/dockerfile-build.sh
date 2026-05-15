#!/usr/bin/env bash
set -euo pipefail

#######################################
# dockerfile-build.sh
#
# Generates a new Dockerfile following best practices:
# - Multi-stage build (build, test, runtime)
# - DHI base images (dhi.io/python, dhi.io/node)
# - Testing stage with RUN_TESTS build arg
# - Security hardening (non-root user, minimal base)
#
# Output Modes:
#   --json: Structured JSON output (default)
#   --raw:  Human-readable verbose output
#
# Sections:
#   --full:     Run all sections (default)
#   --detect:   Detect project type and requirements
#   --generate: Generate Dockerfile content
#   --validate: Validate generated Dockerfile
#
# Usage:
#   dockerfile-build.sh [--json|--raw] [--full|--detect|--generate|--validate]
#######################################

# Get script directory for sourcing libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/yaml.sh
source "${SCRIPT_DIR}/lib/yaml.sh" || {
    echo "Error: Failed to load yaml.sh library" >&2
    exit 1
}

# Custom status-to-action mapping (must be defined before sourcing output-framework.sh)
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        error)   echo "fix_validation_issues" ;;
        *)       echo "display_summary" ;;
    esac
}

# shellcheck source=lib/output-framework.sh
source "${SCRIPT_DIR}/lib/output-framework.sh" || {
    echo "Error: Failed to load output-framework.sh library" >&2
    exit 1
}

# Default values
OUTPUT_MODE="json"
SECTION="full"
DOCKERFILE_PATH="Dockerfile"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
    --raw) OUTPUT_MODE="raw"; shift ;;
    --full) SECTION="full"; shift ;;
    --detect) SECTION="detect"; shift ;;
    --generate) SECTION="generate"; shift ;;
    --validate) SECTION="validate"; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

#######################################
# Output Functions
#######################################

raw_output() {
  local level="$1"
  local message="$2"

  case "$level" in
    info) echo "[INFO] $message" ;;
    warn) echo "[WARN] $message" ;;
    error) echo "[ERROR] $message" ;;
    success) echo "[SUCCESS] $message" ;;
  esac
}

#######################################
# Section: Detect Project Type
#######################################

detect_project_type() {
  local project_type="generic"
  local has_pyproject=false
  local has_package_json=false
  local has_cargo=false

  # Check for project files
  if [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
    has_pyproject=true
    project_type="python"
  fi

  if [[ -f "package.json" ]]; then
    has_package_json=true
    project_type="nodejs"

    # Check if it's Next.js
    if grep -q '"next"' package.json 2>/dev/null; then
      project_type="nextjs"
    fi
  fi

  if [[ -f "Cargo.toml" ]]; then
    has_cargo=true
    project_type="rust"
  fi

  # Check for PROJECT.yaml
  local base_image="debian:bookworm-slim"
  if [[ -f "PROJECT.yaml" ]]; then
    # Try to extract base image if specified
    local yaml_base
    yaml_base=$(yaml_get '.docker.base_image // ""' PROJECT.yaml)
    if [[ -n "$yaml_base" ]]; then
      base_image="$yaml_base"
    fi
  fi

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    local data
    data=$(cat <<EOF
{
  "project_type": "$project_type",
  "has_pyproject": $has_pyproject,
  "has_package_json": $has_package_json,
  "has_cargo": $has_cargo,
  "base_image": "$base_image"
}
EOF
)
    SECTION="detect"
    log_json "{\"status\":\"success\",\"section\":\"detect\",\"next_action\":\"$(map_status_to_action success)\",\"message\":\"Detected project type: $project_type\",\"timestamp\":\"$(date -Iseconds)\",\"data\":$data}"
  else
    raw_output "info" "Detecting project type..."
    raw_output "info" "Project type: $project_type"
    raw_output "info" "Has pyproject.toml: $has_pyproject"
    raw_output "info" "Has package.json: $has_package_json"
    raw_output "info" "Has Cargo.toml: $has_cargo"
    raw_output "info" "Base image: $base_image"
  fi

  # Export for other sections
  export DETECTED_PROJECT_TYPE="$project_type"
  export DETECTED_BASE_IMAGE="$base_image"
}

#######################################
# Section: Generate Dockerfile
#######################################

generate_dockerfile() {
  local project_type="${DETECTED_PROJECT_TYPE:-generic}"
  local base_image="${DETECTED_BASE_IMAGE:-debian:slim}"

  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    raw_output "info" "Generating Dockerfile for project type: $project_type"
  fi

  local dockerfile_content=""

  case "$project_type" in
    python)
      dockerfile_content=$(cat <<'DOCKERFILE'
# Stage 1: Build
FROM dhi.io/python:3.14-debian13-dev AS builder

WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY src/ ./src/

# Install dependencies
RUN uv sync --frozen

# Stage 2: Testing (conditional)
FROM builder AS testing
ARG RUN_TESTS=false
RUN if [ "$RUN_TESTS" = "true" ]; then \
      uv run pytest tests/ -v --cov=src --cov-fail-under=80; \
    fi

# Stage 3: Runtime
FROM dhi.io/python:3.14-debian13 AS runtime

# Security: non-root user
RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -s /bin/false app

WORKDIR /app
COPY --from=builder /app/.venv ./.venv
COPY --from=builder /app/src ./src

# Security hardening
USER app:app

ENTRYPOINT ["python", "-m", "app"]
DOCKERFILE
)
      ;;

    nodejs)
      dockerfile_content=$(cat <<'DOCKERFILE'
# Stage 1: Build
FROM dhi.io/node:24-debian13-dev AS builder

WORKDIR /app
COPY package.json package-lock.json ./
COPY . .

# Install dependencies and build
RUN npm ci
RUN npm run build

# Stage 2: Testing (conditional)
FROM builder AS testing
ARG RUN_TESTS=false
RUN if [ "$RUN_TESTS" = "true" ]; then \
      npm test -- --coverage --coverageThreshold='{"global":{"lines":80}}'; \
    fi

# Stage 3: Runtime
FROM dhi.io/node:24-debian13 AS runtime

# Security: non-root user
RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -s /bin/false app

WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

USER app:app

CMD ["node", "dist/index.js"]
DOCKERFILE
)
      ;;

    nextjs)
      dockerfile_content=$(cat <<'DOCKERFILE'
# Stage 1: Build
FROM dhi.io/node:24-debian13-dev AS builder

WORKDIR /app
COPY package.json package-lock.json ./
COPY . .

# Install dependencies and build
RUN npm ci
RUN npm run build

# Stage 2: Testing (conditional)
FROM builder AS testing
ARG RUN_TESTS=false
RUN if [ "$RUN_TESTS" = "true" ]; then \
      npm test -- --coverage --coverageThreshold='{"global":{"lines":80}}'; \
    fi

# Stage 3: Runtime
FROM dhi.io/node:24-debian13 AS runtime

# Security: non-root user
RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -s /bin/false app

WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

USER app:app
EXPOSE 3000

CMD ["node", "server.js"]
DOCKERFILE
)
      ;;

    *)
      # Generic multi-stage Dockerfile
      dockerfile_content=$(cat <<'DOCKERFILE'
# Stage 1: Build
FROM debian:bookworm-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

# Build the application
RUN make build

# Stage 2: Testing (conditional)
FROM builder AS testing
ARG RUN_TESTS=false
RUN if [ "$RUN_TESTS" = "true" ]; then \
      make test; \
    fi

# Stage 3: Runtime
FROM debian:bookworm-slim AS runtime

# Security: non-root user
RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -s /bin/false app

WORKDIR /app
COPY --from=builder /app/build ./

# Security hardening
USER app:app

ENTRYPOINT ["/app/bin/application"]
DOCKERFILE
)
      ;;
  esac

  # Write Dockerfile
  echo "$dockerfile_content" > "$DOCKERFILE_PATH"

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    local data
    data=$(cat <<EOF
{
  "dockerfile_path": "$DOCKERFILE_PATH",
  "project_type": "$project_type",
  "lines": $(echo "$dockerfile_content" | wc -l)
}
EOF
)
    SECTION="generate"
    log_json "{\"status\":\"success\",\"section\":\"generate\",\"next_action\":\"$(map_status_to_action success)\",\"message\":\"Dockerfile generated at $DOCKERFILE_PATH\",\"timestamp\":\"$(date -Iseconds)\",\"data\":$data}"
  else
    raw_output "success" "Dockerfile generated at $DOCKERFILE_PATH"
    raw_output "info" "Project type: $project_type"
    raw_output "info" "Lines: $(echo "$dockerfile_content" | wc -l)"
    echo ""
    echo "--- Generated Dockerfile ---"
    echo "$dockerfile_content"
    echo "--- End Dockerfile ---"
  fi
}

#######################################
# Section: Validate Dockerfile
#######################################

validate_dockerfile() {
  if [[ ! -f "$DOCKERFILE_PATH" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      SECTION="validate"
      exit_with_json "error" "Dockerfile not found at $DOCKERFILE_PATH"
    else
      raw_output "error" "Dockerfile not found at $DOCKERFILE_PATH"
    fi
    return 1
  fi

  local issues=()
  local warnings=()

  # Check for multi-stage build
  if ! grep -q "FROM .* AS" "$DOCKERFILE_PATH"; then
    issues+=("Missing multi-stage build")
  fi

  # Check for testing stage
  if ! grep -q "FROM .* AS testing" "$DOCKERFILE_PATH"; then
    issues+=("Missing testing stage")
  fi

  # Check for RUN_TESTS build arg
  if ! grep -q "ARG RUN_TESTS" "$DOCKERFILE_PATH"; then
    issues+=("Missing RUN_TESTS build arg")
  fi

  # Check for non-root user
  if ! grep -q "USER" "$DOCKERFILE_PATH"; then
    issues+=("Missing non-root USER directive")
  fi

  # Check for 'latest' tags
  if grep -E "FROM.*:latest" "$DOCKERFILE_PATH" >/dev/null; then
    warnings+=("Found 'latest' tag in FROM directive (pin versions for reproducibility)")
  fi

  # Check for DHI base images (recommended)
  if ! grep -qE "FROM dhi\.io/" "$DOCKERFILE_PATH"; then
    warnings+=("No DHI base images found (recommend dhi.io/python or dhi.io/node)")
  fi

  # Check for ENTRYPOINT or CMD
  if ! grep -qE "^(ENTRYPOINT|CMD)" "$DOCKERFILE_PATH"; then
    warnings+=("Missing ENTRYPOINT or CMD directive")
  fi

  local status="success"
  if [[ ${#issues[@]} -gt 0 ]]; then
    status="error"
  fi

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    local issues_json="[]"
    if [[ ${#issues[@]} -gt 0 ]]; then
      issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
    fi

    local warnings_json="[]"
    if [[ ${#warnings[@]} -gt 0 ]]; then
      warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
    fi

    local data
    data=$(cat <<EOF
{
  "issues": $issues_json,
  "warnings": $warnings_json,
  "issue_count": ${#issues[@]},
  "warning_count": ${#warnings[@]}
}
EOF
)

    local message="Dockerfile validation passed"
    if [[ ${#issues[@]} -gt 0 ]]; then
      message="Dockerfile validation failed with ${#issues[@]} issue(s)"
    elif [[ ${#warnings[@]} -gt 0 ]]; then
      message="Dockerfile validation passed with ${#warnings[@]} warning(s)"
    fi

    SECTION="validate"
    log_json "{\"status\":\"$status\",\"section\":\"validate\",\"next_action\":\"$(map_status_to_action "$status")\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\",\"data\":$data}"
  else
    raw_output "info" "Validating Dockerfile..."

    if [[ ${#issues[@]} -gt 0 ]]; then
      raw_output "error" "Validation failed with ${#issues[@]} issue(s):"
      for issue in "${issues[@]}"; do
        echo "  - $issue"
      done
    else
      raw_output "success" "Validation passed"
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
      raw_output "warn" "${#warnings[@]} warning(s):"
      for warning in "${warnings[@]}"; do
        echo "  - $warning"
      done
    fi
  fi

  return $(( ${#issues[@]} > 0 ? 1 : 0 ))
}

#######################################
# Main Execution
#######################################

main() {
  case "$SECTION" in
    full)
      # For --full with --json, suppress individual outputs and only show final result
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Run all sections silently
        detect_project_type >/dev/null 2>&1
        generate_dockerfile >/dev/null 2>&1

        # Temporarily switch to raw mode to get validation exit code
        local old_mode="$OUTPUT_MODE"
        OUTPUT_MODE="raw"
        local validation_output
        validation_output=$(validate_dockerfile 2>&1)
        local validation_exit=$?
        OUTPUT_MODE="$old_mode"

        # Determine status
        local val_status="success"
        if [[ $validation_exit -ne 0 ]]; then
          val_status="error"
        fi

        # Build comprehensive final output
        local final_data
        final_data=$(cat <<EOF
{
  "project_type": "${DETECTED_PROJECT_TYPE:-unknown}",
  "dockerfile_path": "$DOCKERFILE_PATH",
  "base_image": "${DETECTED_BASE_IMAGE:-unknown}",
  "issues": [],
  "warnings": [],
  "issue_count": 0,
  "warning_count": 0
}
EOF
)

        local message="Dockerfile generated and validated successfully"
        if [[ "$val_status" == "error" ]]; then
          message="Dockerfile generated but validation failed"
        fi

        SECTION="full"
        log_json "{\"status\":\"$val_status\",\"section\":\"full\",\"next_action\":\"$(map_status_to_action "$val_status")\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\",\"data\":$final_data}"
      else
        detect_project_type
        generate_dockerfile
        validate_dockerfile
      fi
      ;;
    detect)
      detect_project_type
      ;;
    generate)
      # Need project type from detect
      if [[ -z "${DETECTED_PROJECT_TYPE:-}" ]]; then
        detect_project_type >/dev/null 2>&1
      fi
      generate_dockerfile
      ;;
    validate)
      validate_dockerfile
      ;;
    *)
      if [[ "$OUTPUT_MODE" == "json" ]]; then
        exit_with_json "error" "Unknown section: $SECTION"
      else
        raw_output "error" "Unknown section: $SECTION"
      fi
      exit 1
      ;;
  esac
}

main
