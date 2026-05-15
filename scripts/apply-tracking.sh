#!/usr/bin/env bash
# apply-tracking.sh — Insert tracking calls into all ~/.claude/commands/*.md files (idempotent)
#
# Inserts a "## Tracking" preamble after YAML frontmatter (or after line 1 if none),
# and appends a "## Completion Tracking" footer at the end of each file.
# Skips files that already contain track-command.sh (safe to run multiple times).

set -euo pipefail

readonly COMMANDS_DIR="${HOME}/.claude/commands"
readonly TRACK_SCRIPT="~/.claude/scripts/track-command.sh"

INSERTED=0
SKIPPED=0
ERRORS=0

insert_tracking() {
  local file="$1"
  local cmd_name="$2"

  # Build preamble block (includes error call so agent sees it before doing any work)
  local preamble
  preamble=$(cat <<PREAMBLE

## Tracking

As your **first action**, before any other work, run:
\`\`\`bash
${TRACK_SCRIPT} "${cmd_name}" start
\`\`\`

If the workflow encounters an unrecoverable error at any point, run:
\`\`\`bash
${TRACK_SCRIPT} "${cmd_name}" error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
\`\`\`

PREAMBLE
)

  # Build footer block (completion only — error is in the preamble)
  local footer
  footer=$(cat <<FOOTER

---

## Completion Tracking

When the workflow completes successfully, run:
\`\`\`bash
${TRACK_SCRIPT} "${cmd_name}" complete \\
  --model "MODEL_ID" \\
  --complexity COMPLEXITY \\
  --tokens TOKENS_ESTIMATED \\
  --cost COST_ESTIMATED
\`\`\`

Replace values before calling:
- \`MODEL_ID\` — the model currently in use (from system context, e.g., \`claude-sonnet-4-6\`)
- \`COMPLEXITY\` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- \`TOKENS_ESTIMATED\` — rough estimate of context used (input + output tokens combined)
- \`COST_ESTIMATED\` — approximate cost in USD based on model pricing
FOOTER
)

  # Use Python to do the insertion cleanly
  PREAMBLE_CONTENT="${preamble}" FOOTER_CONTENT="${footer}" \
  python3 - "${file}" <<'PYEOF'
import sys, os

file = sys.argv[1]
preamble = os.environ["PREAMBLE_CONTENT"]
footer   = os.environ["FOOTER_CONTENT"]

with open(file) as f:
    content = f.read()

lines = content.splitlines(keepends=True)

# Detect YAML frontmatter (file starts with "---\n")
has_frontmatter = len(lines) > 0 and lines[0].strip() == "---"
insert_after = 0

if has_frontmatter:
    # Find closing "---" of frontmatter
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            insert_after = i
            break

# Build new content: preamble inserted right after frontmatter (or at top)
new_lines = lines[:insert_after + 1] + [preamble] + lines[insert_after + 1:]
new_content = "".join(new_lines) + footer

with open(file, "w") as f:
    f.write(new_content)
PYEOF
}

# ─── Main Loop ────────────────────────────────────────────────────────────────

echo "Applying tracking to all commands in ${COMMANDS_DIR}..."
echo ""

for file in "${COMMANDS_DIR}"/*.md; do
  [[ -f "${file}" ]] || continue

  filename="$(basename "${file}")"
  cmd_name="${filename%.md}"

  # Idempotency check
  if grep -q "track-command.sh" "${file}" 2>/dev/null; then
    echo "  SKIP  ${filename} (already has tracking)"
    (( SKIPPED++ )) || true
    continue
  fi

  if insert_tracking "${file}" "${cmd_name}"; then
    echo "  OK    ${filename}"
    (( INSERTED++ )) || true
  else
    echo "  ERR   ${filename}" >&2
    (( ERRORS++ )) || true
  fi
done

echo ""
echo "Done: ${INSERTED} inserted, ${SKIPPED} skipped, ${ERRORS} errors"
