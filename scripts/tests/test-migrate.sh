#!/usr/bin/env bash
# Integration tests for migrate-to-hash-ids.sh
# Run via: ~/.claude/scripts/tests/run-tests.sh test-migrate.sh

# Source functions under test
source "${HOME}/.claude/scripts/common.sh"

MIGRATE_SCRIPT="${HOME}/.claude/scripts/migrate-to-hash-ids.sh"

# ---- Setup: create temp docs dir with sample old-format files ----

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Init as a git repo so git mv works
git -C "$TMPDIR_BASE" init -q
git -C "$TMPDIR_BASE" config user.email "test@test.com"
git -C "$TMPDIR_BASE" config user.name "Test"

mkdir -p "$TMPDIR_BASE/active/0000-0099" "$TMPDIR_BASE/completed/0000-0099"

# Create TSK document for work item 0005
cat > "$TMPDIR_BASE/active/0000-0099/0005-2602140922-TSK-my-task.md" << 'EOF'
# Task: My Task

**Work Item**: 0005
**Created**: 2026-02-14 09:22
**Status**: Active
**Related To**: TSK 0005
EOF

# Create PLN document for same work item (different datetime)
cat > "$TMPDIR_BASE/active/0000-0099/0005-2602140931-PLN-my-task.md" << 'EOF'
# Plan: My Task

**Work Item**: 0005
**Created**: 2026-02-14 09:31
**Status**: Active
**Related To**: TSK 0005
EOF

# Create a completed document for work item 0003
mkdir -p "$TMPDIR_BASE/completed/0000-0099"
cat > "$TMPDIR_BASE/completed/0000-0099/0003-2601150800-TSK-old-task.md" << 'EOF'
# Task: Old Task

**Work Item**: 0003
**Created**: 2026-01-15 08:00
**Status**: Completed
**Related To**: TSK 0003
EOF

# Commit initial state
git -C "$TMPDIR_BASE" add .
git -C "$TMPDIR_BASE" commit -m "init" -q

# ---- Test: dry-run mode ----

"$MIGRATE_SCRIPT" --dry-run "$TMPDIR_BASE" > /dev/null 2>&1
assert_eq 0 $? "dry-run: exits successfully"

# Dry-run must NOT modify original files
assert_true "test -f '$TMPDIR_BASE/active/0000-0099/0005-2602140922-TSK-my-task.md'" \
  "dry-run: original TSK file untouched"
assert_true "test -f '$TMPDIR_BASE/active/0000-0099/0005-2602140931-PLN-my-task.md'" \
  "dry-run: original PLN file untouched"
assert_true "test -f '$TMPDIR_BASE/completed/0000-0099/0003-2601150800-TSK-old-task.md'" \
  "dry-run: completed TSK file untouched"

# ---- Test: actual migration ----

"$MIGRATE_SCRIPT" "$TMPDIR_BASE" > /dev/null 2>&1
assert_eq 0 $? "migration: exits successfully"

# Compute expected hashes
TSK_HASH=$(compute_task_id "2602140922" "my-task")
PLN_HASH=$(compute_task_id "2602140931" "my-task")
OLD_HASH=$(compute_task_id "2601150800" "old-task")

# New files should exist in date-based folders
assert_true "test -f '$TMPDIR_BASE/active/2026-02/${TSK_HASH}-2602140922-TSK-my-task.md'" \
  "migration: TSK moved to date folder with hash name"

assert_true "test -f '$TMPDIR_BASE/active/2026-02/${PLN_HASH}-2602140931-PLN-my-task.md'" \
  "migration: PLN moved to same date folder"

assert_true "test -f '$TMPDIR_BASE/completed/2026-01/${OLD_HASH}-2601150800-TSK-old-task.md'" \
  "migration: completed TSK moved to correct date folder"

# Old files must no longer exist
assert_false "test -f '$TMPDIR_BASE/active/0000-0099/0005-2602140922-TSK-my-task.md'" \
  "migration: old TSK removed"
assert_false "test -f '$TMPDIR_BASE/active/0000-0099/0005-2602140931-PLN-my-task.md'" \
  "migration: old PLN removed"
assert_false "test -f '$TMPDIR_BASE/completed/0000-0099/0003-2601150800-TSK-old-task.md'" \
  "migration: old completed TSK removed"

# Old 0000-0099 folders should be gone (empty after migration)
assert_false "test -d '$TMPDIR_BASE/active/0000-0099'" \
  "migration: old active/0000-0099 folder removed"

# ---- Test: internal content updated ----

TSK_CONTENT=$(cat "$TMPDIR_BASE/active/2026-02/${TSK_HASH}-2602140922-TSK-my-task.md")

assert_contains "$TSK_CONTENT" "**Work Item**: $TSK_HASH" \
  "migration: Work Item field updated to new hash"

assert_not_contains "$TSK_CONTENT" "**Work Item**: 0005" \
  "migration: old seqnum removed from Work Item field"

assert_contains "$TSK_CONTENT" "**Folder**: $TMPDIR_BASE/active/2026-02" \
  "migration: Folder field inserted"

PLN_CONTENT=$(cat "$TMPDIR_BASE/active/2026-02/${PLN_HASH}-2602140931-PLN-my-task.md")

assert_contains "$PLN_CONTENT" "**Work Item**: $PLN_HASH" \
  "migration: PLN Work Item field updated"

assert_not_contains "$PLN_CONTENT" "**Work Item**: 0005" \
  "migration: old seqnum removed from PLN"

# ---- Test: idempotency — re-running migration is a no-op ----

"$MIGRATE_SCRIPT" "$TMPDIR_BASE" > /dev/null 2>&1
assert_eq 0 $? "idempotency: re-run succeeds"

# Files should still be in place
assert_true "test -f '$TMPDIR_BASE/active/2026-02/${TSK_HASH}-2602140922-TSK-my-task.md'" \
  "idempotency: files still in place after re-run"

assert_true "test -f '$TMPDIR_BASE/active/2026-02/${PLN_HASH}-2602140931-PLN-my-task.md'" \
  "idempotency: PLN still in place after re-run"
