#!/usr/bin/env bats

# Test suite: New shared libraries (Phase 1)
#
# Tests: logging.sh, project-knowledge.sh, branching.sh, yaml.sh enhancements

load test_helper

setup() {
    common_setup
    SCRIPTS_DIR="${BATS_TEST_DIRNAME}/.."
    LIB_DIR="${SCRIPTS_DIR}/lib"
}

teardown() {
    common_teardown
}

# =============================================================================
# Syntax validation for all new libraries
# =============================================================================

@test "lib: logging.sh passes bash -n" {
    bash -n "$LIB_DIR/logging.sh"
}

@test "lib: project-knowledge.sh passes bash -n" {
    bash -n "$LIB_DIR/project-knowledge.sh"
}

@test "lib: task-tracker-sync.sh passes bash -n" {
    bash -n "$LIB_DIR/task-tracker-sync.sh"
}

@test "lib: branching.sh passes bash -n" {
    bash -n "$LIB_DIR/branching.sh"
}

@test "lib: output-framework.sh passes bash -n" {
    bash -n "$LIB_DIR/output-framework.sh"
}

@test "lib: yaml.sh passes bash -n" {
    bash -n "$LIB_DIR/yaml.sh"
}

# =============================================================================
# Double-source guards
# =============================================================================

@test "lib: logging.sh has double-source guard" {
    grep -q '_LOGGING_LOADED' "$LIB_DIR/logging.sh"
}

@test "lib: project-knowledge.sh has double-source guard" {
    grep -q '_PROJECT_KNOWLEDGE_LOADED' "$LIB_DIR/project-knowledge.sh"
}

@test "lib: task-tracker-sync.sh has double-source guard" {
    grep -q '_TASK_TRACKER_SYNC_LOADED' "$LIB_DIR/task-tracker-sync.sh"
}

@test "lib: branching.sh has double-source guard" {
    grep -q '_BRANCHING_LOADED' "$LIB_DIR/branching.sh"
}

@test "lib: output-framework.sh has double-source guard" {
    grep -q '_OUTPUT_FRAMEWORK_LOADED' "$LIB_DIR/output-framework.sh"
}

# =============================================================================
# Task-close helpers syntax and guards
# =============================================================================

@test "lib: task-close-impl.sh passes bash -n" {
    bash -n "$LIB_DIR/task-close-impl.sh"
}

@test "lib: task-close-impl.sh has double-source guard" {
    grep -q '_TASK_CLOSE_IMPL_LOADED' "$LIB_DIR/task-close-impl.sh" \
        || { echo "task-close-impl.sh missing double-source guard" >&2; return 1; }
}

@test "lib: task-close-impl.sh exports the section functions" {
    for fn in section_identify section_complete section_defer \
              section_extract_summary_data section_create_summary \
              section_pre_verify section_cleanup; do
        if ! grep -q "^${fn}()" "$LIB_DIR/task-close-impl.sh"; then
            echo "task-close-impl.sh missing function: $fn" >&2
            return 1
        fi
    done
}

# =============================================================================
# Logging library functions
# =============================================================================

@test "lib: logging.sh exports all 5 log functions" {
    local funcs=(log_info log_success log_error log_warn log_debug)
    for func in "${funcs[@]}"; do
        if ! grep -q "^${func}()" "$LIB_DIR/logging.sh"; then
            echo "Missing function: $func" >&2
            return 1
        fi
    done
}

@test "lib: logging.sh suppresses output in json mode" {
    result=$(OUTPUT_MODE=json bash -c 'source "'"$LIB_DIR/logging.sh"'"; log_info "test"' 2>&1)
    [ -z "$result" ]
}

# =============================================================================
# Project Knowledge library
# =============================================================================

@test "lib: project-knowledge.sh exports pk_ functions" {
    local funcs=(pk_exists pk_load_full pk_load_section pk_load_subsection pk_set_path)
    for func in "${funcs[@]}"; do
        if ! grep -q "^${func}()" "$LIB_DIR/project-knowledge.sh"; then
            echo "Missing function: $func" >&2
            return 1
        fi
    done
}

# =============================================================================
# yaml.sh enhancements
# =============================================================================

@test "lib: yaml.sh has yaml_get_array function" {
    grep -q '^yaml_get_array()' "$LIB_DIR/yaml.sh"
}

# =============================================================================
# Output framework sources logging
# =============================================================================

@test "lib: output-framework.sh sources logging.sh" {
    grep -q 'source.*logging.sh' "$LIB_DIR/output-framework.sh"
}

@test "lib: output-framework.sh documents valid status values" {
    grep -q 'Valid status values' "$LIB_DIR/output-framework.sh"
}

@test "lib: output-framework.sh documents valid next_action values" {
    grep -q 'Valid next_action values' "$LIB_DIR/output-framework.sh"
}

# =============================================================================
# Branching library
# =============================================================================

@test "lib: branching.sh exports branch functions" {
    local funcs=(get_feature_branch_prefix create_feature_branch detect_merge_target)
    for func in "${funcs[@]}"; do
        if ! grep -q "^${func}()" "$LIB_DIR/branching.sh"; then
            echo "Missing function: $func" >&2
            return 1
        fi
    done
}

# =============================================================================
# Task tracker sync library
# =============================================================================

@test "lib: task-tracker-sync.sh exports tracker functions" {
    local funcs=(tracker_detect tracker_sync_status tracker_sync_comment tracker_sync_close)
    for func in "${funcs[@]}"; do
        if ! grep -q "^${func}()" "$LIB_DIR/task-tracker-sync.sh"; then
            echo "Missing function: $func" >&2
            return 1
        fi
    done
}
