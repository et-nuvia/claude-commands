#!/usr/bin/env bash
set -euo pipefail

# praxis-contract.sh — Query Praxis contract discovery API
# Usage: praxis-contract.sh [--json|--raw] [endpoint]
# Examples:
#   praxis-contract.sh                    # List all contracts (markdown)
#   praxis-contract.sh /capacity          # Get /capacity contract (markdown)
#   praxis-contract.sh --json /capacity   # Get /capacity contract (raw JSON)
#   praxis-contract.sh --raw /capacity    # Same as --json

PRAXIS_URL="${PRAXIS_URL:-http://api.praxis.localhost/api/v1}"
OUTPUT_MODE="markdown"
ENDPOINT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json|--raw) OUTPUT_MODE="json"; shift ;;
    --help|-h)
      echo "Usage: praxis-contract.sh [--json|--raw] [endpoint]"
      echo "  No args: list all available contracts"
      echo "  /endpoint: get full contract for that endpoint"
      echo "  --json/--raw: output raw API JSON instead of markdown"
      exit 0
      ;;
    *) ENDPOINT="$1"; shift ;;
  esac
done

# Determine API call
if [[ -z "${ENDPOINT}" ]]; then
  # List all contracts
  RESPONSE=$(curl -sf "${PRAXIS_URL}/app/contracts" 2>/dev/null) || {
    if [[ "${OUTPUT_MODE}" == "json" ]]; then
      echo '{"status":"error","next_action":"fix_error","message":"Cannot reach Praxis at '"${PRAXIS_URL}"'. Ensure Praxis is running or set PRAXIS_URL."}'
    else
      echo "ERROR: Cannot reach Praxis at ${PRAXIS_URL}"
      echo "Ensure Praxis is running or set PRAXIS_URL environment variable."
    fi
    exit 1
  }

  if [[ "${OUTPUT_MODE}" == "json" ]]; then
    echo '{"status":"success","next_action":"display_contracts","data":'"${RESPONSE}"'}'
  else
    echo "# Available Praxis Contracts"
    echo ""
    echo "| Endpoint | Method | Description |"
    echo "|----------|--------|-------------|"
    echo "${RESPONSE}" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for c in data:
    print(f\"| \`{c['path']}\` | {c['method']} | {c['description']} |\")" 2>/dev/null || echo "${RESPONSE}"
    echo ""
    echo "Use \`/praxis-contract /endpoint\` to get the full contract."
  fi
else
  # Get specific contract
  RESPONSE=$(curl -sf -X POST "${PRAXIS_URL}/app/contracts" \
    -H "Content-Type: application/json" \
    -d "{\"endpoint\":\"${ENDPOINT}\"}" 2>/dev/null) || {
    HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" -X POST "${PRAXIS_URL}/app/contracts" \
      -H "Content-Type: application/json" \
      -d "{\"endpoint\":\"${ENDPOINT}\"}" 2>/dev/null) || HTTP_CODE="000"

    if [[ "${HTTP_CODE}" == "404" ]]; then
      if [[ "${OUTPUT_MODE}" == "json" ]]; then
        echo '{"status":"error","next_action":"fix_error","message":"Endpoint '"${ENDPOINT}"' is not in the Praxis contract allowlist."}'
      else
        echo "ERROR: Endpoint '${ENDPOINT}' is not in the Praxis contract allowlist."
        echo "Run \`/praxis-contract\` to see available endpoints."
      fi
    else
      if [[ "${OUTPUT_MODE}" == "json" ]]; then
        echo '{"status":"error","next_action":"fix_error","message":"Cannot reach Praxis at '"${PRAXIS_URL}"'. Ensure Praxis is running or set PRAXIS_URL."}'
      else
        echo "ERROR: Cannot reach Praxis at ${PRAXIS_URL}"
      fi
    fi
    exit 1
  }

  if [[ "${OUTPUT_MODE}" == "json" ]]; then
    echo '{"status":"success","next_action":"display_contract","data":'"${RESPONSE}"'}'
  else
    # Format as markdown for LLM consumption
    python3 -c "
import json,sys
data=json.loads('''${RESPONSE}''')
print(f\"# Contract: \`{data['endpoint']}\`\")
print(f\"\n**Method**: {data['method']}\")
print(f\"**Description**: {data['description']}\")
print(f\"\n## Fields\n\")
print(\"| Field | Type | Required | Description | Example |\")
print(\"|-------|------|----------|-------------|---------|\" )
for f in data.get('fields',[]):
    req = 'Yes' if f['required'] else 'No'
    ex = json.dumps(f['example']) if not isinstance(f['example'],str) else f['example']
    enum_str = f' (enum: {\", \".join(f[\"enum\"])})' if 'enum' in f and f['enum'] else ''
    print(f\"| \`{f['name']}\` | {f['type']}{enum_str} | {req} | {f['description']} | \`{ex}\` |\")
print(f\"\n## Example Response\n\")
print('\`\`\`json')
print(json.dumps(data.get('exampleResponse',{}),indent=2))
print('\`\`\`')
print(f\"\n## JSON Schema\n\")
print('\`\`\`json')
print(json.dumps(data.get('schema',{}),indent=2))
print('\`\`\`')
" 2>/dev/null || echo "${RESPONSE}"
  fi
fi
