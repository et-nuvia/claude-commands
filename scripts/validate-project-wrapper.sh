#!/usr/bin/env bash
# validate-project-wrapper.sh - Smart wrapper for validate-project.py
#
# Auto-handles all setup:
#   1. uv available → use `uv run --with pyyaml` (no venv or pip install needed)
#   2. uv not available, Python 3.9+ available → auto-install pyyaml/jsonschema via pip
#   3. Nothing usable → emit JSON error with install instructions
#
# Works on macOS and WSL/Debian without any manual setup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-project.py"

# ── Helper: emit a JSON error to stdout so callers get parseable output ────────
json_error() {
  local msg="$1"
  printf '{"valid":false,"schema_version":"1.0.0","summary":{"errors":1,"warnings":0,"info":0},"issues":[{"severity":"error","code":"SETUP_ERROR","path":"(setup)","message":"%s"}]}\n' \
    "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
  exit 2
}

# ── Strategy 1: uv is available ───────────────────────────────────────────────
# uv run --with handles deps automatically via its package cache.
# No venv creation or pip install required.
if command -v uv &>/dev/null; then
  exec uv run \
    --with pyyaml \
    --with 'jsonschema[format]' \
    --quiet \
    "${VALIDATOR}" "$@"
fi

# ── Strategy 2: system Python 3.9+ with auto-install ─────────────────────────
PYTHON=""
for py in python3.13 python3.12 python3.11 python3.10 python3.9 python3 python; do
  if command -v "$py" &>/dev/null; then
    # Verify it meets minimum version requirement
    ok=$("$py" -c "import sys; print('yes' if sys.version_info >= (3, 9) else 'no')" 2>/dev/null || echo "no")
    if [[ "$ok" == "yes" ]]; then
      PYTHON="$py"
      break
    fi
  fi
done

if [[ -z "$PYTHON" ]]; then
  json_error "Python 3.9+ or uv is required. Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

# Ensure pyyaml and jsonschema are importable; install if missing
if ! "$PYTHON" -c "import yaml, jsonschema" &>/dev/null 2>&1; then
  echo "Installing required packages (pyyaml, jsonschema)..." >&2

  # Try system install first, then user install
  if "$PYTHON" -m pip install --quiet pyyaml 'jsonschema[format]' 2>/dev/null; then
    : # success
  elif "$PYTHON" -m pip install --quiet --user pyyaml 'jsonschema[format]' 2>/dev/null; then
    : # success with --user
  else
    json_error "Failed to install pyyaml/jsonschema. Run: pip install pyyaml 'jsonschema[format]'"
  fi

  # Verify install succeeded
  if ! "$PYTHON" -c "import yaml, jsonschema" &>/dev/null 2>&1; then
    json_error "Package install succeeded but imports still fail. Check your Python environment."
  fi
fi

exec "$PYTHON" "${VALIDATOR}" "$@"
