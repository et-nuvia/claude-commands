#!/usr/bin/env bats

# Test suite for lib/gh-runs.sh — deterministic GitHub Actions run selection.
#
# The fixture reproduces the shape that misled a production deploy: one commit
# with several workflows, the noise workflow newer than the deploy workflow, and
# repeated runs of that noise workflow.

load test_helper

setup() {
    common_setup
    source "$SCRIPTS_DIR/lib/gh-runs.sh"

    FIXTURE='[
      {"databaseId":3,"headSha":"aaa","workflowName":"Dependabot Updates","status":"completed","conclusion":"success","createdAt":"2026-08-04T23:05:14Z","event":"push","url":"u3"},
      {"databaseId":2,"headSha":"aaa","workflowName":"Dependabot Updates","status":"completed","conclusion":"success","createdAt":"2026-08-04T23:04:04Z","event":"push","url":"u2"},
      {"databaseId":1,"headSha":"aaa","workflowName":"Deploy to Production","status":"completed","conclusion":"success","createdAt":"2026-08-04T23:03:53Z","event":"push","url":"u1"},
      {"databaseId":0,"headSha":"bbb","workflowName":"Deploy to Production","status":"completed","conclusion":"failure","createdAt":"2026-08-04T22:00:00Z","event":"push","url":"u0"}
    ]'
}

teardown() {
    common_teardown
}

@test "gh-runs: selects the named workflow, not the newest run for the SHA" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '^Deploy to Production\$' ''; } | jq -r '.[].databaseId'"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "gh-runs: excluding noise leaves only the deploy workflow" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '' 'Dependabot Updates'; } | jq -r '.[].databaseId'"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "gh-runs: collapses repeated runs of one workflow to the newest" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' 'Dependabot' ''; } | jq -r 'length, .[0].databaseId'"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "1" ]
    [ "${lines[1]}" = "3" ]
}

@test "gh-runs: filters by SHA so a prior commit's run cannot match" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'bbb' '^Deploy to Production\$' ''; } | jq -r '.[].databaseId'"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "gh-runs: a filter matching nothing aggregates to none, never success" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '^No Such Workflow\$' '' | gh_runs_aggregate; }"
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "gh-runs: an unknown SHA aggregates to none, never success" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'zzz' '' '' | gh_runs_aggregate; }"
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "gh-runs: all watched runs succeeding aggregates to success" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '' '' | gh_runs_aggregate; }"
    [ "$status" -eq 0 ]
    [ "$output" = "success" ]
}

@test "gh-runs: a still-running deploy is not masked by a finished noise run" {
    # The dangerous case: noise workflow already green, deploy still going.
    # Reporting success here would let a caller tag a deploy mid-flight.
    local running='[
      {"databaseId":3,"headSha":"aaa","workflowName":"Dependabot Updates","status":"completed","conclusion":"success","createdAt":"2026-08-04T23:05:14Z","event":"push","url":"u3"},
      {"databaseId":1,"headSha":"aaa","workflowName":"Deploy to Production","status":"in_progress","conclusion":null,"createdAt":"2026-08-04T23:03:53Z","event":"push","url":"u1"}
    ]'
    run bash -c "printf '%s' '$running' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '' '' | gh_runs_aggregate; }"
    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
}

@test "gh-runs: one failing workflow fails the whole verdict" {
    local mixed='[
      {"databaseId":3,"headSha":"aaa","workflowName":"Lint","status":"completed","conclusion":"success","createdAt":"2026-08-04T23:05:14Z","event":"push","url":"u3"},
      {"databaseId":1,"headSha":"aaa","workflowName":"Deploy to Production","status":"completed","conclusion":"failure","createdAt":"2026-08-04T23:03:53Z","event":"push","url":"u1"}
    ]'
    run bash -c "printf '%s' '$mixed' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '' '' | gh_runs_aggregate; }"
    [ "$status" -eq 0 ]
    [ "$output" = "failure" ]
}

@test "gh-runs: skipped and neutral conclusions still count as success" {
    local skipped='[
      {"databaseId":1,"headSha":"aaa","workflowName":"Deploy","status":"completed","conclusion":"skipped","createdAt":"2026-08-04T23:03:53Z","event":"push","url":"u1"}
    ]'
    run bash -c "printf '%s' '$skipped' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '' '' | gh_runs_aggregate; }"
    [ "$status" -eq 0 ]
    [ "$output" = "success" ]
}

@test "gh-runs: timed_out is treated as failure" {
    local timed='[
      {"databaseId":1,"headSha":"aaa","workflowName":"Deploy","status":"completed","conclusion":"timed_out","createdAt":"2026-08-04T23:03:53Z","event":"push","url":"u1"}
    ]'
    run bash -c "printf '%s' '$timed' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '' '' | gh_runs_aggregate; }"
    [ "$status" -eq 0 ]
    [ "$output" = "failure" ]
}

@test "gh-runs: empty sha matches every run (branch-wide view)" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select '' '^Deploy to Production\$' ''; } | jq -r 'length'"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "gh-runs: describe names the workflow behind a verdict" {
    run bash -c "printf '%s' '$FIXTURE' | { source '$SCRIPTS_DIR/lib/gh-runs.sh'; gh_runs_select 'aaa' '^Deploy to Production\$' '' | gh_runs_describe; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workflow=Deploy to Production"* ]]
    [[ "$output" == *"id=1"* ]]
}
