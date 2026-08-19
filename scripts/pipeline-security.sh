#!/usr/bin/env bash
set -euo pipefail

# Pipeline Security Setup Script
# Adds comprehensive security scanning to CI/CD pipelines
# Follows standard command-script integration pattern

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

SECTION="pipeline-security"
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        *) _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

# macOS/BSD sed compatibility (PLATFORM axis — see lib/platform.sh)
source "${HOME}/.claude/scripts/lib/platform.sh"
if env_is_darwin; then
    sedi() { sed -i '' "$@"; }
else
    sedi() { sed -i "$@"; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════

OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, detect, check, configure, policy

# Available scanners
SCANNERS=()

# ══════════════════════════════════════════════════════════════════════════════
# Argument Parsing
# ══════════════════════════════════════════════════════════════════════════════

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Add security scanning to CI/CD pipeline.

OPTIONS:
    --json              JSON output (default)
    --raw               Raw/verbose output
    --full              Run all sections (default)
    --detect            Detect platform and pipeline only
    --check             Check current security scanning only
    --configure         Generate security configuration only
    --policy            Create security policy only
    --scanners LIST     Comma-separated scanners (trivy,semgrep,gitleaks,snyk,owasp)
    --help              Show this help

EXAMPLES:
    # Full setup with all scanners (interactive)
    $(basename "$0") --json --full

    # Add specific scanners
    $(basename "$0") --json --configure --scanners trivy,semgrep,gitleaks

    # Check what's already configured
    $(basename "$0") --json --check

    # Detect platform only
    $(basename "$0") --json --detect
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --detect) SECTION="detect"; shift ;;
        --check) SECTION="check"; shift ;;
        --configure) SECTION="configure"; shift ;;
        --policy) SECTION="policy"; shift ;;
        --scanners)
            IFS=',' read -ra SCANNERS <<< "$2"
            shift 2
            ;;
        --help) show_usage; exit 0 ;;
        *) echo "Unknown option: $1"; show_usage; exit 1 ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════════
# Output Functions (delegating to output-framework.sh)
# ══════════════════════════════════════════════════════════════════════════════

json_response() {
    local status="$1"
    local section="$2"
    local message="$3"
    shift 3

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log_json "$(cat << EOF
{
  "status": "$status",
  "next_action": "$(map_status_to_action "$status")",
  "section": "$section",
  "message": "$message",
  "timestamp": "$timestamp"$([ $# -gt 0 ] && echo ",$*" || echo "")
}
EOF
)"
}

json_error() {
    local section="$1"
    local message="$2"
    local details="${3:-}"

    json_response "error" "$section" "$message" \
        "$([ -n "$details" ] && echo "\"details\": \"$details\"" || echo "")"
}

json_success() {
    local section="$1"
    local message="$2"
    shift 2

    json_response "success" "$section" "$message" "$@"
}

raw_log() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo "$@" >&2
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Section: Detect Platform
# ══════════════════════════════════════════════════════════════════════════════

detect_platform() {
    raw_log "Detecting CI/CD platform..."

    local platform=""
    local pipeline_file=""

    # Check for GitHub Actions
    if [[ -f "${PROJECT_ROOT}/.github/workflows/ci-cd.yml" ]]; then
        platform="github"
        pipeline_file=".github/workflows/ci-cd.yml"
    elif [[ -f "${PROJECT_ROOT}/.github/workflows/main.yml" ]]; then
        platform="github"
        pipeline_file=".github/workflows/main.yml"
    elif [[ -d "${PROJECT_ROOT}/.github/workflows" ]]; then
        local first_workflow=$(find "${PROJECT_ROOT}/.github/workflows" -name "*.yml" -o -name "*.yaml" | head -1)
        if [[ -n "$first_workflow" ]]; then
            platform="github"
            pipeline_file="${first_workflow#${PROJECT_ROOT}/}"
        fi
    fi

    # Check for GitLab CI
    if [[ -z "$platform" ]] && [[ -f "${PROJECT_ROOT}/.gitlab-ci.yml" ]]; then
        platform="gitlab"
        pipeline_file=".gitlab-ci.yml"
    fi

    if [[ -z "$platform" ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            json_error "detect" "No CI/CD pipeline found" \
                "Run /create-pipeline first to create a pipeline configuration"
        else
            echo "❌ No CI/CD pipeline found"
            echo "Run /create-pipeline first to create a pipeline configuration"
        fi
        exit 1
    fi

    raw_log "Platform: $platform"
    raw_log "Pipeline file: $pipeline_file"

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo "$platform|$pipeline_file"  # Return for next section
    else
        echo "Platform: $platform"
        echo "Pipeline: $pipeline_file"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Section: Check Current Security
# ══════════════════════════════════════════════════════════════════════════════

check_security() {
    local platform="$1"
    local pipeline_file="$2"

    raw_log "Checking existing security scans..."

    local has_trivy=$(grep -q "trivy" "${PROJECT_ROOT}/${pipeline_file}" && echo "true" || echo "false")
    local has_semgrep=$(grep -q "semgrep" "${PROJECT_ROOT}/${pipeline_file}" && echo "true" || echo "false")
    local has_gitleaks=$(grep -q "gitleaks" "${PROJECT_ROOT}/${pipeline_file}" && echo "true" || echo "false")
    local has_snyk=$(grep -q "snyk" "${PROJECT_ROOT}/${pipeline_file}" && echo "true" || echo "false")
    local has_owasp=$(grep -q "owasp\|dependency-check" "${PROJECT_ROOT}/${pipeline_file}" && echo "true" || echo "false")

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat << EOF
{
  "platform": "$platform",
  "pipeline_file": "$pipeline_file",
  "current_scanners": {
    "trivy": $has_trivy,
    "semgrep": $has_semgrep,
    "gitleaks": $has_gitleaks,
    "snyk": $has_snyk,
    "owasp": $has_owasp
  }
}
EOF
    else
        echo "Current security tools:"
        echo "  Trivy: $(if [[ "$has_trivy" == "true" ]]; then echo "✓"; else echo "✗"; fi)"
        echo "  Semgrep: $(if [[ "$has_semgrep" == "true" ]]; then echo "✓"; else echo "✗"; fi)"
        echo "  Gitleaks: $(if [[ "$has_gitleaks" == "true" ]]; then echo "✓"; else echo "✗"; fi)"
        echo "  Snyk: $(if [[ "$has_snyk" == "true" ]]; then echo "✓"; else echo "✗"; fi)"
        echo "  OWASP: $(if [[ "$has_owasp" == "true" ]]; then echo "✓"; else echo "✗"; fi)"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Section: Configure Security Scanning
# ══════════════════════════════════════════════════════════════════════════════

configure_github_security() {
    local add_trivy="${1:-false}"
    local add_semgrep="${2:-false}"
    local add_gitleaks="${3:-false}"
    local add_snyk="${4:-false}"

    local security_file="${PROJECT_ROOT}/.github/workflows/security.yml"

    cat > "$security_file" << 'EOF'
name: Security Scanning

on:
  push:
    branches: [main, dev]
  pull_request:
    branches: [main, dev]
  schedule:
    - cron: '0 0 * * 0'  # Weekly on Sunday

jobs:
EOF

    # Add Trivy job
    if [[ "$add_trivy" == "true" ]]; then
        cat >> "$security_file" << 'EOF'
  trivy:
    name: Trivy Vulnerability Scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run Trivy filesystem scan
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'fs'
          scan-ref: '.'
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'

      - name: Upload Trivy results
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: 'trivy-results.sarif'

      - name: Run Trivy image scan
        if: hashFiles('Dockerfile') != ''
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'config'
          scan-ref: 'Dockerfile'

EOF
    fi

    # Add Semgrep job
    if [[ "$add_semgrep" == "true" ]]; then
        cat >> "$security_file" << 'EOF'
  semgrep:
    name: Semgrep SAST
    runs-on: ubuntu-latest
    container:
      image: returntocorp/semgrep
    steps:
      - uses: actions/checkout@v4

      - name: Run Semgrep
        run: semgrep scan --config auto --sarif --output semgrep.sarif

      - name: Upload Semgrep results
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: 'semgrep.sarif'

EOF
    fi

    # Add Gitleaks job
    if [[ "$add_gitleaks" == "true" ]]; then
        cat >> "$security_file" << 'EOF'
  gitleaks:
    name: Gitleaks Secret Scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run Gitleaks
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

EOF
    fi

    echo "$security_file"
}

configure_gitlab_security() {
    local pipeline_file="$1"
    local add_trivy="${2:-false}"
    local add_semgrep="${3:-false}"
    local add_gitleaks="${4:-false}"

    local full_path="${PROJECT_ROOT}/${pipeline_file}"

    # Add security stage if not present
    if ! grep -q "stages:" "$full_path"; then
        sedi '1i stages:\n  - security' "$full_path"
    elif ! grep -q "security" "$full_path"; then
        sedi '/stages:/a\  - security' "$full_path"
    fi

    # Add security jobs
    cat >> "$full_path" << 'EOF'

# Security Scanning
EOF

    if [[ "$add_trivy" == "true" ]]; then
        cat >> "$full_path" << 'EOF'

trivy:
  stage: security
  image: aquasec/trivy:latest
  script:
    - trivy fs --exit-code 0 --severity HIGH,CRITICAL .
    - trivy fs --format json --output trivy-report.json .
  artifacts:
    reports:
      container_scanning: trivy-report.json
  only:
    - merge_requests
    - main
    - dev

EOF
    fi

    if [[ "$add_semgrep" == "true" ]]; then
        cat >> "$full_path" << 'EOF'

semgrep:
  stage: security
  image: returntocorp/semgrep
  script:
    - semgrep scan --config auto --json --output semgrep-report.json
  artifacts:
    reports:
      sast: semgrep-report.json
  only:
    - merge_requests
    - main
    - dev

EOF
    fi

    if [[ "$add_gitleaks" == "true" ]]; then
        cat >> "$full_path" << 'EOF'

gitleaks:
  stage: security
  image: zricethezav/gitleaks:latest
  script:
    - gitleaks detect --source . --report-path gitleaks-report.json
  artifacts:
    reports:
      secret_detection: gitleaks-report.json
  allow_failure: false
  only:
    - merge_requests
    - main
    - dev

EOF
    fi

    echo "$pipeline_file"
}

configure_security() {
    local platform="$1"
    local pipeline_file="$2"

    raw_log "Configuring security scanning..."

    # Determine which scanners to add
    local add_trivy="false"
    local add_semgrep="false"
    local add_gitleaks="false"
    local add_snyk="false"

    # If scanners specified via --scanners, use those
    if [[ ${#SCANNERS[@]} -gt 0 ]]; then
        for scanner in "${SCANNERS[@]}"; do
            case "$scanner" in
                trivy) add_trivy="true" ;;
                semgrep) add_semgrep="true" ;;
                gitleaks) add_gitleaks="true" ;;
                snyk) add_snyk="true" ;;
            esac
        done
    else
        # Default: add all recommended scanners
        add_trivy="true"
        add_semgrep="true"
        add_gitleaks="true"
    fi

    local files_created=()

    if [[ "$platform" == "github" ]]; then
        local security_file=$(configure_github_security "$add_trivy" "$add_semgrep" "$add_gitleaks" "$add_snyk")
        files_created+=("$security_file")
    else
        local updated_file=$(configure_gitlab_security "$pipeline_file" "$add_trivy" "$add_semgrep" "$add_gitleaks")
        files_created+=("${PROJECT_ROOT}/${updated_file}")
    fi

    # Create .trivyignore if needed
    if [[ "$add_trivy" == "true" ]] && [[ ! -f "${PROJECT_ROOT}/.trivyignore" ]]; then
        cat > "${PROJECT_ROOT}/.trivyignore" << 'EOF'
# Trivy Ignore File
# Add CVEs that don't apply to your project

# Example:
# CVE-2021-12345  # Not applicable: we don't use the vulnerable function

EOF
        files_created+=("${PROJECT_ROOT}/.trivyignore")
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local files_json=$(printf ',"%s"' "${files_created[@]}")
        files_json="[${files_json:1}]"

        echo "$files_json"  # Return for next section
    else
        echo "✓ Security scanning configured"
        echo "Files created/updated:"
        for file in "${files_created[@]}"; do
            echo "  - ${file#${PROJECT_ROOT}/}"
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Section: Create Security Policy
# ══════════════════════════════════════════════════════════════════════════════

create_security_policy() {
    raw_log "Creating security policy..."

    local security_policy="${PROJECT_ROOT}/docs/SECURITY.md"

    mkdir -p "${PROJECT_ROOT}/docs"

    cat > "$security_policy" << 'EOF'
# Security Policy

## Vulnerability Scanning

This project uses automated security scanning in CI/CD:

- **Trivy**: Container and filesystem vulnerability scanning
- **Semgrep**: Static application security testing (SAST)
- **Gitleaks**: Secret detection
- **Dependency scanning**: Checks for vulnerable dependencies

## Scan Schedule

- **On every commit**: Full security scan
- **Weekly**: Scheduled deep scan (Sundays)
- **On PR/MR**: Security gate before merge

## Severity Levels

- **CRITICAL**: Must fix immediately - blocks deployment
- **HIGH**: Fix within 7 days
- **MEDIUM**: Fix within 30 days
- **LOW**: Fix when convenient

## Handling Vulnerabilities

1. **Review**: Check if vulnerability applies to your usage
2. **Update**: Upgrade affected dependency if possible
3. **Mitigate**: Apply workaround if upgrade not available
4. **Exception**: Document why vulnerability doesn't apply (if true)

## False Positives

To suppress false positives:

### Trivy
Create `.trivyignore`:
```
CVE-2021-12345  # Reason: Not applicable because...
```

### Semgrep
Add inline comment:
```python
# nosemgrep: rule-id
vulnerable_code()
```

### Gitleaks
Create `.gitleaksignore`:
```
path/to/file:secret-hash
```

## Reporting Security Issues

**DO NOT** open public issues for security vulnerabilities.

Contact: security@example.com
EOF

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo "$security_policy"  # Return for final output
    else
        echo "✓ Created security policy: docs/SECURITY.md"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main Execution
# ══════════════════════════════════════════════════════════════════════════════

main() {
    case "$SECTION" in
        detect)
            detect_platform
            ;;

        check)
            local detect_output=$(detect_platform)
            if [[ "$OUTPUT_MODE" == "json" ]]; then
                IFS='|' read -r platform pipeline_file <<< "$detect_output"
                check_security "$platform" "$pipeline_file"
            fi
            ;;

        configure)
            local detect_output=$(detect_platform)
            if [[ "$OUTPUT_MODE" == "json" ]]; then
                IFS='|' read -r platform pipeline_file <<< "$detect_output"
                configure_security "$platform" "$pipeline_file"
            fi
            ;;

        policy)
            create_security_policy
            ;;

        full)
            # Run all sections
            local detect_output=$(detect_platform)

            if [[ "$OUTPUT_MODE" == "json" ]]; then
                IFS='|' read -r platform pipeline_file <<< "$detect_output"

                # Get scanner configuration
                local files_created=$(configure_security "$platform" "$pipeline_file")

                # Create policy
                local policy_file=$(create_security_policy)

                # Build final JSON response
                local scanners_json=""
                [[ " ${SCANNERS[@]} " =~ " trivy " ]] || [[ ${#SCANNERS[@]} -eq 0 ]] && scanners_json+='"trivy",'
                [[ " ${SCANNERS[@]} " =~ " semgrep " ]] || [[ ${#SCANNERS[@]} -eq 0 ]] && scanners_json+='"semgrep",'
                [[ " ${SCANNERS[@]} " =~ " gitleaks " ]] || [[ ${#SCANNERS[@]} -eq 0 ]] && scanners_json+='"gitleaks",'
                scanners_json="[${scanners_json%,}]"

                json_success "full" "Security scanning configured" \
                    "\"platform\": \"$platform\"" \
                    "\"pipeline_file\": \"$pipeline_file\"" \
                    "\"scanners_added\": $scanners_json" \
                    "\"files_created\": $files_created" \
                    "\"policy_file\": \"${policy_file#${PROJECT_ROOT}/}\""
            else
                echo ""
                echo "Security Scanning Added"
                echo "════════════════════════════════════════"
                echo ""
                echo "Next steps:"
                echo "1. Commit security configuration"
                echo "2. Push and verify scans run"
                echo "3. Review any findings"
                echo "4. Set up notifications for critical issues"
            fi
            ;;
    esac
}

main
