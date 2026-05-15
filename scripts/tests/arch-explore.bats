#!/usr/bin/env bats

# Test suite: arch-explore.sh — discovery of architectural deepening candidates

load test_helper

setup() {
    common_setup
    setup_mock_git_repo
}

teardown() {
    common_teardown
}

@test "arch-explore: --check returns valid JSON with branch + adr metadata" {
    run "$SCRIPTS_DIR/arch-explore.sh" --json --check
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".section" "check"
    assert_json_field "$output" ".next_action" "spawn_explore_subagent"
    assert_json_field_present "$output" ".branch"
    assert_json_field_present "$output" ".adr_files"
    assert_json_field_present "$output" ".language_template"
    assert_json_field_present "$output" ".deepening_template"
}

@test "arch-explore: --check reports knowledge_present=false when missing" {
    run "$SCRIPTS_DIR/arch-explore.sh" --json --check
    assert_valid_json "$output"
    assert_json_field "$output" ".knowledge_present" "false"
}

@test "arch-explore: --check reports knowledge_present=true when file exists" {
    mkdir -p docs/architecture
    echo "# knowledge" > docs/architecture/PROJECT-KNOWLEDGE.md
    run "$SCRIPTS_DIR/arch-explore.sh" --json --check
    assert_valid_json "$output"
    assert_json_field "$output" ".knowledge_present" "true"
}

@test "arch-explore: --check lists ADR files when docs/adr/ populated" {
    mkdir -p docs/adr
    echo "# ADR 1" > docs/adr/0001-foo.md
    echo "# ADR 2" > docs/adr/0002-bar.md
    run "$SCRIPTS_DIR/arch-explore.sh" --json --check
    assert_valid_json "$output"
    local count
    count=$(echo "$output" | jq -r '.adr_files | length')
    [ "$count" = "2" ]
}

@test "arch-explore: errors outside git repo" {
    common_teardown
    common_setup
    run "$SCRIPTS_DIR/arch-explore.sh" --json --check
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "arch-explore: --full == --check by default" {
    run "$SCRIPTS_DIR/arch-explore.sh" --json --full
    assert_valid_json "$output"
    assert_json_field "$output" ".section" "check"
}

@test "arch-explore: unknown section errors" {
    run "$SCRIPTS_DIR/arch-explore.sh" --json --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

@test "arch-explore: --create-doc returns ARC path + template" {
    run "$SCRIPTS_DIR/arch-explore.sh" --json --create-doc --description "deepening-pass"
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".section" "create-doc"
    assert_json_field "$output" ".next_action" "fill_document"
    assert_json_field_present "$output" ".arc_path"
    assert_json_field_present "$output" ".template"
    local arc_path
    arc_path=$(echo "$output" | jq -r '.arc_path')
    [[ "$arc_path" == *"-ARC-deepening-pass.md" ]]
}

@test "arch-explore: --commit fails when no ARC doc exists" {
    run "$SCRIPTS_DIR/arch-explore.sh" --json --commit
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}
