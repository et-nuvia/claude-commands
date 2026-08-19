#!/usr/bin/env bash
# ci-lint-local.sh - Pre-push CI/Docker/Compose validation
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/ci-lint-local.sh [--json|--raw] [--full|--ci-only|--dockerfiles|--compose]
#
# Sections:
#   --ci-only:      Validate CI config syntax, shellcheck script blocks
#   --dockerfiles:  Check Dockerfile best practices
#   --compose:      Validate docker-compose.yml
#   --full:         All checks (default)
#
# Workflow:
#   1. LLM calls: ci-lint-local.sh --json --full
#   2. Returns issues list with categories
#   3. If issues found, fix before pushing

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
OUTPUT_MODE="json"
SECTION="full"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo -e "$@" >&2
    fi
}

# Accumulate issues as JSON array entries
ISSUES_JSON="["
ISSUES_COUNT=0
WARNINGS_COUNT=0
ERRORS_COUNT=0

add_issue() {
    local severity="$1"  # error | warning
    local category="$2"  # ci | dockerfile | compose
    local file="$3"
    local message="$4"

    message="${message//\"/\\\"}"
    file="${file//\"/\\\"}"

    if [[ $ISSUES_COUNT -gt 0 ]]; then
        ISSUES_JSON="${ISSUES_JSON}, "
    fi
    ISSUES_JSON="${ISSUES_JSON}{\"severity\": \"${severity}\", \"category\": \"${category}\", \"file\": \"${file}\", \"message\": \"${message}\"}"
    ISSUES_COUNT=$((ISSUES_COUNT + 1))

    if [[ "$severity" == "error" ]]; then
        ERRORS_COUNT=$((ERRORS_COUNT + 1))
    else
        WARNINGS_COUNT=$((WARNINGS_COUNT + 1))
    fi

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        local color="$YELLOW"
        [[ "$severity" == "error" ]] && color="$RED"
        echo -e "${color}[${severity}]${NC} ${category}: ${file} — ${message}" >&2
    fi
}

#------------------------------------------------------------------------------
# Section: CI Config Validation
#------------------------------------------------------------------------------

section_ci() {
    log "${BLUE}Checking CI configuration...${NC}"

    # GitLab CI
    if [[ -f ".gitlab-ci.yml" ]]; then
        log "  Found .gitlab-ci.yml"

        # Basic YAML syntax check
        if command -v python3 &>/dev/null; then
            if ! python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml'))" 2>/dev/null; then
                add_issue "error" "ci" ".gitlab-ci.yml" "Invalid YAML syntax"
            fi
        fi

        # Extract and shellcheck script blocks
        if command -v shellcheck &>/dev/null; then
            python3 -c "
import yaml, sys, tempfile, subprocess, os
with open('.gitlab-ci.yml') as f:
    ci = yaml.safe_load(f)
if not isinstance(ci, dict):
    sys.exit(0)
for job_name, job in ci.items():
    if not isinstance(job, dict):
        continue
    for key in ('script', 'before_script', 'after_script'):
        scripts = job.get(key, [])
        if isinstance(scripts, str):
            scripts = [scripts]
        if not scripts:
            continue
        combined = '\n'.join(scripts)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.sh', delete=False) as tmp:
            tmp.write('#!/bin/bash\n' + combined)
            tmp_path = tmp.name
        result = subprocess.run(['shellcheck', '-S', 'warning', tmp_path],
                              capture_output=True, text=True)
        os.unlink(tmp_path)
        if result.returncode != 0:
            for line in result.stdout.strip().split('\n'):
                if line.startswith('In ') or not line.strip():
                    continue
                print(f'{job_name}.{key}|{line}')
" 2>/dev/null | while IFS='|' read -r location msg; do
                add_issue "warning" "ci" ".gitlab-ci.yml" "${location}: ${msg}"
            done
        else
            log "  shellcheck not available, skipping script block analysis"
        fi
    fi

    # GitHub Actions
    local workflow_files
    workflow_files=$(find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null || true)

    if [[ -n "$workflow_files" ]]; then
        while IFS= read -r wf; do
            [[ -z "$wf" ]] && continue
            log "  Found workflow: $wf"

            if command -v python3 &>/dev/null; then
                if ! python3 -c "import yaml; yaml.safe_load(open('$wf'))" 2>/dev/null; then
                    add_issue "error" "ci" "$wf" "Invalid YAML syntax"
                fi
            fi
        done <<< "$workflow_files"
    fi

    if [[ ! -f ".gitlab-ci.yml" ]] && [[ -z "$workflow_files" ]]; then
        log "  No CI configuration found"
    fi
}

#------------------------------------------------------------------------------
# Section: Dockerfile Validation
#------------------------------------------------------------------------------

section_dockerfiles() {
    log "${BLUE}Checking Dockerfiles...${NC}"

    local dockerfiles
    dockerfiles=$(find . -name "Dockerfile" -o -name "Dockerfile.*" -o -name "*.dockerfile" 2>/dev/null | grep -v node_modules | grep -v .git || true)

    if [[ -z "$dockerfiles" ]]; then
        log "  No Dockerfiles found"
        return
    fi

    while IFS= read -r df; do
        [[ -z "$df" ]] && continue
        log "  Checking: $df"

        # Check for USER directive (security)
        if ! grep -q '^USER ' "$df"; then
            add_issue "warning" "dockerfile" "$df" "No USER directive — container runs as root"
        fi

        # Check for root user
        if grep -qE '^USER\s+(root|0)' "$df"; then
            add_issue "error" "dockerfile" "$df" "Explicitly runs as root user"
        fi

        # Check for privileged ports without USER
        if grep -qE 'EXPOSE\s+(80|443|[0-9]{1,3})\b' "$df"; then
            if ! grep -q '^USER ' "$df"; then
                add_issue "warning" "dockerfile" "$df" "Exposes privileged port without non-root USER"
            fi
        fi

        # Check COPY ordering (package files should come before source)
        local has_package_copy=false
        local has_source_copy_before_package=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^COPY.*\.(json|toml|lock|txt)[[:space:]] ]]; then
                has_package_copy=true
            elif [[ "$line" =~ ^COPY[[:space:]]+\. ]] && [[ "$has_package_copy" == "false" ]]; then
                has_source_copy_before_package=true
            fi
        done < "$df"

        if [[ "$has_source_copy_before_package" == "true" ]] && [[ "$has_package_copy" == "true" ]]; then
            add_issue "warning" "dockerfile" "$df" "COPY . before package files — breaks layer caching"
        fi

        # Check for latest tag
        if grep -qE '^FROM\s+\S+:latest' "$df"; then
            add_issue "warning" "dockerfile" "$df" "Uses :latest tag — pin a specific version"
        fi

    done <<< "$dockerfiles"
}

#------------------------------------------------------------------------------
# Section: Docker Compose Validation
#------------------------------------------------------------------------------

section_compose() {
    log "${BLUE}Checking docker-compose.yml...${NC}"

    if [[ ! -f "docker-compose.yml" ]]; then
        log "  No docker-compose.yml found"
        return
    fi

    # Syntax validation
    if ! docker compose config -q 2>/dev/null; then
        add_issue "error" "compose" "docker-compose.yml" "Invalid compose file syntax"
        return
    fi

    # Check for security hardening
    if command -v python3 &>/dev/null; then
        python3 -c "
import yaml, sys
with open('docker-compose.yml') as f:
    compose = yaml.safe_load(f)
services = compose.get('services', {})
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    # Check read_only
    if not svc.get('read_only', False):
        print(f'warning|compose|docker-compose.yml|Service {name}: missing read_only: true')
    # Check security_opt
    sec_opts = svc.get('security_opt', [])
    if 'no-new-privileges:true' not in sec_opts:
        print(f'warning|compose|docker-compose.yml|Service {name}: missing no-new-privileges:true')
    # Check healthcheck
    if 'healthcheck' not in svc and svc.get('build'):
        print(f'warning|compose|docker-compose.yml|Service {name}: no healthcheck defined')
    # Check privileged
    if svc.get('privileged', False):
        print(f'error|compose|docker-compose.yml|Service {name}: privileged mode enabled')
" 2>/dev/null | while IFS='|' read -r severity category file message; do
            add_issue "$severity" "$category" "$file" "$message"
        done
    fi
}

#------------------------------------------------------------------------------
# Audit documentation drift
#
# /docker-audit and /pipeline-audit run on every project, and LLMs build new
# projects from the wiki tables rather than from the audit scripts. If a weight
# changed in a script without regenerating the published tables, the standard
# every future project is built against is silently wrong — so this is an error,
# not a warning.
#------------------------------------------------------------------------------

section_audit_specs() {
    local sync_script="${HOME}/.claude/scripts/audit-spec-sync.py"
    [[ -x "$sync_script" ]] || return 0

    local drift
    if ! drift=$("$sync_script" --check 2>&1); then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                *drifted*|*no_markers*|*unknown_block*|*missing*|*error*)
                    add_issue "error" "audit-spec" "audit-spec-sync" \
                        "Audit docs out of sync with script: ${line}. Run: audit-spec-sync.py --write"
                    ;;
            esac
        done <<< "$drift"
    fi
}

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --ci-only) SECTION="ci"; shift ;;
        --dockerfiles) SECTION="dockerfiles"; shift ;;
        --compose) SECTION="compose"; shift ;;
        -h|--help)
            echo "Usage: $0 [--json|--raw] [--full|--ci-only|--dockerfiles|--compose]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

case "$SECTION" in
    full)
        section_ci
        section_dockerfiles
        section_compose
        section_audit_specs
        ;;
    ci) section_ci ;;
    dockerfiles) section_dockerfiles ;;
    compose) section_compose ;;
esac

ISSUES_JSON="${ISSUES_JSON}]"

# Output
if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo ""
    if [[ $ISSUES_COUNT -eq 0 ]]; then
        echo -e "${GREEN}All checks passed — safe to push${NC}"
    else
        echo -e "${RED}Found $ERRORS_COUNT errors and $WARNINGS_COUNT warnings${NC}"
    fi
else
    local_next_action="safe_to_push"
    local_message="All checks passed"
    local_status="success"

    if [[ $ERRORS_COUNT -gt 0 ]]; then
        local_next_action="fix_before_push"
        local_message="$ERRORS_COUNT errors and $WARNINGS_COUNT warnings found"
        local_status="failure"
    elif [[ $WARNINGS_COUNT -gt 0 ]]; then
        local_next_action="safe_to_push"
        local_message="$WARNINGS_COUNT warnings found (non-blocking)"
        local_status="success"
    fi

    cat <<EOF
{
  "status": "$local_status",
  "next_action": "$local_next_action",
  "message": "$local_message",
  "section": "$SECTION",
  "errors": $ERRORS_COUNT,
  "warnings": $WARNINGS_COUNT,
  "issues": $ISSUES_JSON,
  "timestamp": "$(date -Iseconds)"
}
EOF
fi
