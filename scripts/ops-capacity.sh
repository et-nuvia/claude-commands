#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Capacity forecasting with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/ops-capacity.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --collect:   Collect current resource usage metrics
#   --analyze:   Analyze growth trends and forecast future load
#   --report:    Generate capacity forecast report
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: ops-capacity.sh --json --full
#   2. Script returns current metrics and forecast data as JSON
#   3. If more detail needed: ops-capacity.sh --raw --analyze

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, collect, analyze, report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)        echo "display_summary" ;;
        input_required) echo "gather_user_input" ;;
        error)          echo "fix_error" ;;
        *)              echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Monitoring system choice
MONITOR_CHOICE=""
CURRENT_LOAD=""
GROWTH_RATE=""
FORECAST_MONTHS=""

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Collect Current Metrics
section_collect() {
    log "${BLUE}Collecting Current Resource Usage${NC}"

    # Prompt for monitoring system choice
    if [[ -z "$MONITOR_CHOICE" ]]; then
        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            echo -e "\nMonitoring system:" >&2
            echo "1. Prometheus" >&2
            echo "2. CloudWatch (AWS)" >&2
            echo "3. Manual input" >&2
            read -p "Choice (1-3): " MONITOR_CHOICE
        else
            # In JSON mode, need input from LLM
            local json=$(cat <<EOF
{
  "status": "input_required",
  "next_action": "gather_user_input",
  "section": "collect",
  "message": "Monitoring system selection required",
  "input_prompt": "Select monitoring system",
  "options": ["Prometheus", "CloudWatch (AWS)", "Manual input"],
  "next_steps": [
    "Provide monitoring system choice (1-3)",
    "Then continue: ops-capacity.sh --json --collect --monitor <choice>"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi
    fi

    log "${GREEN}✓${NC} Monitoring system selected: $MONITOR_CHOICE"

    # Collect current load metrics
    if [[ -z "$CURRENT_LOAD" ]]; then
        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            read -p "Current users/requests per day: " CURRENT_LOAD
        else
            # In JSON mode, need input from LLM
            local json=$(cat <<EOF
{
  "status": "input_required",
  "next_action": "gather_user_input",
  "section": "collect",
  "message": "Current load data required",
  "monitoring_system": "$MONITOR_CHOICE",
  "input_required": ["current_load", "growth_rate", "forecast_months"],
  "next_steps": [
    "Provide current load (users/requests per day)",
    "Provide growth rate (% per month)",
    "Provide forecast period (months)",
    "Then continue with --analyze"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi
    fi

    log "${GREEN}✓${NC} Current load: $CURRENT_LOAD/day"

    # If running only this section, return now
    if [[ "$SECTION" == "collect" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "collect",
  "message": "Metrics collection complete",
  "monitoring_system": "$MONITOR_CHOICE",
  "current_load": "$CURRENT_LOAD",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Section 2: Analyze Growth Trends
section_analyze() {
    log "${BLUE}Analyzing Growth Trends${NC}"

    # Collect growth parameters if not provided
    if [[ -z "$GROWTH_RATE" ]] || [[ -z "$FORECAST_MONTHS" ]]; then
        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            [[ -z "$GROWTH_RATE" ]] && read -p "Expected growth rate (% per month): " GROWTH_RATE
            [[ -z "$FORECAST_MONTHS" ]] && read -p "Forecast period (months): " FORECAST_MONTHS
        else
            # In JSON mode, need input from LLM
            local json=$(cat <<EOF
{
  "status": "input_required",
  "next_action": "gather_user_input",
  "section": "analyze",
  "message": "Growth parameters required",
  "current_load": "$CURRENT_LOAD",
  "required_inputs": {
    "growth_rate": "Expected growth rate (% per month)",
    "forecast_months": "Forecast period (months)"
  },
  "next_steps": [
    "Provide growth rate percentage",
    "Provide forecast period in months",
    "Then continue: ops-capacity.sh --json --analyze --rate <rate> --months <months>"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi
    fi

    log "Forecasting $FORECAST_MONTHS months at $GROWTH_RATE% growth..."

    # Calculate forecast for each month
    local forecast_data=""
    for month in $(seq 1 "$FORECAST_MONTHS"); do
        local forecast
        forecast=$(echo "$CURRENT_LOAD * (1 + $GROWTH_RATE/100)^$month" | bc -l)
        local forecast_rounded
        forecast_rounded=$(printf '%.0f' "$forecast")

        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            echo "  Month $month: $forecast_rounded/day" >&2
        fi

        # Build JSON array element
        if [[ -n "$forecast_data" ]]; then
            forecast_data="$forecast_data,"
        fi
        forecast_data="$forecast_data{\"month\":$month,\"load\":$forecast_rounded}"
    done

    log "${GREEN}✓${NC} Forecast calculation complete"

    # If running only this section, return now
    if [[ "$SECTION" == "analyze" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "analyze",
  "message": "Growth analysis complete",
  "current_load": "$CURRENT_LOAD",
  "growth_rate": "$GROWTH_RATE",
  "forecast_months": "$FORECAST_MONTHS",
  "forecast_data": [$forecast_data],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    # Store for next section
    FORECAST_DATA="$forecast_data"
}

# Section 3: Generate Report
section_report() {
    log "${BLUE}Generating Capacity Report${NC}"

    local report_dir="docs/capacity"
    local report_file="$report_dir/$(date +%Y-%m-%d)-capacity-forecast.md"

    # Create directory if needed
    mkdir -p "$report_dir"

    # Build forecast list for markdown
    local forecast_list=""
    for month in $(seq 1 "$FORECAST_MONTHS"); do
        local forecast
        forecast=$(echo "$CURRENT_LOAD * (1 + $GROWTH_RATE/100)^$month" | bc -l)
        local forecast_rounded
        forecast_rounded=$(printf '%.0f' "$forecast")
        forecast_list="${forecast_list}- Month $month: $forecast_rounded/day\n"
    done

    # Generate report
    cat > "$report_file" <<EOF
# Capacity Forecast

**Date**: $(date -Iseconds)
**Current Load**: $CURRENT_LOAD/day
**Growth Rate**: $GROWTH_RATE%/month
**Forecast Period**: $FORECAST_MONTHS months

---

## Projected Load

$(echo -e "$forecast_list")

---

## Resource Recommendations

- Scale infrastructure at Month X
- Add database read replicas
- Increase cache capacity
- Review CDN usage

EOF

    log "${GREEN}✓${NC} Report generated: $report_file"

    # If running only this section, return now
    if [[ "$SECTION" == "report" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "report",
  "message": "Capacity report generated",
  "report_path": "$report_file",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --collect) SECTION="collect"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --report) SECTION="report"; shift ;;
            --full) SECTION="full"; shift ;;
            --monitor) MONITOR_CHOICE="$2"; shift 2 ;;
            --load) CURRENT_LOAD="$2"; shift 2 ;;
            --rate) GROWTH_RATE="$2"; shift 2 ;;
            --months) FORECAST_MONTHS="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        collect)
            section_collect
            ;;
        analyze)
            section_analyze
            ;;
        report)
            section_report
            ;;
        full)
            section_collect
            section_analyze
            section_report

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Capacity forecast completed successfully",
  "sections_completed": ["collect", "analyze", "report"],
  "monitoring_system": "$MONITOR_CHOICE",
  "current_load": "$CURRENT_LOAD",
  "growth_rate": "$GROWTH_RATE",
  "forecast_months": "$FORECAST_MONTHS",
  "forecast_data": [$FORECAST_DATA],
  "report_path": "docs/capacity/$(date +%Y-%m-%d)-capacity-forecast.md",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
