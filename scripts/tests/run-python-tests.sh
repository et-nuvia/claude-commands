#!/usr/bin/env bash
# run-python-tests.sh - Run Python tests via pytest
#
# Works on macOS and WSL/Debian. Uses uv if available, falls back to system
# Python with auto-install of pytest.
#
# Usage:
#   ./run-python-tests.sh                      # run all Python tests
#   ./run-python-tests.sh test-project-config-detect.py  # run specific file
#   ./run-python-tests.sh -v                   # verbose output
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "${SCRIPT_DIR}")"

# Collect args: separate test files from pytest flags
TEST_FILES=()
PYTEST_ARGS=()
for arg in "$@"; do
  if [[ -f "${SCRIPT_DIR}/${arg}" ]]; then
    TEST_FILES+=("${SCRIPT_DIR}/${arg}")
  elif [[ -f "${arg}" ]]; then
    TEST_FILES+=("${arg}")
  else
    PYTEST_ARGS+=("${arg}")
  fi
done

# Default: all test-*.py files in this directory
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    TEST_FILES+=("$f")
  done < <(find "${SCRIPT_DIR}" -maxdepth 1 -name "test-*.py" -o -name "test_*.py" | sort)
fi

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  echo "No Python test files found in ${SCRIPT_DIR}" >&2
  exit 0
fi

echo "=== Python Test Suite ==="
echo "Test files: ${#TEST_FILES[@]}"
echo ""

# ── Strategy 1: uv run (handles all deps automatically) ──────────────────────
if command -v uv &>/dev/null; then
  exec uv run \
    --with pytest \
    --with pyyaml \
    --quiet \
    python -m pytest \
    --tb=short \
    "${PYTEST_ARGS[@]}" \
    "${TEST_FILES[@]}"
fi

# ── Strategy 2: system Python with auto-install ───────────────────────────────
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
  echo "Error: Python 3.9+ or uv required." >&2
  echo "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 2
fi

# Ensure pytest and pyyaml are available
MISSING=()
"$PYTHON" -c "import pytest" &>/dev/null 2>&1 || MISSING+=("pytest")
"$PYTHON" -c "import yaml" &>/dev/null 2>&1 || MISSING+=("pyyaml")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Installing: ${MISSING[*]}..." >&2
  if ! "$PYTHON" -m pip install --quiet "${MISSING[@]}" 2>/dev/null; then
    "$PYTHON" -m pip install --quiet --user "${MISSING[@]}" 2>/dev/null || {
      echo "Error: Could not install ${MISSING[*]}" >&2
      exit 2
    }
  fi
fi

exec "$PYTHON" -m pytest \
  --tb=short \
  "${PYTEST_ARGS[@]}" \
  "${TEST_FILES[@]}"
