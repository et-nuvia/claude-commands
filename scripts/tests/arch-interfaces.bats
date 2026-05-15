#!/usr/bin/env bats

# Test suite: arch-interfaces.sh — parallel sub-agent interface design

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    mkdir -p docs/active/2026-05
    cat > docs/active/2026-05/AB12CD-2605141200-ARC-test.md << 'EOF'
# Architecture Review: test

## Grilled Design

### Candidate 1: Foo intake module

- Seam placement: package boundary
- Dependency category: in-process
EOF
    git add docs/active/2026-05/AB12CD-2605141200-ARC-test.md
    git commit -q -m "add ARC fixture"
}

teardown() {
    common_teardown
}

@test "arch-interfaces: --identify locates newest ARC + reports has_grilled=true" {
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --identify
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".section" "identify"
    assert_json_field "$output" ".next_action" "spawn_parallel_subagents"
    assert_json_field "$output" ".task_id" "AB12CD"
    assert_json_field "$output" ".has_grilled" "true"
}

@test "arch-interfaces: has_grilled=false when no Candidate section present" {
    cat > docs/active/2026-05/AB12CD-2605141200-ARC-test.md << 'EOF'
# Architecture Review: test

## Deepening Candidates

### 1. Foo intake module
EOF
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --identify
    assert_valid_json "$output"
    assert_json_field "$output" ".has_grilled" "false"
}

@test "arch-interfaces: --identify accepts explicit --arc-doc" {
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --identify \
        --arc-doc "docs/active/2026-05/AB12CD-2605141200-ARC-test.md"
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
}

@test "arch-interfaces: --identify errors on missing arc-doc" {
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --identify --arc-doc "nope.md"
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-interfaces: --identify errors when no ARC exists" {
    rm -rf docs/active
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --identify
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-interfaces: --full == --identify" {
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --full
    assert_valid_json "$output"
    assert_json_field "$output" ".section" "identify"
}

@test "arch-interfaces: --commit fails with nothing staged" {
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --commit
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-interfaces: --commit succeeds when ARC edited" {
    echo "" >> docs/active/2026-05/AB12CD-2605141200-ARC-test.md
    echo "## Interface Alternatives" >> docs/active/2026-05/AB12CD-2605141200-ARC-test.md
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --commit
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field_present "$output" ".commit_hash"
}

@test "arch-interfaces: unknown section errors" {
    run "$SCRIPTS_DIR/arch-interfaces.sh" --json --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}
