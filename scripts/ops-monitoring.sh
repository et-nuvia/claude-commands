#!/usr/bin/env bash
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$_SD}"
# macOS/BSD sed compatibility (PLATFORM axis — see lib/platform.sh)
source "${SCRIPT_DIR}/lib/platform.sh"
if env_is_darwin; then
    sedi() { sed -i '' "$@"; }
else
    sedi() { sed -i "$@"; }
fi
# ops-monitoring.sh - Configure monitoring stack for services
#
# Usage:
#   ops-monitoring.sh --json --full           # Complete workflow (JSON)
#   ops-monitoring.sh --json --detect         # Run detection section only
#   ops-monitoring.sh --json --configure      # Run configuration section only
#   ops-monitoring.sh --raw --<section>       # Verbose output for debugging
#
# Sections:
#   --detect       Detect monitoring stack and services
#   --configure    Configure Prometheus, Grafana, and alerts
#   --verify       Verify monitoring is working
#
# Output modes:
#   --json         Structured JSON output (default)
#   --raw          Verbose debugging output

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date -Iseconds)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/yaml.sh"

SECTION="ops-monitoring"
map_status_to_action() {
    case "$1" in
        ready_for_input|ready_for_configuration) echo "confirm_action" ;;
        success) echo "display_summary" ;;
        *) _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Default values
OUTPUT_MODE="json"
SECTIONS=()
# Set by --service-name/--service-type/--monitoring-stack, or inherited from the
# environment if the caller exported them.
SERVICE_NAME="${SERVICE_NAME:-}"
SERVICE_TYPE="${SERVICE_TYPE:-}"
MONITORING_STACK="${MONITORING_STACK:-}"

# ============================================================================
# Section: Detect Monitoring Stack and Services
# ============================================================================

section_detect() {
    log "Detecting monitoring stack and services..."

    # Detect existing monitoring infrastructure
    local monitoring_stack="none"
    local monitoring_files=()

    if [[ -f "infrastructure/terraform/monitoring.tf" ]]; then
        monitoring_stack="terraform"
        monitoring_files+=("infrastructure/terraform/monitoring.tf")
    fi

    if [[ -f "infrastructure/ansible/playbooks/monitoring.yml" ]]; then
        monitoring_stack="ansible"
        monitoring_files+=("infrastructure/ansible/playbooks/monitoring.yml")
    fi

    if [[ -f "docker-compose.yml" ]] && grep -q "prometheus\|grafana" docker-compose.yml 2>/dev/null; then
        monitoring_stack="docker-compose"
        monitoring_files+=("docker-compose.yml")
    fi

    # Detect services to monitor
    local services=()

    if [[ -f "docker-compose.yml" ]]; then
        if command -v yq &>/dev/null; then
            mapfile -t services < <(yaml_get '.services | keys | .[]' docker-compose.yml)
        else
            # Fallback: grep-based service detection
            mapfile -t services < <(grep -E "^  [a-zA-Z0-9_-]+:" docker-compose.yml | sed 's/://' | xargs)
        fi
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local services_json="[]"
        if [[ ${#services[@]} -gt 0 ]]; then
            services_json="$(printf '%s\n' "${services[@]}" | jq -R . | jq -s .)"
        fi

        local files_json="[]"
        if [[ ${#monitoring_files[@]} -gt 0 ]]; then
            files_json="$(printf '%s\n' "${monitoring_files[@]}" | jq -R . | jq -s .)"
        fi

        log_json "$(cat <<JEOF
{
  "status": "ready_for_input",
  "next_action": "$(map_status_to_action "ready_for_input")",
  "section": "${SECTION}",
  "message": "Monitoring stack and services detected",
  "monitoring_stack": "$monitoring_stack",
  "monitoring_files": $files_json,
  "services": $services_json,
  "service_count": ${#services[@]},
  "timestamp": "$(date -Iseconds)"
}
JEOF
)"
    else
        echo "Monitoring Stack Detection"
        echo "═══════════════════════════════════════"
        echo ""
        echo "Stack detected: $monitoring_stack"
        echo ""
        if [[ ${#monitoring_files[@]} -gt 0 ]]; then
            echo "Monitoring infrastructure files:"
            printf '  - %s\n' "${monitoring_files[@]}"
            echo ""
        fi
        echo "Services available for monitoring:"
        if [[ ${#services[@]} -eq 0 ]]; then
            echo "  (none detected)"
        else
            printf '  - %s\n' "${services[@]}"
        fi
        echo ""
    fi
}

# ============================================================================
# Section: Configure Monitoring
# ============================================================================

section_configure() {
    log "Configuring monitoring..."

    # This section requires user input (service name, type, stack preference)
    # Return a status indicating that LLM should gather this info

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        log_json "$(cat <<JEOF
{
  "status": "ready_for_configuration",
  "next_action": "$(map_status_to_action "ready_for_configuration")",
  "section": "${SECTION}",
  "message": "Ready to configure monitoring",
  "next_steps": ["Select monitoring stack (Prometheus+Grafana, CloudWatch, etc.)", "Choose service to monitor", "Define service type (API, worker, database, etc.)", "Generate configuration files"],
  "required_inputs": ["monitoring_stack", "service_name", "service_type"],
  "timestamp": "$(date -Iseconds)"
}
JEOF
)"
    else
        echo "Monitoring Configuration"
        echo "═══════════════════════════════════════"
        echo ""
        echo "Required inputs:"
        echo "  1. Monitoring stack (Prometheus+Grafana, CloudWatch, GCP, Azure, Datadog)"
        echo "  2. Service name"
        echo "  3. Service type (web_api, worker, database, queue, custom)"
        echo ""
        echo "This section should be called after gathering these inputs."
        echo ""
    fi
}

generate_configs() {
    local service_name="$1"
    local service_type="$2"
    local stack="$3"

    log "Generating configs for service=$service_name, type=$service_type, stack=$stack"

    # Create directories
    mkdir -p infrastructure/monitoring/prometheus
    mkdir -p infrastructure/monitoring/prometheus/alerts
    mkdir -p infrastructure/monitoring/grafana/dashboards
    mkdir -p docs/monitoring

    local created_files=()

    # Generate Prometheus config
    cat > "infrastructure/monitoring/prometheus/${service_name}.yml" <<EOF
# Prometheus scrape config for $service_name

scrape_configs:
  - job_name: '${service_name}'
    scrape_interval: 15s
    static_configs:
      - targets: ['${service_name}:9090']
        labels:
          environment: '{{ env }}'
          service: '${service_name}'

    # Metric relabeling
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'go_.*'
        action: drop  # Drop Go runtime metrics if not needed
EOF
    created_files+=("infrastructure/monitoring/prometheus/${service_name}.yml")

    # Generate Grafana dashboard
    cat > "infrastructure/monitoring/grafana/dashboards/${service_name}.json" <<'EOF'
{
  "dashboard": {
    "title": "${SERVICE_NAME} Monitoring",
    "tags": ["${SERVICE_NAME}", "generated"],
    "timezone": "browser",
    "panels": [
      {
        "title": "Request Rate",
        "targets": [{
          "expr": "rate(http_requests_total{service=\"${SERVICE_NAME}\"}[5m])"
        }],
        "type": "graph"
      },
      {
        "title": "Error Rate",
        "targets": [{
          "expr": "rate(http_requests_total{service=\"${SERVICE_NAME}\",status=~\"5..\"}[5m])"
        }],
        "type": "graph"
      },
      {
        "title": "Response Time (p95)",
        "targets": [{
          "expr": "histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{service=\"${SERVICE_NAME}\"}[5m]))"
        }],
        "type": "graph"
      },
      {
        "title": "CPU Usage",
        "targets": [{
          "expr": "rate(process_cpu_seconds_total{service=\"${SERVICE_NAME}\"}[5m]) * 100"
        }],
        "type": "graph"
      },
      {
        "title": "Memory Usage",
        "targets": [{
          "expr": "process_resident_memory_bytes{service=\"${SERVICE_NAME}\"} / 1024 / 1024"
        }],
        "type": "graph"
      }
    ]
  }
}
EOF
    # Replace placeholder
    sedi "s/\${SERVICE_NAME}/${service_name}/g" "infrastructure/monitoring/grafana/dashboards/${service_name}.json"
    created_files+=("infrastructure/monitoring/grafana/dashboards/${service_name}.json")

    # Generate alert rules
    cat > "infrastructure/monitoring/prometheus/alerts/${service_name}.yml" <<EOF
groups:
  - name: ${service_name}_alerts
    interval: 30s
    rules:
      # High error rate
      - alert: HighErrorRate
        expr: |
          rate(http_requests_total{service="${service_name}",status=~"5.."}[5m])
          / rate(http_requests_total{service="${service_name}"}[5m])
          > 0.05
        for: 5m
        labels:
          severity: warning
          service: ${service_name}
        annotations:
          summary: "High error rate on ${service_name}"
          description: "Error rate is {{ \$value | humanizePercentage }}"

      # Service down
      - alert: ServiceDown
        expr: up{service="${service_name}"} == 0
        for: 1m
        labels:
          severity: critical
          service: ${service_name}
        annotations:
          summary: "${service_name} is down"
          description: "Service has been down for more than 1 minute"

      # High latency
      - alert: HighLatency
        expr: |
          histogram_quantile(0.95,
            rate(http_request_duration_seconds_bucket{service="${service_name}"}[5m])
          ) > 1.0
        for: 5m
        labels:
          severity: warning
          service: ${service_name}
        annotations:
          summary: "High latency on ${service_name}"
          description: "P95 latency is {{ \$value }}s"

      # High memory usage
      - alert: HighMemoryUsage
        expr: |
          process_resident_memory_bytes{service="${service_name}"}
          / on(instance) node_memory_MemTotal_bytes
          > 0.9
        for: 5m
        labels:
          severity: warning
          service: ${service_name}
        annotations:
          summary: "High memory usage on ${service_name}"
          description: "Memory usage is {{ \$value | humanizePercentage }}"
EOF
    created_files+=("infrastructure/monitoring/prometheus/alerts/${service_name}.yml")

    # Generate documentation
    cat > "docs/monitoring/${service_name}.md" <<EOF
# ${service_name} Monitoring

**Service**: ${service_name}
**Monitoring Stack**: ${stack}
**Configured**: $(date -Iseconds)

## Metrics Collected

### System Metrics
- CPU usage
- Memory usage
- Disk I/O
- Network I/O

### Application Metrics
- Request rate
- Error rate (5xx responses)
- Response time (p50, p95, p99)
- Active connections

## Dashboards

- **Main Dashboard**: http://grafana.example.com/d/${service_name}
- **Alerts**: http://grafana.example.com/alerting

## Alerts Configured

| Alert | Threshold | Severity |
|-------|-----------|----------|
| High Error Rate | > 5% for 5min | Warning |
| Service Down | Down for 1min | Critical |
| High Latency | P95 > 1s for 5min | Warning |
| High Memory | > 90% for 5min | Warning |

## Alert Destinations

- Slack: #alerts
- PagerDuty: ${service_name} service
- Email: team@example.com

## Runbooks

- [High Error Rate](../runbooks/${service_name}-high-errors.md)
- [Service Down](../runbooks/${service_name}-down.md)
- [High Latency](../runbooks/${service_name}-latency.md)

## Metrics Endpoints

- Prometheus: http://prometheus.example.com
- Service metrics: http://${service_name}:9090/metrics

## Configuration Files

- Prometheus scrape: \`infrastructure/monitoring/prometheus/${service_name}.yml\`
- Alert rules: \`infrastructure/monitoring/prometheus/alerts/${service_name}.yml\`
- Grafana dashboard: \`infrastructure/monitoring/grafana/dashboards/${service_name}.json\`

## Testing Alerts

\`\`\`bash
# Trigger high error rate
curl http://${service_name}/trigger-errors

# Check alert fired
curl http://prometheus.example.com/api/v1/alerts
\`\`\`

## Next Steps

1. Verify metrics are being collected
2. Test alerts trigger correctly
3. Create runbooks for each alert
4. Train team on dashboard usage
5. Set up alert escalation
EOF
    created_files+=("docs/monitoring/${service_name}.md")

    # Return created files
    printf '%s\n' "${created_files[@]}"
}

# ============================================================================
# Section: Verify Monitoring
# ============================================================================

section_verify() {
    log "Verifying monitoring configuration..."

    local service_name="${1:-}"
    if [[ -z "$service_name" ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            exit_with_json "error" "Service name required for verification" "Provide service_name parameter"
        else
            echo "Error: Service name required for verification"
        fi
        return 1
    fi

    # Check if Prometheus is accessible
    local prometheus_url="${PROMETHEUS_URL:-http://localhost:9090}"
    local prometheus_reachable=false

    if command -v curl &>/dev/null; then
        if curl -sf "${prometheus_url}/api/v1/status/config" &>/dev/null; then
            prometheus_reachable=true
        fi
    fi

    # Check if configuration files exist
    local config_exists=true
    local missing_files=()

    if [[ ! -f "infrastructure/monitoring/prometheus/${service_name}.yml" ]]; then
        config_exists=false
        missing_files+=("infrastructure/monitoring/prometheus/${service_name}.yml")
    fi

    if [[ ! -f "infrastructure/monitoring/prometheus/alerts/${service_name}.yml" ]]; then
        config_exists=false
        missing_files+=("infrastructure/monitoring/prometheus/alerts/${service_name}.yml")
    fi

    if [[ ! -f "infrastructure/monitoring/grafana/dashboards/${service_name}.json" ]]; then
        config_exists=false
        missing_files+=("infrastructure/monitoring/grafana/dashboards/${service_name}.json")
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        local missing_json="[]"
        if [[ ${#missing_files[@]} -gt 0 ]]; then
            missing_json="$(printf '%s\n' "${missing_files[@]}" | jq -R . | jq -s .)"
        fi

        if [[ "$config_exists" == "false" ]]; then
            exit_with_json "error" "Configuration files missing" "" \
                "\"missing_files\": $missing_json"
        else
            exit_with_json "success" "Monitoring configuration verified" "" \
                "\"prometheus_reachable\": $prometheus_reachable," \
                "\"prometheus_url\": \"$prometheus_url\"," \
                "\"config_files_present\": true," \
                "\"next_steps\": [\"Deploy configuration\", \"Verify metrics collection\", \"Test alerts\"]"
        fi
    else
        echo "Monitoring Verification"
        echo "═══════════════════════════════════════"
        echo ""
        echo "Service: $service_name"
        echo "Prometheus URL: $prometheus_url"
        echo "Prometheus reachable: $prometheus_reachable"
        echo ""
        if [[ "$config_exists" == "false" ]]; then
            echo "Missing configuration files:"
            printf '  - %s\n' "${missing_files[@]}"
        else
            echo "✓ All configuration files present"
            echo ""
            echo "Next steps:"
            echo "  1. Deploy configuration to monitoring stack"
            echo "  2. Verify Prometheus can scrape service metrics"
            echo "  3. Test alert firing"
        fi
        echo ""
    fi
}

# ============================================================================
# Full Workflow
# ============================================================================

run_full_workflow() {
    log "Running full monitoring setup workflow..."

    # Step 1: Detect
    section_detect

    # This is an interactive command that requires user input
    # We can't auto-flow through configuration without knowing:
    # - Which service to monitor
    # - What type of service it is
    # - Which monitoring stack to use

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        exit_with_json "ready_for_input" "Detection complete - user input required" "" \
            "\"next_steps\": [\"LLM should ask user which service to monitor\", \"LLM should ask service type\", \"LLM should call generate_configs with inputs\"]," \
            "\"required_for_configure\": [\"service_name\", \"service_type\", \"monitoring_stack\"]"
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                OUTPUT_MODE="json"
                shift
                ;;
            --raw)
                OUTPUT_MODE="raw"
                shift
                ;;
            --full)
                SECTIONS+=("full")
                shift
                ;;
            --detect)
                SECTIONS+=("detect")
                shift
                ;;
            --configure)
                SECTIONS+=("configure")
                shift
                ;;
            --verify)
                SECTIONS+=("verify")
                shift
                ;;
            --generate)
                # Special section for generating configs with provided params
                SECTIONS+=("generate")
                shift
                ;;
            # Parameters for --generate and --verify. Previously these were
            # only readable as pre-exported environment variables, so the
            # documented `--generate --service-name x --service-type y
            # --monitoring-stack z` call hit the catch-all below and exited 1.
            --service-name)
                SERVICE_NAME="$2"
                shift 2
                ;;
            --service-type)
                SERVICE_TYPE="$2"
                shift 2
                ;;
            --monitoring-stack)
                MONITORING_STACK="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    # Default to full workflow if no sections specified
    if [[ ${#SECTIONS[@]} -eq 0 ]]; then
        SECTIONS=("full")
    fi

    # Execute requested sections
    for section in "${SECTIONS[@]}"; do
        case "$section" in
            full)
                run_full_workflow
                ;;
            detect)
                section_detect
                ;;
            configure)
                section_configure
                ;;
            verify)
                section_verify "${SERVICE_NAME:-}"
                ;;
            generate)
                # Params come from --service-name/--service-type/--monitoring-stack,
                # falling back to same-named environment variables.
                if [[ -z "${SERVICE_NAME:-}" || -z "${SERVICE_TYPE:-}" || -z "${MONITORING_STACK:-}" ]]; then
                    exit_with_json "error" \
                        "--generate requires --service-name, --service-type, and --monitoring-stack" \
                        "Example: ops-monitoring.sh --json --generate --service-name api --service-type node --monitoring-stack prometheus"
                fi
                generate_configs "${SERVICE_NAME}" "${SERVICE_TYPE}" "${MONITORING_STACK}"
                ;;
            *)
                if [[ "$OUTPUT_MODE" == "json" ]]; then
                    exit_with_json "error" "Unknown section: $section"
                else
                    echo "Error: Unknown section: $section"
                fi
                exit 1
                ;;
        esac
    done
}

main "$@"
