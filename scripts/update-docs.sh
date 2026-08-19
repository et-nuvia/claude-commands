#!/usr/bin/env bash
set -euo pipefail

# Thin shim — delegates to the Python implementation (update_docs.py, sibling file).
#
# The doc-index generator was rewritten from bash to Python for speed (the bash
# version took minutes on large doc trees; see TSK AAEAB3). The Python CLI mirrors
# this script's original interface exactly — `--docs-dir <dir>` and `-h/--help` —
# and resolves the default docs directory itself (ported `find_docs_dir`), so every
# argument passes straight through with no preprocessing here.
#
# The implementation is located relative to THIS script (not a hardcoded $HOME
# path) so the shim works both from a git worktree and from the installed
# ~/.claude/scripts location.
#
# Usage: update-docs.sh [--docs-dir <dir>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/update_docs.py" "$@"
