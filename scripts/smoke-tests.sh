#!/usr/bin/env bash
# =============================================================================
# Universal Smoke Test Script (PROJECT.yaml-driven)
# =============================================================================
# Reads smoke_tests section from PROJECT.yaml and runs layered tests.
#
# Modes:
#   --basic    Docker container health only (fastest)
#   --server   Health + docker exec endpoint checks (on-server via SSM)
#   --full     External domain-based checks from CI (needs --domain)
#   --browser  Playwright login smoke test
#
# Options:
#   --version X.Y.Z  Verify deployed version matches expected
#   --generate       Output self-contained bash for SSM execution
#   --project PATH   Path to PROJECT.yaml (default: ./PROJECT.yaml)
#   --domain URL     Base URL for --full mode (e.g., https://app.example.com)
#
# Output: JSON to stdout, human-readable to stderr
# Exit:   0=passed, 1=failed, 2=usage error
# =============================================================================

set -euo pipefail

# Defaults
MODE="server"
EXPECTED_VERSION=""
GENERATE=false
PROJECT_FILE="./PROJECT.yaml"
DOMAIN=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --basic)   MODE="basic"; shift ;;
    --server)  MODE="server"; shift ;;
    --full)    MODE="full"; shift ;;
    --browser) MODE="browser"; shift ;;
    --version) EXPECTED_VERSION="$2"; shift 2 ;;
    --generate) GENERATE=true; shift ;;
    --project) PROJECT_FILE="$2"; shift 2 ;;
    --domain)  DOMAIN="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--basic|--server|--full|--browser] [options]" >&2
      echo "" >&2
      echo "Modes:" >&2
      echo "  --basic    Docker container health checks only" >&2
      echo "  --server   Container health + docker exec endpoint checks (default)" >&2
      echo "  --full     External domain-based checks (needs --domain)" >&2
      echo "  --browser  Playwright browser smoke tests" >&2
      echo "" >&2
      echo "Options:" >&2
      echo "  --version VER   Verify deployed version matches VER" >&2
      echo "  --generate      Output self-contained bash for SSM execution" >&2
      echo "  --project PATH  Path to PROJECT.yaml (default: ./PROJECT.yaml)" >&2
      echo "  --domain URL    Base URL for --full mode" >&2
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Validate
if [[ "$MODE" == "full" && -z "$DOMAIN" ]]; then
  echo "Error: --full mode requires --domain URL" >&2
  exit 2
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: PROJECT.yaml not found at $PROJECT_FILE" >&2
  exit 2
fi

# ============================================================================
# Parse PROJECT.yaml using python3 + PyYAML (or inline fallback)
# ============================================================================

parse_yaml() {
  python3 -c "
import yaml, json, sys

with open('$PROJECT_FILE') as f:
    config = yaml.safe_load(f)

smoke = config.get('smoke_tests', {})
print(json.dumps(smoke))
" 2>/dev/null
}

SMOKE_CONFIG=$(parse_yaml)
if [[ -z "$SMOKE_CONFIG" || "$SMOKE_CONFIG" == "null" ]]; then
  echo "Error: No smoke_tests section in PROJECT.yaml" >&2
  exit 2
fi

# ============================================================================
# Generate mode: output self-contained bash script for SSM
# ============================================================================

if [[ "$GENERATE" == "true" ]]; then
  # Generate a self-contained bash script that doesn't need YAML parsing
  python3 -c "
import yaml, json, sys

with open('$PROJECT_FILE') as f:
    config = yaml.safe_load(f)

smoke = config.get('smoke_tests', {})
containers = smoke.get('containers', [])
endpoints = smoke.get('endpoints', [])

print('#!/bin/bash')
print('set -euo pipefail')
print('cd /opt/medical-clearance')
print('')
print('PASSED=0; FAILED=0; WARNINGS=0')
print('pass() { echo \"  ✓ \$1\"; PASSED=\$((PASSED + 1)); }')
print('fail() { echo \"  ✗ \$1\"; FAILED=\$((FAILED + 1)); }')
print('warn() { echo \"  ⚠ \$1\"; WARNINGS=\$((WARNINGS + 1)); }')
print('')

# Container health checks
print('echo \"\"')
print('echo \"[1/3] Docker Health Status\"')
print('echo \"------------------------------------------\"')
for c in containers:
    print(f'''
STATUS=\$(docker inspect --format='{{{{.State.Health.Status}}}}' \"{c}\" 2>/dev/null || echo \"not found\")
if [ \"\$STATUS\" = \"healthy\" ]; then
  pass \"{c} is healthy\"
elif [ \"\$STATUS\" = \"no healthcheck\" ]; then
  RUNNING=\$(docker inspect --format='{{{{.State.Status}}}}' \"{c}\" 2>/dev/null || echo \"not found\")
  if [ \"\$RUNNING\" = \"running\" ]; then pass \"{c} is running (no healthcheck)\"; else fail \"{c} is \$RUNNING\"; fi
else
  fail \"{c} is \$STATUS\"
fi''')

# Endpoint checks
print('')
print('echo \"\"')
print('echo \"[2/3] Endpoint Checks\"')
print('echo \"------------------------------------------\"')
for ep in endpoints:
    name = ep['name']
    container = ep['container']
    url = ep['url']
    runtime = ep.get('runtime', 'node')
    ep_type = ep.get('type', 'json')
    expect = ep.get('expect', {})
    severity = ep.get('severity', 'error')
    status_code = expect.get('status_code', 200)
    fields = expect.get('fields', {})
    contains = expect.get('contains', '')
    report_fn = 'warn' if severity == 'warning' else 'fail'

    if runtime == 'node':
        fetch_cmd = f'''docker exec {container} node -e \"
const http = require('http');
http.get('{url}', r => {{
  let d = '';
  r.on('data', c => d += c);
  r.on('end', () => {{ process.stdout.write(r.statusCode + '\\\\n' + d); process.exit(0); }});
}}).on('error', e => {{ process.stdout.write('0\\\\n{{}}'); process.exit(0); }});
\" 2>/dev/null || echo \"0\\n{{}}\"'''
    else:
        fetch_cmd = f'''docker exec {container} python -c \"
import urllib.request, sys
try:
    with urllib.request.urlopen('{url}', timeout=10) as r:
        sys.stdout.write(str(r.status) + '\\\\n' + r.read().decode())
except Exception as e:
    sys.stdout.write('0\\\\n{{}}')
\" 2>/dev/null || echo \"0\\n{{}}\"'''

    print(f'RESPONSE=$({fetch_cmd})')
    print(f'HTTP_CODE=$(echo \"$RESPONSE\" | head -1)')
    print(f'BODY=$(echo \"$RESPONSE\" | tail -n +2)')

    # Status code check
    print(f'if [ \"$HTTP_CODE\" = \"{status_code}\" ]; then')
    if fields:
        for field_path, expected_val in fields.items():
            json_path = '.'.join(f'[\"{p}\"]' for p in field_path.split('.'))
            expected_str = str(expected_val).lower() if isinstance(expected_val, bool) else str(expected_val)
            print(f'  FIELD_VAL=$(echo \"$BODY\" | python3 -c \"import json,sys; d=json.load(sys.stdin); print(str(d{json_path}).lower() if isinstance(d{json_path},bool) else d{json_path})\" 2>/dev/null || echo \"\")')
            print(f'  if [ \"$FIELD_VAL\" = \"{expected_str}\" ]; then')
            print(f'    pass \"{name}\"')
            print(f'  else')
            print(f'    {report_fn} \"{name} (field {field_path}=$FIELD_VAL, expected {expected_str})\"')
            print(f'  fi')
        print(f'else')
        print(f'  {report_fn} \"{name} (HTTP $HTTP_CODE, expected {status_code})\"')
        print(f'fi')
    elif contains:
        print(f'  if echo \"$BODY\" | grep -qi \"{contains}\"; then')
        print(f'    pass \"{name}\"')
        print(f'  else')
        print(f'    {report_fn} \"{name} (content mismatch)\"')
        print(f'  fi')
        print(f'else')
        print(f'  {report_fn} \"{name} (HTTP $HTTP_CODE, expected {status_code})\"')
        print(f'fi')
    else:
        print(f'  pass \"{name}\"')
        print(f'else')
        print(f'  {report_fn} \"{name} (HTTP $HTTP_CODE, expected {status_code})\"')
        print(f'fi')
    print('')

# Container status
print('echo \"\"')
print('echo \"[3/3] Container Status\"')
print('echo \"------------------------------------------\"')
# Count containers whose State field is exactly \"running\" — match the
# fixed token \"State\":\"running\", not substrings like Status containing
# the word \"running\". Built via a Python variable so the triple-nested
# quoting (bash -> python -c -> printed bash) stays readable.
_running_pat = chr(34) + 'State' + chr(34) + ':' + chr(34) + 'running' + chr(34)
_restart_pat = chr(34) + 'State' + chr(34) + ':' + chr(34) + 'restarting' + chr(34)
print(f'RUNNING=\$(docker compose ps --format json 2>/dev/null | grep -cF {chr(39)}{_running_pat}{chr(39)} || echo 0)')
print('if [ \"\$RUNNING\" -ge 3 ]; then pass \"All \$RUNNING containers running\"; else fail \"Only \$RUNNING containers running\"; fi')
print(f'RESTARTS=\$(docker compose ps --format json 2>/dev/null | grep -cF {chr(39)}{_restart_pat}{chr(39)} || echo 0)')
print('if [ \"\$RESTARTS\" -eq 0 ]; then pass \"No containers restarting\"; else fail \"\$RESTARTS container(s) restarting\"; fi')

# Version check
version_expected = '$EXPECTED_VERSION'
if version_expected:
    version_config = smoke.get('version', {})
    check_path = version_config.get('check_path', '/api/v1/version')
    field = version_config.get('field', 'version')
    print(f'''
echo \"\"
echo \"[Version] Checking deployed version...\"
echo \"------------------------------------------\"
VER_RESPONSE=\$(docker exec medclear-backend node -e \"
const http = require('http');
http.get('http://127.0.0.1:3001{check_path}', r => {{
  let d = '';
  r.on('data', c => d += c);
  r.on('end', () => {{ process.stdout.write(d); process.exit(0); }});
}}).on('error', () => {{ process.stdout.write('{{}}'); process.exit(0); }});
\" 2>/dev/null || echo \"{{}}\")
DEPLOYED_VER=\$(echo \"\$VER_RESPONSE\" | python3 -c \"import json,sys; print(json.load(sys.stdin).get('{field}','unknown'))\" 2>/dev/null || echo \"unknown\")
if [ \"\$DEPLOYED_VER\" = \"{version_expected}\" ]; then
  pass \"Version matches: \$DEPLOYED_VER\"
else
  fail \"Version mismatch: deployed=\$DEPLOYED_VER expected={version_expected}\"
fi''')

# Summary
print('')
print('echo \"\"')
print('echo \"============================================\"')
print('echo \"  Results: \$PASSED passed, \$FAILED failed, \$WARNINGS warnings\"')
print('echo \"============================================\"')
print('')
print('if [ \"\$FAILED\" -gt 0 ]; then')
print('  echo \"\"')
print('  echo \"SMOKE TESTS FAILED\"')
print('  docker compose ps')
print('  docker compose logs --tail=30')
print('  exit 1')
print('fi')
print('echo \"All smoke tests passed!\"')
"
  exit $?
fi

# ============================================================================
# Run tests directly (non-generate mode)
# ============================================================================

START_TIME=$(date +%s)
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNINGS=0
TEST_RESULTS=()

pass() {
  echo "  ✓ $1" >&2
  TESTS_PASSED=$((TESTS_PASSED + 1))
  TEST_RESULTS+=("{\"name\":\"$1\",\"status\":\"passed\"}")
}

fail() {
  echo "  ✗ $1" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TEST_RESULTS+=("{\"name\":\"$1\",\"status\":\"failed\"}")
}

warn() {
  echo "  ⚠ $1" >&2
  TESTS_WARNINGS=$((TESTS_WARNINGS + 1))
  TEST_RESULTS+=("{\"name\":\"$1\",\"status\":\"warning\"}")
}

# ---------- Basic mode: Docker container health ----------
if [[ "$MODE" == "basic" || "$MODE" == "server" ]]; then
  echo "" >&2
  echo "Container Health Checks:" >&2
  echo "------------------------------------------" >&2

  CONTAINERS=$(echo "$SMOKE_CONFIG" | python3 -c "import json,sys; [print(c) for c in json.load(sys.stdin).get('containers',[])]")
  while IFS= read -r container; do
    [[ -z "$container" ]] && continue
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not found")
    if [[ "$STATUS" == "healthy" ]]; then
      pass "$container is healthy"
    elif [[ "$STATUS" == "no healthcheck" ]]; then
      RUNNING=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
      if [[ "$RUNNING" == "running" ]]; then
        pass "$container is running"
      else
        fail "$container is $RUNNING"
      fi
    else
      fail "$container is $STATUS"
    fi
  done <<< "$CONTAINERS"
fi

# ---------- Server mode: docker exec endpoint checks ----------
if [[ "$MODE" == "server" ]]; then
  echo "" >&2
  echo "Endpoint Checks:" >&2
  echo "------------------------------------------" >&2

  python3 -c "
import json, sys, subprocess

config = json.loads('''$SMOKE_CONFIG''')
endpoints = config.get('endpoints', [])

for ep in endpoints:
    name = ep['name']
    container = ep['container']
    url = ep['url']
    runtime = ep.get('runtime', 'node')
    ep_type = ep.get('type', 'json')
    expect = ep.get('expect', {})
    severity = ep.get('severity', 'error')
    status_code = expect.get('status_code', 200)
    fields = expect.get('fields', {})
    contains = expect.get('contains', '')

    # Fetch via docker exec
    if runtime == 'node':
        cmd = ['docker', 'exec', container, 'node', '-e', f\"\"\"
const http = require('http');
http.get('{url}', r => {{
  let d = '';
  r.on('data', c => d += c);
  r.on('end', () => {{ console.log(r.statusCode); console.log(d); process.exit(0); }});
}}).on('error', () => {{ console.log(0); console.log('{{}}'); process.exit(0); }});
\"\"\"]
    else:
        cmd = ['docker', 'exec', container, 'python', '-c', f\"\"\"
import urllib.request, sys
try:
    with urllib.request.urlopen('{url}', timeout=10) as r:
        print(r.status)
        print(r.read().decode())
except Exception:
    print(0)
    print('{{}}')
\"\"\"]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        lines = result.stdout.strip().split('\\n', 1)
        http_code = int(lines[0]) if lines else 0
        body = lines[1] if len(lines) > 1 else '{{}}'
    except Exception:
        http_code = 0
        body = '{{}}'

    # Check expectations
    ok = http_code == status_code
    detail = ''

    if ok and fields:
        try:
            data = json.loads(body)
            for path, expected in fields.items():
                val = data
                for key in path.split('.'):
                    val = val[key]
                if isinstance(expected, bool):
                    ok = val is expected
                else:
                    ok = str(val) == str(expected)
                if not ok:
                    detail = f' (field {path}={val}, expected {expected})'
                    break
        except Exception as e:
            ok = False
            detail = f' (JSON parse error: {e})'

    if ok and contains:
        if contains.lower() not in body.lower():
            ok = False
            detail = ' (content mismatch)'

    if not ok and not detail:
        detail = f' (HTTP {http_code}, expected {status_code})'

    # Output result line for bash to parse
    status_str = 'pass' if ok else ('warn' if severity == 'warning' else 'fail')
    print(f'{status_str}|{name}{detail}')
" 2>/dev/null | while IFS='|' read -r status msg; do
    case "$status" in
      pass) pass "$msg" ;;
      fail) fail "$msg" ;;
      warn) warn "$msg" ;;
    esac
  done
fi

# ---------- Full mode: external domain-based checks ----------
if [[ "$MODE" == "full" ]]; then
  echo "" >&2
  echo "External Endpoint Checks ($DOMAIN):" >&2
  echo "------------------------------------------" >&2

  python3 -c "
import json, sys

config = json.loads('''$SMOKE_CONFIG''')
external = config.get('external_endpoints', [])

for ep in external:
    name = ep['name']
    path = ep['path']
    ep_type = ep.get('type', 'json')
    expect = ep.get('expect', {})
    status_code = expect.get('status_code', 200)
    fields = expect.get('fields', {})
    contains = expect.get('contains', '')
    print(f'{name}|{path}|{ep_type}|{status_code}|{json.dumps(fields)}|{contains}')
" 2>/dev/null | while IFS='|' read -r name path ep_type exp_code fields_json contains; do
    URL="${DOMAIN}${path}"
    HTTP_CODE=$(curl -s -o /tmp/smoke_body -w "%{http_code}" --max-time 10 "$URL" 2>/dev/null || echo "000")
    BODY=$(cat /tmp/smoke_body 2>/dev/null || echo "")

    if [[ "$HTTP_CODE" != "$exp_code" ]]; then
      fail "$name (HTTP $HTTP_CODE, expected $exp_code)"
      continue
    fi

    if [[ -n "$fields_json" && "$fields_json" != "{}" ]]; then
      FIELD_OK=$(python3 -c "
import json, sys
fields = json.loads('$fields_json')
try:
    data = json.loads('''$BODY''')
    for path, expected in fields.items():
        val = data
        for key in path.split('.'): val = val[key]
        if isinstance(expected, bool):
            if val is not expected: sys.exit(1)
        elif str(val) != str(expected): sys.exit(1)
    print('ok')
except: sys.exit(1)
" 2>/dev/null && echo "ok" || echo "fail")
      if [[ "$FIELD_OK" != *"ok"* ]]; then
        fail "$name (field mismatch)"
        continue
      fi
    fi

    if [[ -n "$contains" ]]; then
      if ! echo "$BODY" | grep -qi "$contains"; then
        fail "$name (content mismatch)"
        continue
      fi
    fi

    pass "$name"
  done

  rm -f /tmp/smoke_body
fi

# ---------- Browser mode: Playwright tests ----------
if [[ "$MODE" == "browser" ]]; then
  echo "" >&2
  echo "Browser Smoke Tests:" >&2
  echo "------------------------------------------" >&2

  SPECS=$(echo "$SMOKE_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
for bt in config.get('browser_tests', []):
    print(bt.get('spec', ''))
" 2>/dev/null)

  while IFS= read -r spec; do
    [[ -z "$spec" ]] && continue
    echo "  Running $spec..." >&2
    if npx playwright test "$spec" --reporter=line 2>&1 | tail -5 >&2; then
      pass "$(basename "$spec")"
    else
      fail "$(basename "$spec")"
    fi
  done <<< "$SPECS"
fi

# ---------- Version verification ----------
if [[ -n "$EXPECTED_VERSION" ]]; then
  echo "" >&2
  echo "Version Verification:" >&2
  echo "------------------------------------------" >&2

  VERSION_PATH=$(echo "$SMOKE_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
print(config.get('version', {}).get('check_path', '/api/v1/version'))
" 2>/dev/null)

  VERSION_FIELD=$(echo "$SMOKE_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
print(config.get('version', {}).get('field', 'version'))
" 2>/dev/null)

  if [[ "$MODE" == "full" ]]; then
    # External check via domain
    BODY=$(curl -s --max-time 10 "${DOMAIN}${VERSION_PATH}" 2>/dev/null || echo "{}")
  else
    # On-server check via docker exec
    BODY=$(docker exec medclear-backend node -e "
const http = require('http');
http.get('http://127.0.0.1:3001${VERSION_PATH}', r => {
  let d = '';
  r.on('data', c => d += c);
  r.on('end', () => { process.stdout.write(d); process.exit(0); });
}).on('error', () => { process.stdout.write('{}'); process.exit(0); });
" 2>/dev/null || echo "{}")
  fi

  DEPLOYED_VER=$(echo "$BODY" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('$VERSION_FIELD', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

  if [[ "$DEPLOYED_VER" == "$EXPECTED_VERSION" ]]; then
    pass "Version matches: $DEPLOYED_VER"
  else
    fail "Version mismatch: deployed=$DEPLOYED_VER expected=$EXPECTED_VERSION"
  fi
fi

# ============================================================================
# Results
# ============================================================================

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_WARNINGS))

echo "" >&2
echo "============================================" >&2
echo "  Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_WARNINGS warnings ($TOTAL total)" >&2
echo "============================================" >&2

# JSON output to stdout
cat <<EOF
{
  "status": "$(if [[ $TESTS_FAILED -eq 0 ]]; then echo "passed"; else echo "failed"; fi)",
  "mode": "$MODE",
  "tests_passed": $TESTS_PASSED,
  "tests_failed": $TESTS_FAILED,
  "tests_warnings": $TESTS_WARNINGS,
  "elapsed_seconds": $ELAPSED,
  "version_expected": "$EXPECTED_VERSION",
  "results": [$(IFS=,; echo "${TEST_RESULTS[*]}")]
}
EOF

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
