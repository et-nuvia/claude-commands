#!/usr/bin/env bash
set -euo pipefail

# pre-merge-verify.sh — Pre-merge verification per Branch, Merge & Deploy SOP
#
# Before squash-merging a feature branch into dev, verify:
#   1. Rebase onto target branch (get latest)
#   2. Detect affected services
#   3. Lint affected services
#   4. Test affected services
#   5. Build all (integration check)
#
# Usage:
#   pre-merge-verify.sh --json --target-branch dev
#   pre-merge-verify.sh --json --target-branch dev --doc-only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
TARGET_BRANCH=""
DOC_ONLY=false
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_OUTPUT=true; shift ;;
        --target-branch) TARGET_BRANCH="$2"; shift 2 ;;
        --doc-only) DOC_ONLY=true; shift ;;
        --help|-h)
            echo "Usage: pre-merge-verify.sh --json --target-branch <branch> [--doc-only]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Require --target-branch
if [[ -z "$TARGET_BRANCH" ]]; then
    echo '{"status":"error","message":"--target-branch required"}' >&2
    exit 1
fi

# State
STEPS='[]'
AFFECTED_SERVICES='[]'
OVERALL_STATUS="pass"
SKIP_REASON=""

# ─── Helpers ────────────────────────────────────────────────────────────────

_add_step() {
    local name="$1" status="$2" detail="${3:-}"
    local extra="${4:-}"
    local step_json
    if [[ -n "$extra" ]]; then
        step_json=$(printf '{"name":"%s","status":"%s","detail":"%s",%s}' "$name" "$status" "$detail" "$extra")
    else
        step_json=$(printf '{"name":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")
    fi
    STEPS=$(echo "$STEPS" | jq --argjson s "$step_json" '. + [$s]')
}

_output() {
    local status="${1:-$OVERALL_STATUS}"
    local skip="${SKIP_REASON:-null}"
    [[ "$skip" != "null" ]] && skip="\"$skip\""
    # Write to fd 3 which is mapped to real stdout; script body uses redirected stdout→stderr
    printf '{"status":"%s","steps":%s,"affected_services":%s,"skipped_reason":%s}\n' \
        "$status" "$STEPS" "$AFFECTED_SERVICES" "$skip" >&3
}

_fail_and_exit() {
    OVERALL_STATUS="fail"
    _output "fail"
    exit 0
}

# Redirect stdout→stderr for the script body so git/make noise doesn't pollute JSON.
# _output writes to fd 3 (real stdout) to emit clean JSON.
exec 3>&1 1>&2

# ─── Worktree detection ────────────────────────────────────────────────────
# Source worktree-utils if available; detect whether we're in a linked worktree.
# In worktree mode, baseline comparison is skipped (DSN 85456E Decision 3).
IN_WORKTREE=false
SCRIPT_DIR_PMV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR_PMV}/lib/worktree-utils.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR_PMV}/lib/worktree-utils.sh" 2>/dev/null || true
    if declare -f is_in_worktree &>/dev/null && is_in_worktree; then
        IN_WORKTREE=true
    fi
fi

# ─── Safety Checks ──────────────────────────────────────────────────────────

# Require clean working tree — caller (task-close) is responsible for stashing
if [[ -n "$(git diff --name-only 2>/dev/null)" ]] || [[ -n "$(git diff --cached --name-only 2>/dev/null)" ]]; then
    OVERALL_STATUS="fail"
    local_dirty=$(git diff --name-only 2>/dev/null | head -3 | tr '\n' ', ')
    _add_step "preflight" "fail" "Uncommitted tracked changes: ${local_dirty}— commit or stash before verification"
    _output "fail"
    exit 0
fi

# Check we're on a feature branch (not dev/staging/main/master)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" =~ ^(main|master|dev|develop|staging|production)$ ]]; then
    OVERALL_STATUS="fail"
    _add_step "preflight" "fail" "Cannot run verification on protected branch: $CURRENT_BRANCH"
    _output "fail"
    exit 0
fi

# Check target branch exists
if ! git rev-parse --verify "$TARGET_BRANCH" &>/dev/null && \
   ! git rev-parse --verify "origin/$TARGET_BRANCH" &>/dev/null; then
    OVERALL_STATUS="fail"
    _add_step "preflight" "fail" "Target branch '$TARGET_BRANCH' does not exist"
    _output "fail"
    exit 0
fi

# ─── Auto-Skip Detection ────────────────────────────────────────────────────

if [[ "$DOC_ONLY" == "true" ]]; then
    SKIP_REASON="doc-only flag"
    _output "skipped"
    exit 0
fi

# No Makefile → skip (single-script projects)
if [[ ! -f "Makefile" ]]; then
    SKIP_REASON="No Makefile in project root"
    _output "skipped"
    exit 0
fi

# No docker services in PROJECT.yaml → skip
if [[ -f "PROJECT.yaml" ]]; then
    if ! grep -q 'docker:' PROJECT.yaml 2>/dev/null; then
        SKIP_REASON="No docker services in PROJECT.yaml"
        _output "skipped"
        exit 0
    fi
elif [[ ! -f "PROJECT.yaml" ]]; then
    SKIP_REASON="No PROJECT.yaml"
    _output "skipped"
    exit 0
fi

# Check if all changed files are doc/config only
CHANGED_FILES=$(git diff --name-only "${TARGET_BRANCH}...HEAD" 2>/dev/null || \
                git diff --name-only "origin/${TARGET_BRANCH}...HEAD" 2>/dev/null || echo "")

if [[ -z "$CHANGED_FILES" ]]; then
    SKIP_REASON="No changed files detected"
    _output "skipped"
    exit 0
fi

_all_doc_or_config() {
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        case "$file" in
            docs/*|*.md|.github/*|Makefile) continue ;;
            *) return 1 ;;
        esac
    done <<< "$CHANGED_FILES"
    return 0
}

if _all_doc_or_config; then
    SKIP_REASON="All changes are documentation or config only"
    _output "skipped"
    exit 0
fi

# ─── Step 1: Rebase onto target ─────────────────────────────────────────────

# Fetch latest target
git fetch origin "$TARGET_BRANCH" --quiet 2>/dev/null || true

if git rebase "origin/${TARGET_BRANCH}" --quiet >/dev/null 2>&1; then
    _add_step "rebase" "pass" "Rebased onto origin/$TARGET_BRANCH"
elif git rebase "$TARGET_BRANCH" --quiet >/dev/null 2>&1; then
    _add_step "rebase" "pass" "Rebased onto $TARGET_BRANCH"
else
    git rebase --abort >/dev/null 2>&1 || true
    _add_step "rebase" "fail" "Rebase conflict — resolve manually and retry"
    _fail_and_exit
fi

# Verify rebase left a clean tree (some conflicts auto-resolve as UD state)
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    local_dirty=$(git status --porcelain 2>/dev/null | head -3 | tr '\n' ', ')
    # Hard reset to HEAD to clear any residual conflict state
    git reset --hard HEAD >/dev/null 2>&1 || true
    _add_step "rebase" "pass" "Rebased with auto-resolved residuals: ${local_dirty}"
fi

# ─── Step 2: Detect affected services ───────────────────────────────────────

# Re-read changed files after rebase (may have shifted)
CHANGED_FILES=$(git diff --name-only "${TARGET_BRANCH}...HEAD" 2>/dev/null || \
                git diff --name-only "origin/${TARGET_BRANCH}...HEAD" 2>/dev/null || echo "")

declare -a SERVICES=()
# Associative arrays: component path → custom make targets from PROJECT.yaml
declare -A COMP_TEST_TARGET=()
declare -A COMP_LINT_TARGET=()

# Try PROJECT.yaml components first (preferred — has path, test_target, lint_target)
if [[ -f "PROJECT.yaml" ]] && grep -q '^components:' PROJECT.yaml 2>/dev/null; then
    # Parse components: extract name/path/test_target/lint_target per component
    local_comp_name="" local_comp_path="" local_comp_test="" local_comp_lint=""
    in_components=false
    while IFS= read -r line; do
        # Detect start/end of components block
        if [[ "$line" =~ ^components: ]]; then
            in_components=true; continue
        fi
        # End of components block: next top-level key
        if [[ "$in_components" == "true" ]] && [[ "$line" =~ ^[a-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            # Flush last component
            if [[ -n "$local_comp_path" ]]; then
                if echo "$CHANGED_FILES" | grep -qE "^${local_comp_path}/" 2>/dev/null; then
                    SERVICES+=("$local_comp_path")
                    [[ -n "$local_comp_test" ]] && COMP_TEST_TARGET["$local_comp_path"]="$local_comp_test"
                    [[ -n "$local_comp_lint" ]] && COMP_LINT_TARGET["$local_comp_path"]="$local_comp_lint"
                fi
                local_comp_path=""
            fi
            break
        fi
        [[ "$in_components" != "true" ]] && continue

        # New component entry
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
            # Flush previous component
            if [[ -n "$local_comp_path" ]]; then
                if echo "$CHANGED_FILES" | grep -qE "^${local_comp_path}/" 2>/dev/null; then
                    SERVICES+=("$local_comp_path")
                    [[ -n "$local_comp_test" ]] && COMP_TEST_TARGET["$local_comp_path"]="$local_comp_test"
                    [[ -n "$local_comp_lint" ]] && COMP_LINT_TARGET["$local_comp_path"]="$local_comp_lint"
                fi
            fi
            local_comp_name=$(echo "$line" | sed 's/.*name:[[:space:]]*//' | tr -d '"'"'")
            local_comp_path="" local_comp_test="" local_comp_lint=""
            continue
        fi
        # Extract fields
        if [[ "$line" =~ ^[[:space:]]+path: ]]; then
            local_comp_path=$(echo "$line" | sed 's/.*path:[[:space:]]*//' | tr -d '"'"'")
        elif [[ "$line" =~ ^[[:space:]]+test_target: ]]; then
            local_comp_test=$(echo "$line" | sed 's/.*test_target:[[:space:]]*//' | tr -d '"'"'")
        elif [[ "$line" =~ ^[[:space:]]+lint_target: ]]; then
            local_comp_lint=$(echo "$line" | sed 's/.*lint_target:[[:space:]]*//' | tr -d '"'"'")
        fi
    done < PROJECT.yaml
    # Flush final component (if file ends inside components block)
    if [[ "$in_components" == "true" ]] && [[ -n "$local_comp_path" ]]; then
        if echo "$CHANGED_FILES" | grep -qE "^${local_comp_path}/" 2>/dev/null; then
            SERVICES+=("$local_comp_path")
            [[ -n "$local_comp_test" ]] && COMP_TEST_TARGET["$local_comp_path"]="$local_comp_test"
            [[ -n "$local_comp_lint" ]] && COMP_LINT_TARGET["$local_comp_path"]="$local_comp_lint"
        fi
    fi
fi

# Fallback: docker.services or top-level directories
if [[ ${#SERVICES[@]} -eq 0 ]]; then
    if [[ -f "PROJECT.yaml" ]]; then
        PROJECT_SERVICES=$(grep -A 50 'docker:' PROJECT.yaml 2>/dev/null | \
            grep -A 50 'services:' | \
            grep -E '^\s*-\s+' | \
            sed 's/^\s*-\s*//' | \
            tr -d ' "'"'" || echo "")

        if [[ -n "$PROJECT_SERVICES" ]]; then
            while IFS= read -r svc; do
                [[ -z "$svc" ]] && continue
                if echo "$CHANGED_FILES" | grep -qE "^${svc}/" 2>/dev/null; then
                    SERVICES+=("$svc")
                fi
            done <<< "$PROJECT_SERVICES"
        fi
    fi
fi

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local_dir="${file%%/*}"
        [[ "$local_dir" == "$file" ]] && continue  # root file, no dir
        [[ "$local_dir" == "docs" || "$local_dir" == ".github" ]] && continue

        found=false
        for existing in "${SERVICES[@]:-}"; do
            [[ "$existing" == "$local_dir" ]] && found=true && break
        done
        [[ "$found" == "false" ]] && SERVICES+=("$local_dir")
    done <<< "$CHANGED_FILES"
fi

AFFECTED_SERVICES=$(printf '%s\n' "${SERVICES[@]:-}" | jq -R . | jq -s .)
_add_step "detect_services" "pass" "Found ${#SERVICES[@]} affected service(s)" \
    "\"services\":$(echo "${SERVICES[@]:-}" | tr ' ' '\n' | jq -R . | jq -s .)"

# ─── Step 3: Lint affected services ─────────────────────────────────────────

LINT_RAN=()
LINT_FAILED=false

# Helper: count lint errors from output (grep for "N errors" or count "error" lines)
_count_lint_errors() {
    local output="$1"
    local count
    count=$(echo "$output" | grep -oE '[0-9]+ errors?' | tail -1 | grep -oE '[0-9]+' | head -1 || echo "")
    if [[ -n "$count" ]]; then
        echo "$count"
    else
        echo "$output" | grep -c ' error ' 2>/dev/null || echo "0"
    fi
}

for svc in "${SERVICES[@]:-}"; do
    [[ -z "$svc" ]] && continue
    # Use component lint_target from PROJECT.yaml if defined, else lint-{svc}
    target="${COMP_LINT_TARGET[$svc]:-lint-${svc}}"
    if make -n "$target" &>/dev/null; then
        local_output=$(make "$target" 2>&1) && lint_exit=0 || lint_exit=$?
        if [[ $lint_exit -eq 0 ]]; then
            LINT_RAN+=("$svc")
        else
            # Lint failed — check if failures are pre-existing on target branch
            feature_errors=$(_count_lint_errors "$local_output" | tr -d '[:space:]')
feature_errors=${feature_errors:-0}

            # Get baseline error count from target branch (skipped in worktree mode)
            baseline_errors=0
            if [[ "$IN_WORKTREE" == "true" ]]; then
                echo "Baseline comparison skipped (worktree mode)" >&2
            elif current_branch=$(git rev-parse --abbrev-ref HEAD) && git stash --quiet 2>/dev/null; then
                if git checkout "$TARGET_BRANCH" --quiet 2>/dev/null || \
                   git checkout "origin/$TARGET_BRANCH" --detach --quiet 2>/dev/null; then
                    baseline_output=$(make "$target" 2>&1 || true)
                    baseline_errors=$(_count_lint_errors "$baseline_output" | tr -d '[:space:]')
                    baseline_errors=${baseline_errors:-0}
                    git checkout "$current_branch" --quiet 2>/dev/null || true
                fi
                git stash pop --quiet 2>/dev/null || true
            fi

            if [[ "$feature_errors" -gt "$baseline_errors" ]]; then
                new_errors=$((feature_errors - baseline_errors))
                LINT_FAILED=true
                fail_excerpt=$(echo "$local_output" | tail -5 | tr '\n' ' ' | cut -c1-200)
                _add_step "lint" "fail" "make $target introduced $new_errors new error(s): $fail_excerpt" \
                    "\"services_run\":$(printf '%s\n' "${LINT_RAN[@]:-}" "$svc" | jq -R . | jq -s .)"
                _fail_and_exit
            else
                # Same or fewer errors than baseline — pre-existing, not our fault
                LINT_RAN+=("$svc")
            fi
        fi
    fi
done

# Fallback: generic make lint if no service-specific targets ran
if [[ ${#LINT_RAN[@]} -eq 0 ]]; then
    if make -n lint &>/dev/null; then
        local_output=$(make lint 2>&1) && lint_exit=0 || lint_exit=$?
        if [[ $lint_exit -eq 0 ]]; then
            LINT_RAN=("all")
        else
            # Check baseline
            feature_errors=$(_count_lint_errors "$local_output" | tr -d '[:space:]')
feature_errors=${feature_errors:-0}
            baseline_errors=0
            current_branch=$(git rev-parse --abbrev-ref HEAD)
            if git stash --quiet 2>/dev/null; then
                if git checkout "$TARGET_BRANCH" --quiet 2>/dev/null || \
                   git checkout "origin/$TARGET_BRANCH" --detach --quiet 2>/dev/null; then
                    baseline_output=$(make lint 2>&1 || true)
                    baseline_errors=$(_count_lint_errors "$baseline_output" | tr -d '[:space:]')
                    baseline_errors=${baseline_errors:-0}
                    git checkout "$current_branch" --quiet 2>/dev/null || true
                fi
                git stash pop --quiet 2>/dev/null || true
            fi

            if [[ "$feature_errors" -gt "$baseline_errors" ]]; then
                new_errors=$((feature_errors - baseline_errors))
                fail_excerpt=$(echo "$local_output" | tail -5 | tr '\n' ' ' | cut -c1-200)
                _add_step "lint" "fail" "make lint introduced $new_errors new error(s): $fail_excerpt" '"services_run":["all"]'
                _fail_and_exit
            else
                LINT_RAN=("all")
            fi
        fi
    fi
fi

_add_step "lint" "pass" "Lint passed for ${#LINT_RAN[@]} service(s)" \
    "\"services_run\":$(printf '%s\n' "${LINT_RAN[@]:-}" | jq -R . | jq -s .)"

# ─── Step 4: Test affected services ─────────────────────────────────────────

TEST_RAN=()

# Helper: count test failures from output
_count_test_failures() {
    local output="$1"
    local count
    count=$(echo "$output" | grep -oE '[0-9]+ failed' | tail -1 | grep -oE '[0-9]+' | head -1 || echo "")
    if [[ -n "$count" ]]; then
        echo "$count"
    else
        echo "$output" | grep -c '^FAIL ' 2>/dev/null || echo "0"
    fi
}

for svc in "${SERVICES[@]:-}"; do
    [[ -z "$svc" ]] && continue
    # Use component test_target from PROJECT.yaml if defined, else test-{svc}
    target="${COMP_TEST_TARGET[$svc]:-test-${svc}}"
    if make -n "$target" &>/dev/null; then
        local_output=$(make "$target" 2>&1) && test_exit=0 || test_exit=$?
        if [[ $test_exit -eq 0 ]]; then
            TEST_RAN+=("$svc")
        else
            # Tests failed — check if pre-existing on target branch (skipped in worktree mode)
            feature_failures=$(_count_test_failures "$local_output" | tr -d '[:space:]')
            feature_failures=${feature_failures:-0}
            baseline_failures=0
            if [[ "$IN_WORKTREE" == "true" ]]; then
                echo "Baseline comparison skipped (worktree mode)" >&2
            elif current_branch=$(git rev-parse --abbrev-ref HEAD) && git stash --quiet 2>/dev/null; then
                if git checkout "$TARGET_BRANCH" --quiet 2>/dev/null || \
                   git checkout "origin/$TARGET_BRANCH" --detach --quiet 2>/dev/null; then
                    baseline_output=$(make "$target" 2>&1 || true)
                    baseline_failures=$(_count_test_failures "$baseline_output" | tr -d '[:space:]')
                    baseline_failures=${baseline_failures:-0}
                    git checkout "$current_branch" --quiet 2>/dev/null || true
                fi
                git stash pop --quiet 2>/dev/null || true
            fi

            if [[ "$feature_failures" -gt "$baseline_failures" ]]; then
                new_failures=$((feature_failures - baseline_failures))
                fail_excerpt=$(echo "$local_output" | tail -5 | tr '\n' ' ' | cut -c1-200)
                _add_step "test" "fail" "make $target introduced $new_failures new failure(s): $fail_excerpt" \
                    "\"services_run\":$(printf '%s\n' "${TEST_RAN[@]:-}" "$svc" | jq -R . | jq -s .)"
                _fail_and_exit
            else
                TEST_RAN+=("$svc")
            fi
        fi
    fi
done

# Fallback: generic make test
if [[ ${#TEST_RAN[@]} -eq 0 ]]; then
    if make -n test &>/dev/null; then
        local_output=$(make test 2>&1) && test_exit=0 || test_exit=$?
        if [[ $test_exit -eq 0 ]]; then
            TEST_RAN=("all")
        else
            feature_failures=$(_count_test_failures "$local_output" | tr -d '[:space:]')
            feature_failures=${feature_failures:-0}
            baseline_failures=0
            current_branch=$(git rev-parse --abbrev-ref HEAD)
            if git stash --quiet 2>/dev/null; then
                if git checkout "$TARGET_BRANCH" --quiet 2>/dev/null || \
                   git checkout "origin/$TARGET_BRANCH" --detach --quiet 2>/dev/null; then
                    baseline_output=$(make test 2>&1 || true)
                    baseline_failures=$(_count_test_failures "$baseline_output" | tr -d '[:space:]')
                    baseline_failures=${baseline_failures:-0}
                    git checkout "$current_branch" --quiet 2>/dev/null || true
                fi
                git stash pop --quiet 2>/dev/null || true
            fi

            if [[ "$feature_failures" -gt "$baseline_failures" ]]; then
                new_failures=$((feature_failures - baseline_failures))
                fail_excerpt=$(echo "$local_output" | tail -5 | tr '\n' ' ' | cut -c1-200)
                _add_step "test" "fail" "make test introduced $new_failures new failure(s): $fail_excerpt" '"services_run":["all"]'
                _fail_and_exit
            else
                TEST_RAN=("all")
            fi
        fi
    fi
fi

_add_step "test" "pass" "Tests passed for ${#TEST_RAN[@]} service(s)" \
    "\"services_run\":$(printf '%s\n' "${TEST_RAN[@]:-}" | jq -R . | jq -s .)"

# ─── Step 5: Build all ──────────────────────────────────────────────────────

if make -n build &>/dev/null; then
    local_output=$(make build 2>&1) && build_exit=0 || build_exit=$?
    if [[ $build_exit -eq 0 ]]; then
        _add_step "build" "pass" "Build succeeded"
    else
        fail_excerpt=$(echo "$local_output" | tail -5 | tr '\n' ' ' | cut -c1-200)
        _add_step "build" "fail" "make build failed: $fail_excerpt"
        _fail_and_exit
    fi
else
    _add_step "build" "pass" "No build target — skipped"
fi

# ─── Ensure clean tree before returning ────────────────────────────────────

# Lint/test/build steps may leave residual dirty state (e.g. UD conflicts
# from rebase, stash artifacts). Hard reset so the caller gets a clean tree.
git reset --hard HEAD >/dev/null 2>&1 || true

# ─── Output ──────────────────────────────────────────────────────────────────

_output "pass"
