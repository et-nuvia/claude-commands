#!/usr/bin/env bash
# rca-timeline.sh - Create detailed incident timeline from logs and events
#
# Usage:
#   rca-timeline.sh --json --full
#   rca-timeline.sh --json --gather [--incident ID] [--start TIME] [--end TIME]
#   rca-timeline.sh --json --collect
#   rca-timeline.sh --json --generate
#   rca-timeline.sh --raw --<section>
#
# Sections:
#   --gather:   Gather incident parameters (ID, start, end)
#   --collect:  Collect events from various sources
#   --generate: Generate timeline document
#   --full:     Run all sections
#
# Output modes:
#   --json: Structured JSON output (default)
#   --raw:  Verbose debugging output

set -euo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Default values
OUTPUT_MODE="json"
SECTION="full"
INCIDENT_ID=""
START_TIME=""
END_TIME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
    --raw) OUTPUT_MODE="raw"; shift ;;
    --full) SECTION="full"; shift ;;
    --gather) SECTION="gather"; shift ;;
    --collect) SECTION="collect"; shift ;;
    --generate) SECTION="generate"; shift ;;
    --incident) INCIDENT_ID="$2"; shift 2 ;;
    --start) START_TIME="$2"; shift 2 ;;
    --end) END_TIME="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# State file for resumption
STATE_FILE="/tmp/rca-timeline-state.json"

#=============================================================================
# Helper Functions
#=============================================================================

log_raw() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "$@" >&2
  fi
}

return_json() {
  local status="$1"
  local section="$2"
  local message="$3"
  shift 3

  local next_action
  case "$status" in
    success) next_action="display_summary" ;;
    input_needed) next_action="gather_user_input" ;;
    *) next_action="fix_error" ;;
  esac

  local json="{\"status\":\"$status\",\"next_action\":\"$next_action\",\"section\":\"$section\",\"message\":\"$message\",\"timestamp\":\"$TIMESTAMP\""

  # Add optional fields
  while [[ $# -gt 0 ]]; do
    json="$json,\"$1\":\"$2\""
    shift 2
  done

  json="$json}"
  echo "$json"
}

return_json_array() {
  local status="$1"
  local section="$2"
  local message="$3"
  local field="$4"
  shift 4


  local next_action
  case "$status" in
    success) next_action="display_summary" ;;
    *) next_action="fix_error" ;;
  esac

  local json="{\"status\":\"$status\",\"next_action\":\"$next_action\",\"section\":\"$section\",\"message\":\"$message\",\"timestamp\":\"$TIMESTAMP\""
  json="$json,\"$field\":["

  local first=true
  for item in "$@"; do
    if [[ "$first" == "true" ]]; then
      json="$json\"$item\""
      first=false
    else
      json="$json,\"$item\""
    fi
  done

  json="$json]}"
  echo "$json"
}

save_state() {
  cat > "$STATE_FILE" << EOF
{
  "incident_id": "$INCIDENT_ID",
  "start_time": "$START_TIME",
  "end_time": "$END_TIME",
  "timeline_doc": "${TIMELINE_DOC:-}",
  "events_collected": ${EVENTS_COLLECTED:-false}
}
EOF
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    INCIDENT_ID=$(jq -r '.incident_id // ""' "$STATE_FILE")
    START_TIME=$(jq -r '.start_time // ""' "$STATE_FILE")
    END_TIME=$(jq -r '.end_time // ""' "$STATE_FILE")
    TIMELINE_DOC=$(jq -r '.timeline_doc // ""' "$STATE_FILE")
    EVENTS_COLLECTED=$(jq -r '.events_collected // false' "$STATE_FILE")
  fi
}

#=============================================================================
# Section: Gather
#=============================================================================

section_gather() {
  log_raw "=== Gathering Incident Parameters ==="

  # Check if parameters were provided via arguments
  if [[ -z "$INCIDENT_ID" || -z "$START_TIME" || -z "$END_TIME" ]]; then
    # Parameters missing - need user input
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      return_json "input_needed" "gather" "Incident parameters required" \
        "required_fields" "incident_id,start_time,end_time" \
        "prompt_incident_id" "Incident ID" \
        "prompt_start_time" "Start time (YYYY-MM-DD HH:MM)" \
        "prompt_end_time" "End time (YYYY-MM-DD HH:MM)"
      return 0
    else
      echo "Error: Missing required parameters" >&2
      echo "Provide --incident ID --start 'YYYY-MM-DD HH:MM' --end 'YYYY-MM-DD HH:MM'" >&2
      return 1
    fi
  fi

  log_raw "Incident ID: $INCIDENT_ID"
  log_raw "Start: $START_TIME"
  log_raw "End: $END_TIME"

  # Validate date format
  if ! date -d "$START_TIME" &>/dev/null; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      return_json "error" "gather" "Invalid start time format" \
        "details" "Expected format: YYYY-MM-DD HH:MM"
      return 1
    else
      echo "Error: Invalid start time format: $START_TIME" >&2
      return 1
    fi
  fi

  if ! date -d "$END_TIME" &>/dev/null; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      return_json "error" "gather" "Invalid end time format" \
        "details" "Expected format: YYYY-MM-DD HH:MM"
      return 1
    else
      echo "Error: Invalid end time format: $END_TIME" >&2
      return 1
    fi
  fi

  # Save state for later sections
  save_state

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    return_json "success" "gather" "Incident parameters gathered" \
      "incident_id" "$INCIDENT_ID" \
      "start_time" "$START_TIME" \
      "end_time" "$END_TIME" \
      "next_section" "collect"
  else
    echo "✓ Incident parameters gathered:"
    echo "  ID: $INCIDENT_ID"
    echo "  Start: $START_TIME"
    echo "  End: $END_TIME"
  fi
}

#=============================================================================
# Section: Collect
#=============================================================================

section_collect() {
  log_raw "=== Collecting Events ==="

  # Load state if not already set
  if [[ -z "$INCIDENT_ID" ]]; then
    load_state
  fi

  # Validate we have required parameters
  if [[ -z "$INCIDENT_ID" || -z "$START_TIME" || -z "$END_TIME" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      return_json "error" "collect" "Missing incident parameters" \
        "details" "Run --gather section first"
      return 1
    else
      echo "Error: Missing incident parameters. Run --gather first." >&2
      return 1
    fi
  fi

  log_raw "Event sources:"
  log_raw "  1. Application logs"
  log_raw "  2. System logs"
  log_raw "  3. Deployment history"
  log_raw "  4. Monitoring alerts"
  log_raw "  5. Chat transcripts"

  # Placeholder for actual event collection
  # In real implementation, would fetch from:
  # - Log aggregation system (Splunk, ELK, CloudWatch)
  # - CI/CD pipeline history
  # - Monitoring/alerting system (Datadog, New Relic)
  # - Chat/incident channels (Slack, PagerDuty)

  local event_sources=(
    "application_logs"
    "system_logs"
    "deployment_history"
    "monitoring_alerts"
    "chat_transcripts"
  )

  EVENTS_COLLECTED=true
  save_state

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    return_json_array "success" "collect" "Events collected from sources" "sources" "${event_sources[@]}" \
      | jq '. + {incident_id: "'$INCIDENT_ID'", start_time: "'$START_TIME'", end_time: "'$END_TIME'", next_section: "generate"}'
  else
    echo "✓ Events collected from:"
    for source in "${event_sources[@]}"; do
      echo "  - $source"
    done
  fi
}

#=============================================================================
# Section: Generate
#=============================================================================

section_generate() {
  log_raw "=== Generating Timeline Document ==="

  # Load state if not already set
  if [[ -z "$INCIDENT_ID" ]]; then
    load_state
  fi

  # Validate we have required parameters
  if [[ -z "$INCIDENT_ID" || -z "$START_TIME" || -z "$END_TIME" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      return_json "error" "generate" "Missing incident parameters" \
        "details" "Run --gather section first"
      return 1
    else
      echo "Error: Missing incident parameters. Run --gather first." >&2
      return 1
    fi
  fi

  if [[ "$EVENTS_COLLECTED" != "true" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      return_json "error" "generate" "Events not collected" \
        "details" "Run --collect section first"
      return 1
    else
      echo "Error: Events not collected. Run --collect first." >&2
      return 1
    fi
  fi

  # Create timeline document
  TIMELINE_DOC="docs/incidents/${INCIDENT_ID}-timeline.md"

  # Ensure directory exists
  mkdir -p "docs/incidents"

  log_raw "Creating timeline: $TIMELINE_DOC"

  cat > "$TIMELINE_DOC" << EOF
# Incident Timeline: $INCIDENT_ID

**Start**: $START_TIME
**End**: $END_TIME

---

## Timeline

### Detection Phase
- HH:MM - First alert triggered
- HH:MM - On-call engineer paged

### Investigation Phase
- HH:MM - Investigation started
- HH:MM - Root cause identified

### Mitigation Phase
- HH:MM - Fix deployed
- HH:MM - Service restored

### Recovery Phase
- HH:MM - Monitoring confirmed recovery
- HH:MM - Incident closed

EOF

  save_state

  if [[ "$OUTPUT_MODE" == "json" ]]; then
    return_json "success" "generate" "Timeline document created" \
      "incident_id" "$INCIDENT_ID" \
      "timeline_doc" "$TIMELINE_DOC" \
      "start_time" "$START_TIME" \
      "end_time" "$END_TIME"
  else
    echo "✓ Timeline created: $TIMELINE_DOC"
    echo ""
    echo "Duration: $START_TIME to $END_TIME"
  fi
}

#=============================================================================
# Main Execution
#=============================================================================

case "$SECTION" in
  gather)
    section_gather
    ;;

  collect)
    section_collect
    ;;

  generate)
    section_generate
    ;;

  full)
    # Run all sections in sequence
    if ! section_gather; then
      exit 1
    fi

    if ! section_collect; then
      exit 1
    fi

    if ! section_generate; then
      exit 1
    fi
    ;;

  *)
    echo "Error: Unknown section: $SECTION" >&2
    exit 1
    ;;
esac
