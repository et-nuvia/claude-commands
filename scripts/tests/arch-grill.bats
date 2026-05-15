#!/usr/bin/env bats

# Test suite: arch-grill.sh — grilling a deepening candidate

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    # Create a dummy ARC doc so --identify has something to find
    mkdir -p docs/active/2026-05
    cat > docs/active/2026-05/AB12CD-2605141200-ARC-test.md << 'EOF'
# Architecture Review: test

## Deepening Candidates

### 1. Foo intake module
- Files: src/foo.py
- Problem: shallow pass-through
EOF
    git add docs/active/2026-05/AB12CD-2605141200-ARC-test.md
    git commit -q -m "add ARC fixture"
}

teardown() {
    common_teardown
}

@test "arch-grill: --identify locates newest ARC doc" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --identify
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".section" "identify"
    assert_json_field "$output" ".next_action" "run_grilling_loop"
    assert_json_field "$output" ".task_id" "AB12CD"
    assert_json_field_present "$output" ".arc_body"
}

@test "arch-grill: --identify accepts explicit --arc-doc" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --identify \
        --arc-doc "docs/active/2026-05/AB12CD-2605141200-ARC-test.md"
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".task_id" "AB12CD"
}

@test "arch-grill: --identify errors on missing --arc-doc path" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --identify --arc-doc "nope.md"
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-grill: --identify errors when no ARC doc exists" {
    rm -rf docs/active
    run "$SCRIPTS_DIR/arch-grill.sh" --json --identify
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-grill: --save-state writes valid JSON checkpoint" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --save-state --candidate 1 \
        --decisions '[{"topic":"seam-placement","choice":"package boundary"}]'
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    [ -f .arch-grill-state.json ]
    run jq -r '.task_id' .arch-grill-state.json
    [ "$output" = "AB12CD" ]
}

@test "arch-grill: --save-state rejects invalid JSON decisions" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --save-state --decisions 'not-json'
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-grill: --load-state returns empty decisions when no state" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --load-state
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".section" "load-state"
}

@test "arch-grill: --load-state ignores state from a different task" {
    echo '{"task_id":"ZZ9999","candidate":"1","decisions":[]}' > .arch-grill-state.json
    run "$SCRIPTS_DIR/arch-grill.sh" --json --load-state
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field_present "$output" ".warning"
}

@test "arch-grill: --write-adr creates docs/adr/0001-<slug>.md" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --write-adr \
        --slug "no-deepening-foo" \
        --reason "Foo intake intentionally pass-through to keep on-call surface area small."
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".adr_number" "0001"
    [ -f docs/adr/0001-no-deepening-foo.md ]
    run grep -q "No Deepening Foo" docs/adr/0001-no-deepening-foo.md
    [ "$status" -eq 0 ]
    run grep -q "intentionally pass-through" docs/adr/0001-no-deepening-foo.md
    [ "$status" -eq 0 ]
}

@test "arch-grill: --write-adr increments ADR number" {
    mkdir -p docs/adr
    : > docs/adr/0001-existing.md
    : > docs/adr/0002-another.md
    run "$SCRIPTS_DIR/arch-grill.sh" --json --write-adr \
        --slug "third" --reason "load-bearing reason"
    assert_valid_json "$output"
    assert_json_field "$output" ".adr_number" "0003"
    [ -f docs/adr/0003-third.md ]
}

@test "arch-grill: --write-adr rejects invalid slug" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --write-adr \
        --slug "Bad Slug" --reason "x"
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-grill: --write-adr requires reason" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --write-adr --slug "foo-bar"
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-grill: --commit fails with nothing staged" {
    run "$SCRIPTS_DIR/arch-grill.sh" --json --commit
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-grill: --commit succeeds when ARC edited" {
    echo "" >> docs/active/2026-05/AB12CD-2605141200-ARC-test.md
    echo "## Grilled Design" >> docs/active/2026-05/AB12CD-2605141200-ARC-test.md
    run "$SCRIPTS_DIR/arch-grill.sh" --json --commit
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field_present "$output" ".commit_hash"
}
