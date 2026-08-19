#!/usr/bin/env bash
# gh-runs.sh - Deterministic GitHub Actions run selection.
#
# WHY THIS EXISTS
# A commit usually triggers more than one workflow. Selecting "the newest run on
# the branch" — or even "the newest run for this SHA" — therefore picks an
# arbitrary workflow. In one real incident a production deploy watched a
# "Dependabot Updates" run instead of "Deploy to Production" (same SHA, three
# Dependabot runs queued alongside it) and reported its conclusion as the
# deploy's. The dangerous direction is a fast noise workflow going green while
# the deploy is still running: the caller sees success and proceeds to tag and
# promote a deploy that has not finished.
#
# The rule here: name the workflow you mean, take the newest run PER workflow
# (so re-runs supersede), and require every watched run to succeed.
#
# All selection is pure jq over a runs JSON array, so it is testable from
# fixtures without calling gh.
#
# Patterns for include/exclude are unanchored, case-insensitive regexes.
# Anchor them (^Deploy to Production$) when a substring would over-match.

# Fields every consumer needs. Kept in one place so callers cannot fetch a
# subset that breaks the jq below.
GH_RUNS_FIELDS="databaseId,headSha,workflowName,status,conclusion,createdAt,event,url"

# gh_runs_fetch <branch> [limit]
# Emits a JSON array of recent runs for the branch.
gh_runs_fetch() {
  local branch="$1"
  local limit="${2:-50}"
  gh run list --branch "$branch" --limit "$limit" --json "$GH_RUNS_FIELDS" 2>/dev/null || echo '[]'
}

# gh_runs_select <sha> <include_patterns> <exclude_patterns>
# Reads a runs JSON array on stdin, writes the selected runs as a JSON array.
# Patterns are newline-separated; empty means "no constraint".
#
# Order of operations:
#   1. keep only runs for <sha> (when given)
#   2. if include patterns exist, keep only matching workflows
#      else drop workflows matching the exclude patterns
#   3. collapse to the newest run per workflow (re-runs win)
gh_runs_select() {
  local sha="${1:-}"
  local include="${2:-}"
  local exclude="${3:-}"

  jq \
    --arg sha "$sha" \
    --arg include "$include" \
    --arg exclude "$exclude" '
    def to_patterns($s): $s | split("\n") | map(select(length > 0));
    def matches_any($name; $pats): $pats | any(. as $p | ($name | test($p; "i")));

    to_patterns($include) as $inc
    | to_patterns($exclude) as $exc
    | map(select($sha == "" or .headSha == $sha))
    | (if ($inc | length) > 0
       then map(select(matches_any(.workflowName; $inc)))
       else map(select(matches_any(.workflowName; $exc) | not))
       end)
    | group_by(.workflowName)
    | map(sort_by(.createdAt) | last)
    | sort_by(.workflowName)
  '
}

# gh_runs_aggregate
# Reads a selected-runs JSON array on stdin, writes one word:
#   none      nothing matched yet (keep waiting — never treat as success)
#   running   at least one watched run has not completed
#   failure   at least one watched run failed / timed out / failed to start
#   cancelled at least one watched run was cancelled (and none failed)
#   success   every watched run finished acceptably
#
# "none" is deliberately distinct from "success": a filter that matches nothing
# must not read as a green deploy.
gh_runs_aggregate() {
  jq -r '
    if length == 0 then "none"
    elif any(.status != "completed") then "running"
    elif any(.conclusion | IN("failure", "timed_out", "startup_failure")) then "failure"
    elif any(.conclusion == "cancelled") then "cancelled"
    else "success"
    end
  '
}

# gh_runs_failed_jobs <run_id>
# Comma-separated names of the failed jobs in a run.
gh_runs_failed_jobs() {
  local run_id="$1"
  gh run view "$run_id" --json jobs \
    -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null \
    | tr '\n' ',' | sed 's/,$//'
}

# gh_runs_describe
# Reads a selected-runs JSON array, writes "workflow=<name> status=<s> id=<id>"
# per line — so a caller can always show WHICH runs a verdict came from.
gh_runs_describe() {
  jq -r '.[] | "workflow=\(.workflowName) status=\(.status)/\(.conclusion // "pending") id=\(.databaseId)"'
}
