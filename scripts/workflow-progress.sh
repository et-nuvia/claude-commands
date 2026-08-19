#!/usr/bin/env bash
# workflow-progress.sh - Track the post-plan closeout workflow for a task.
#
# These stages are NOT part of the plan (PLN) — they are the fixed closeout
# chain a task moves through *after* every plan task is done:
#
#   AUD run → ARC created → CRV created → PR created → PR review done
#
# plan-progress.sh tracks the buildable/testable plan items; once it reports
# pending == 0, callers (e.g. the statusline) invoke THIS script to track the
# remaining workflow. Each stage is checked in order and the network (gh/glab)
# calls are gated so they only fire once the cheaper file-based stages ahead of
# them are satisfied — keeping the common still-reviewing case off the network.
#
# Platform auto-detects: GitHub (gh) on Work/macOS, GitLab (glab) on Home/WSL.
#
# Usage:
#   ~/.claude/scripts/workflow-progress.sh [--json] [--file <pln-path>]
#
# Output (JSON):
#   {"status":"success","task_id":"B28407","workflow":{
#      "aud":bool,"arc":bool,"crv":bool,"pr":bool,"pr_review":bool}}

set -euo pipefail

OUTPUT_MODE="json"
PLN_FILE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/doc-utils.sh"
SECTION="workflow-progress"
source "${SCRIPT_DIR}/lib/output-framework.sh"

#------------------------------------------------------------------------------
# Resolve the task id (sequence) — from --file, else the branch name.
#------------------------------------------------------------------------------
resolve_task_id() {
    # Prefer the leading segment of an explicit PLN filename.
    if [[ -n "$PLN_FILE" ]]; then
        local base
        base=$(basename "$PLN_FILE")
        if [[ "$base" =~ ^([0-9A-Za-z]+)- ]]; then
            echo "${BASH_REMATCH[1]^^}"
            return 0
        fi
    fi

    # Otherwise extract from the branch: feature/XXXX-desc or XXXX-desc.
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "")
    if [[ "$branch" =~ ^[a-zA-Z]+/([0-9A-Fa-f]+)- ]]; then
        echo "${BASH_REMATCH[1]^^}"
        return 0
    elif [[ "$branch" =~ ^([0-9A-Fa-f]+)- ]]; then
        echo "${BASH_REMATCH[1]^^}"
        return 0
    fi
    return 1
}

#------------------------------------------------------------------------------
# A doc of the given type exists for this task (active or completed).
#------------------------------------------------------------------------------
# Skips a directory that does not exist rather than passing it to `find`: a
# missing `docs/completed` (every task worktree before its first `/task-close`)
# makes find exit non-zero, and under `set -o pipefail` that status becomes the
# whole pipeline's — so a doc that WAS found still reported false, and the
# `2>/dev/null` hid the error explaining why. AUD gates the rest of the chain,
# so one missing directory blanked all five indicators. Capturing the output and
# testing it, instead of piping into `grep -q`, keeps a find failure from
# masquerading as "no match".
doc_exists() {
    local seq="$1" type="$2" docs_dir="$3"
    local dir hits
    for dir in "$docs_dir/active" "$docs_dir/completed"; do
        [[ -d "$dir" ]] || continue
        hits=$(find "$dir" -name "${seq}-*-${type}-*.md" 2>/dev/null || true)
        [[ -n "$hits" ]] && return 0
    done
    return 1
}

#------------------------------------------------------------------------------
# PR existence + number for the current branch (GitHub or GitLab).
# Echoes "<pr_exists> <pr_number>" — number empty when no PR/MR found.
#------------------------------------------------------------------------------
check_pr() {
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "")
    [[ -z "$branch" ]] && { echo "false"; return; }

    local num remote
    remote=$(git config --get remote.origin.url 2>/dev/null || echo "")

    # Pick the forge from the remote, not from which CLI happens to be installed.
    # `gh` is present on the Home/WSL box too, so an `if gh / elif glab` chain
    # always took the GitHub branch and silently reported "no PR" for every
    # GitLab MR.
    if [[ "$remote" == *github.com* ]]; then
        if command -v gh >/dev/null 2>&1 \
            && num=$(gh pr view "$branch" --json number -q '.number' 2>/dev/null) \
            && [[ -n "$num" ]]; then
            echo "true $num"
            return
        fi
        echo "false"
        return
    fi

    if command -v glab >/dev/null 2>&1 \
        && num=$(glab mr view "$branch" -F json 2>/dev/null | jq -r '.iid // empty' 2>/dev/null) \
        && [[ -n "$num" ]]; then
        echo "true $num"
        return
    fi

    # glab may be unconfigured for the self-hosted host; fall back to the API.
    local token host project
    if [[ -r "$HOME/.secrets/gitlab-token" && -n "$remote" ]]; then
        token=$(tr -d '[:space:]' < "$HOME/.secrets/gitlab-token")
        host=$(printf '%s' "$remote" | sed -nE 's#^(git@|https?://)([^:/]+)[:/].*#\2#p')
        # Parameter expansion, not sed: the previous pattern used a lazy `(.+?)`,
        # which GNU sed tolerates and BSD sed (macOS) rejects outright with
        # "repetition-operator operand invalid" — and under `set -e` that killed
        # the whole script, so the statusline got nothing at all. Strip scheme,
        # then any user@, then the host, then the optional .git suffix.
        project=${remote#*://}
        project=${project#*@}
        project=${project#*[:/]}
        project=${project%.git}
        if [[ -n "$token" && -n "$host" && -n "$project" ]]; then
            local encoded
            encoded=${project//\//%2F}
            num=$(curl -sf --max-time 5 \
                -H "PRIVATE-TOKEN: ${token}" \
                "https://${host}/api/v4/projects/${encoded}/merge_requests?source_branch=${branch}&state=all&order_by=updated_at" \
                2>/dev/null | jq -r '.[0].iid // empty' 2>/dev/null)
            if [[ -n "$num" ]]; then
                echo "true $num"
                return
            fi
        fi
    fi

    echo "false"
}

#------------------------------------------------------------------------------
# PR review done — a code-review doc keyed by the PR number exists.
# Reviews live in docs/code-reviews/ (e.g. 2026-06-19-pr-020-desc.md), named by
# PR number with optional zero-padding — NOT by task id, so they aren't found by
# the task-id glob used for CRV/AUD.
#------------------------------------------------------------------------------
pr_review_done() {
    local num="$1" docs_dir="$2"
    [[ -z "$num" ]] && return 1
    local dir f n
    for dir in "$docs_dir/code-reviews" "$docs_dir/code-review"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*pr-* "$dir"/*mr-*; do
            [[ -e "$f" ]] || continue
            # Extract the number after 'pr-'/'mr-', dropping any zero padding.
            n=$(basename "$f" | sed -nE 's/.*[pm]r-0*([0-9]+).*/\1/p')
            [[ "$n" == "$num" ]] && return 0
        done
    done
    return 1
}

#------------------------------------------------------------------------------
# Emit JSON
#------------------------------------------------------------------------------
emit() {
    local status="$1" seq="$2" aud="$3" arc="$4" crv="$5" pr="$6" review="$7"
    log_json "$(cat <<EOF
{
  "status": "$status",
  "task_id": "$seq",
  "workflow": {
    "aud": $aud,
    "arc": $arc,
    "crv": $crv,
    "pr": $pr,
    "pr_review": $review
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
        --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --file) PLN_FILE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

seq=$(resolve_task_id) || { emit "error" "" false false false false false; exit 0; }

docs_dir=$(find_docs_dir 2>/dev/null) || true
[[ -z "$docs_dir" ]] && { emit "error" "$seq" false false false false false; exit 0; }

aud=false arc=false crv=false pr=false review=false

# The three document stages are checked INDEPENDENTLY, not as a nested chain.
# They are produced in any order — /task-post-work writes ARC and CRV from
# subagent findings while a slow task-audit (full suite + coverage) is still
# running, so a nested `if AUD then ARC then CRV` reported arc=false crv=false
# with both docs sitting on disk. The statusline renders each stage by name
# specifically so out-of-order completion stays visible; nesting defeated that.
#   AUD · ARC · CRV  (independent)  →  PR → review (sequential)
doc_exists "$seq" "AUD" "$docs_dir" && aud=true
doc_exists "$seq" "ARC" "$docs_dir" && arc=true
doc_exists "$seq" "CRV" "$docs_dir" && crv=true

# The platform query STAYS gated behind all three docs — that was the real
# reason for the original chain (don't hit gh/glab over the network on every
# statusline render). PR → review remains sequential because the review lookup
# needs the PR number.
if [[ "$aud" == "true" && "$arc" == "true" && "$crv" == "true" ]]; then
    read -r pr prnum < <(check_pr)
    if [[ "$pr" == "true" ]]; then
        pr_review_done "$prnum" "$docs_dir" && review=true
    fi
fi

emit "success" "$seq" "$aud" "$arc" "$crv" "$pr" "$review"
