#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Ops Scaling Analysis
#
# Usage:
#   ~/.claude/scripts/ops-scaling.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --gather:   Gather current metrics (interactive prompts)
#   --analyze:  Analyze bottlenecks from metrics
#   --report:   Generate scaling decision report
#   --full:     Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: ops-scaling.sh --json --full
#   2. Script prompts for metrics interactively
#   3. Returns JSON with recommendation and report path
#   4. If error: LLM can retry with --raw for more debugging info

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, gather, analyze, report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Metrics (gathered in section_gather)
CPU_USAGE=""
MEM_USAGE=""
REQ_RATE=""
RESPONSE_TIME=""
INSTANCE_COUNT=""

# Analysis results
BOTTLENECK=""
RECOMMENDATION=""
RECOMMENDED_INSTANCES=""

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Gather Metrics (Interactive)
section_gather() {
    log "${BLUE}Gathering Current Metrics${NC}"
    log "══════════════════════════════════════"
    log ""

    # Prompt for metrics (interactive)
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        read -p "Current CPU usage (%): " CPU_USAGE
        read -p "Current memory usage (%): " MEM_USAGE
        read -p "Current request rate (req/s): " REQ_RATE
        read -p "Response time (ms): " RESPONSE_TIME
        read -p "Number of instances: " INSTANCE_COUNT
    else
        # In JSON mode, check if values provided via environment
        if [[ -z "${CPU_USAGE:-}" ]] || [[ -z "${MEM_USAGE:-}" ]] || \
           [[ -z "${REQ_RATE:-}" ]] || [[ -z "${RESPONSE_TIME:-}" ]] || \
           [[ -z "${INSTANCE_COUNT:-}" ]]; then
            exit_with_json "error" "Metrics not provided" \
                "Pass metric flags: --cpu, --mem, --req-rate, --response-time, --instances. Or use --raw mode for interactive prompts."
        fi
    fi

    # Validate inputs
    if [[ ! "$CPU_USAGE" =~ ^[0-9]+$ ]] || \
       [[ ! "$MEM_USAGE" =~ ^[0-9]+$ ]] || \
       [[ ! "$REQ_RATE" =~ ^[0-9]+$ ]] || \
       [[ ! "$RESPONSE_TIME" =~ ^[0-9]+$ ]] || \
       [[ ! "$INSTANCE_COUNT" =~ ^[0-9]+$ ]]; then
        exit_with_json "error" "Invalid metric values" \
            "All metrics must be positive integers"
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "gather" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "gather",
  "message": "Metrics gathered successfully",
  "metrics": {
    "cpu_usage": $CPU_USAGE,
    "memory_usage": $MEM_USAGE,
    "request_rate": $REQ_RATE,
    "response_time": $RESPONSE_TIME,
    "instance_count": $INSTANCE_COUNT
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Metrics gathered"
}

# Section 2: Analyze Bottlenecks
section_analyze() {
    log ""
    log "${BLUE}Analyzing Bottlenecks${NC}"

    BOTTLENECK=""
    RECOMMENDATION=""
    RECOMMENDED_INSTANCES=""

    # Analyze CPU
    if [[ $CPU_USAGE -gt 80 ]]; then
        log "  ${YELLOW}⚠️  CPU constrained${NC}"
        BOTTLENECK="CPU"
    fi

    # Analyze Memory
    if [[ $MEM_USAGE -gt 80 ]]; then
        log "  ${YELLOW}⚠️  Memory constrained${NC}"
        if [[ -z "$BOTTLENECK" ]]; then
            BOTTLENECK="Memory"
        else
            BOTTLENECK="$BOTTLENECK, Memory"
        fi
    fi

    # Analyze Latency
    if [[ $RESPONSE_TIME -gt 500 ]]; then
        log "  ${YELLOW}⚠️  High latency${NC}"
    fi

    # Determine recommendation
    if [[ -n "$BOTTLENECK" ]]; then
        RECOMMENDATION="Horizontal Scaling"
        RECOMMENDED_INSTANCES=$((INSTANCE_COUNT * 2))
    else
        RECOMMENDATION="Vertical Scaling"
        RECOMMENDED_INSTANCES=$INSTANCE_COUNT
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "analyze" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "analyze",
  "message": "Analysis complete",
  "bottleneck": "${BOTTLENECK:-None}",
  "recommendation": "$RECOMMENDATION",
  "recommended_instances": $RECOMMENDED_INSTANCES,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Analysis complete"
}

# Section 3: Generate Report
section_report() {
    log ""
    log "${BLUE}Generating Report${NC}"

    local SCALING_REPORT="docs/scaling/$(date +%Y-%m-%d)-scaling-decision.md"
    mkdir -p docs/scaling

    # Create report
    cat > "$SCALING_REPORT" << EOF
# Scaling Decision

**Date**: $(date -Iseconds)

## Current State
- CPU: ${CPU_USAGE}%
- Memory: ${MEM_USAGE}%
- Request rate: ${REQ_RATE} req/s
- Response time: ${RESPONSE_TIME}ms
- Instances: ${INSTANCE_COUNT}

## Analysis
- Bottleneck: ${BOTTLENECK:-None detected}
- Resource utilization: $(if [[ -n "$BOTTLENECK" ]]; then echo "Constrained"; else echo "Normal"; fi)
- Latency status: $(if [[ $RESPONSE_TIME -gt 500 ]]; then echo "High"; else echo "Acceptable"; fi)

## Recommendation
${RECOMMENDATION}

$(if [[ "$RECOMMENDATION" == "Horizontal Scaling" ]]; then
    echo "### Horizontal Scaling Strategy"
    echo "- Add more instances to distribute load"
    echo "- Recommended instances: ${RECOMMENDED_INSTANCES} (current: ${INSTANCE_COUNT})"
    echo "- Benefits: Better fault tolerance, handles spiky traffic"
    echo "- Considerations: Requires load balancer, session management"
else
    echo "### Vertical Scaling Strategy"
    echo "- Upgrade instance size for better performance"
    echo "- Current instances: ${INSTANCE_COUNT}"
    echo "- Benefits: Simpler architecture, more cost-effective"
    echo "- Considerations: Downtime during upgrade, upper hardware limits"
fi)

## Next Steps
1. Test scaling strategy in staging environment
2. Monitor performance metrics after scaling
3. Adjust as needed based on results
4. Document final configuration

EOF

    # If running only this section, return now
    if [[ "$SECTION" == "report" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "report",
  "message": "Report generated",
  "report_path": "$SCALING_REPORT",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Report generated: $SCALING_REPORT"
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
            --gather) SECTION="gather"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --report) SECTION="report"; shift ;;
            --full) SECTION="full"; shift ;;
            --cpu) CPU_USAGE="$2"; shift 2 ;;
            --mem) MEM_USAGE="$2"; shift 2 ;;
            --req-rate) REQ_RATE="$2"; shift 2 ;;
            --response-time) RESPONSE_TIME="$2"; shift 2 ;;
            --instances) INSTANCE_COUNT="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        gather)
            section_gather
            ;;
        analyze)
            # Need metrics first
            if [[ -z "${CPU_USAGE:-}" ]]; then
                exit_with_json "error" "Cannot analyze without metrics" \
                    "Run --gather first or provide metrics via flags"
            fi
            section_analyze
            ;;
        report)
            # Need analysis first
            if [[ -z "${RECOMMENDATION:-}" ]]; then
                exit_with_json "error" "Cannot generate report without analysis" \
                    "Run --analyze first"
            fi
            section_report
            ;;
        full)
            section_gather
            section_analyze
            section_report

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Scaling analysis complete",
  "metrics": {
    "cpu_usage": $CPU_USAGE,
    "memory_usage": $MEM_USAGE,
    "request_rate": $REQ_RATE,
    "response_time": $RESPONSE_TIME,
    "instance_count": $INSTANCE_COUNT
  },
  "analysis": {
    "bottleneck": "${BOTTLENECK:-None}",
    "recommendation": "$RECOMMENDATION",
    "recommended_instances": $RECOMMENDED_INSTANCES
  },
  "report_path": "docs/scaling/$(date +%Y-%m-%d)-scaling-decision.md",
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
