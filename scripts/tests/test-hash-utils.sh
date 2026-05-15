#!/usr/bin/env bash
# Unit tests for compute_task_id, compute_year_month, normalize_task_id
# Run via: ~/.claude/scripts/tests/run-tests.sh test-hash-utils.sh

# Source functions under test
source "${HOME}/.claude/scripts/common.sh"

# ---- compute_task_id ----

EXPECTED_HASH=$(printf '%s%s' "2602140922" "convert-commands-to-scripts" | sha256sum | head -c 6 | tr 'a-f' 'A-F')
ACTUAL_HASH=$(compute_task_id "2602140922" "convert-commands-to-scripts")

assert_eq "$EXPECTED_HASH" "$ACTUAL_HASH" \
  "compute_task_id: produces correct hash"

# Determinism: same inputs → same output
H1=$(compute_task_id "2602140922" "convert-commands-to-scripts")
H2=$(compute_task_id "2602140922" "convert-commands-to-scripts")
assert_eq "$H1" "$H2" \
  "compute_task_id: deterministic"

# Different description → different hash
H3=$(compute_task_id "2602140922" "different-description")
assert_neq "$H1" "$H3" \
  "compute_task_id: different inputs produce different hashes"

# Different datetime → different hash
H4=$(compute_task_id "2602140923" "convert-commands-to-scripts")
assert_neq "$H1" "$H4" \
  "compute_task_id: different datetime produces different hash"

# Output is exactly 6 uppercase hex chars
assert_eq "6" "${#ACTUAL_HASH}" \
  "compute_task_id: output is exactly 6 chars"

if [[ "$ACTUAL_HASH" =~ ^[A-F0-9]{6}$ ]]; then
  pass "compute_task_id: output is uppercase hex only"
else
  fail "compute_task_id: output '$ACTUAL_HASH' is not uppercase hex"
fi

# ---- compute_year_month ----

assert_eq "2026-02" "$(compute_year_month "2602140922")" \
  "compute_year_month: Feb 2026"

assert_eq "2026-12" "$(compute_year_month "2612250000")" \
  "compute_year_month: Dec 2026"

assert_eq "2025-01" "$(compute_year_month "2501010000")" \
  "compute_year_month: Jan 2025"

assert_eq "2030-06" "$(compute_year_month "3006151200")" \
  "compute_year_month: June 2030"

# ---- normalize_task_id ----

assert_eq "A3F2B9" "$(normalize_task_id "a3f2b9")" \
  "normalize_task_id: lowercase → uppercase"

assert_eq "A3F2B9" "$(normalize_task_id "A3F2B9")" \
  "normalize_task_id: already uppercase unchanged"

assert_eq "000000" "$(normalize_task_id "000000")" \
  "normalize_task_id: all zeros valid"

assert_eq "FFFFFF" "$(normalize_task_id "ffffff")" \
  "normalize_task_id: all f's → FFFFFF"

# Rejects old 4-digit seqnum format
if normalize_task_id "0001" 2>/dev/null; then
  fail "normalize_task_id: should reject 4-digit seqnum"
else
  pass "normalize_task_id: rejects 4-digit seqnum"
fi

# Rejects non-hex characters
if normalize_task_id "ZZZZZZ" 2>/dev/null; then
  fail "normalize_task_id: should reject non-hex input"
else
  pass "normalize_task_id: rejects non-hex input"
fi

# Rejects 7-char input
if normalize_task_id "A3F2B9C" 2>/dev/null; then
  fail "normalize_task_id: should reject 7-char input"
else
  pass "normalize_task_id: rejects 7-char input"
fi

# Rejects 5-char input
if normalize_task_id "A3F2B" 2>/dev/null; then
  fail "normalize_task_id: should reject 5-char input"
else
  pass "normalize_task_id: rejects 5-char input"
fi

# Rejects empty string
if normalize_task_id "" 2>/dev/null; then
  fail "normalize_task_id: should reject empty string"
else
  pass "normalize_task_id: rejects empty string"
fi
