#!/usr/bin/env bash
# project-config-detect.sh - Smart wrapper for project-config-detect.py
#
# Auto-detects PROJECT.yaml values from the current project. Outputs JSON
# with detected values, confidence levels, and what still needs user input.
#
# Works on macOS and WSL/Debian without any manual setup.
# Falls back to system Python + auto-install if uv is not available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="${SCRIPT_DIR}/project-config-detect.py"

# ── Helper: emit a JSON error so callers always get parseable output ──────────
json_error() {
  local msg="$1"
  printf '{"error":true,"message":"%s"}\n' \
    "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
  exit 2
}

# ── Strategy 1: uv available (handles pyyaml automatically) ──────────────────
if command -v uv &>/dev/null; then
  exec uv run \
    --with pyyaml \
    --quiet \
    "${DETECTOR}" "$@"
fi

# ── Strategy 2: system Python 3.9+ with auto-install ─────────────────────────
PYTHON=""
for py in python3.13 python3.12 python3.11 python3.10 python3.9 python3 python; do
  if command -v "$py" &>/dev/null; then
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

# Ensure pyyaml is available (used for docker-compose parsing)
if ! "$PYTHON" -c "import yaml" &>/dev/null 2>&1; then
  echo "Installing pyyaml..." >&2
  if ! "$PYTHON" -m pip install --quiet pyyaml 2>/dev/null; then
    "$PYTHON" -m pip install --quiet --user pyyaml 2>/dev/null || true
  fi
fi

exec "$PYTHON" "${DETECTOR}" "$@"
