#!/usr/bin/env bash
# git-platforms/github.sh — GitHub adapter for the git platform contract.
#
# Uses the gh CLI (https://cli.github.com/) for everything except logs,
# which use both gh and direct API access. Requires gh to be installed
# and authenticated (`gh auth status`).
#
# Don't source this file directly — go through scripts/lib/git-api.sh.

if ! command -v gh >/dev/null 2>&1; then
  echo "git-platforms/github.sh: gh CLI not installed" >&2
  return 1
fi

# Repo identifier: gh CLI auto-detects from cwd, but allow override.
# PROJECT.yaml .git.repo wins, then current directory.
_github_repo() {
  if [[ -f PROJECT.yaml ]]; then
    local r
    r=$(yaml_get '.git.repo' PROJECT.yaml 2>/dev/null || true)
    if [[ -n "$r" && "$r" != "null" ]]; then
      echo "$r"
      return
    fi
  fi
  # Empty = gh auto-detect
  echo ""
}

# Pass --repo to gh when we have an explicit repo, otherwise let gh
# auto-detect from cwd.
_gh() {
  local repo
  repo=$(_github_repo)
  if [[ -n "$repo" ]]; then
    gh --repo "$repo" "$@"
  else
    gh "$@"
  fi
}

# Run a gh command and translate "resource not found" exits into exit 2
# (per the contract). Other errors remain exit 1.
_gh_get() {
  local stderr
  stderr=$(mktemp)
  trap 'rm -f "$stderr"' RETURN
  if _gh "$@" 2>"$stderr"; then
    return 0
  fi
  local rc=$?
  if grep -qiE "could not resolve|not found|no .* found" "$stderr"; then
    return 2
  fi
  cat "$stderr" >&2
  return "$rc"
}

# Parse a numeric resource id from a gh-printed URL.
# gh CLI prints URLs in the canonical form .../issues/42, .../pull/42,
# .../actions/runs/42 — always ending in a numeric id. Validate the
# extracted value strictly so we error out instead of silently using "".
_gh_parse_id_from_url() {
  local url="$1"
  local num="${url##*/}"
  if [[ ! "$num" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  echo "$num"
}

# Map gh run conclusion+status into the normalized contract value.
_github_normalize_status() {
  local status="$1" conclusion="$2"
  if [[ "$status" != "completed" ]]; then
    echo "running"
    return
  fi
  case "$conclusion" in
    success)            echo "success" ;;
    failure|timed_out)  echo "failed" ;;
    cancelled|skipped)  echo "cancelled" ;;
    *)                  echo "unknown" ;;
  esac
}

# ----------------------------------------------------------------------
# Issues
# ----------------------------------------------------------------------

git_issue_get() {
  local id="${1:?id required}"
  local raw
  raw=$(_gh_get issue view "$id" --json number,title,state,assignees,labels,url,body) || return $?
  jq -c '{
    id: .number, title: .title, state: (.state | ascii_downcase),
    assignee: (.assignees[0].login // null),
    labels: (.labels | map(.name)),
    url: .url, raw: .
  }' <<<"$raw"
}

git_issue_list() {
  local state="open" assignee_arg=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)    state="$2"; shift 2 ;;
      --assignee) assignee_arg=(--assignee "$2"); shift 2 ;;
      *)          shift ;;
    esac
  done
  _gh issue list --state "$state" "${assignee_arg[@]}" --limit 100 \
       --json number,title,state,assignees,labels,url \
    | jq -c '[.[] | {
        id: .number, title: .title, state: (.state | ascii_downcase),
        assignee: (.assignees[0].login // null),
        labels: (.labels | map(.name)),
        url: .url, raw: .
      }]'
}

git_issue_create() {
  local title="${1:?title required}" body="${2:-}"
  local url num
  url=$(_gh issue create --title "$title" --body "$body") || return $?
  num=$(_gh_parse_id_from_url "$url") || {
    echo "git_issue_create: created issue but could not parse id from url '$url'" >&2
    return 1
  }
  jq -nc --arg id "$num" --arg url "$url" '{id: ($id | tonumber), url: $url}'
}

git_issue_close() {
  local id="${1:?id required}" comment="${2:-}"
  if [[ -n "$comment" ]]; then
    _gh issue close "$id" --comment "$comment" >/dev/null
  else
    _gh issue close "$id" >/dev/null
  fi
}

git_issue_comment() {
  local id="${1:?id required}" body="${2:?body required}"
  _gh issue comment "$id" --body "$body" >/dev/null
}

git_issue_label_add() {
  local id="${1:?id required}" label="${2:?label required}"
  _gh issue edit "$id" --add-label "$label" >/dev/null
}

# ----------------------------------------------------------------------
# Pull requests
# ----------------------------------------------------------------------

git_pr_find_for_branch() {
  local branch="${1:?branch required}"
  local raw
  raw=$(_gh pr list --head "$branch" --state open --limit 1 \
        --json number,title,state,url) || return $?
  local first
  first=$(jq -c '.[0] // empty' <<<"$raw")
  [[ -z "$first" ]] && return 2
  jq -c '{id: .number, title: .title, state: (.state | ascii_downcase), url: .url}' <<<"$first"
}

git_pr_create() {
  local title="${1:?title required}" body="${2:-}" base="${3:-}"
  local args=(--title "$title" --body "$body")
  [[ -n "$base" ]] && args+=(--base "$base")
  local url num
  url=$(_gh pr create "${args[@]}") || return $?
  num=$(_gh_parse_id_from_url "$url") || {
    echo "git_pr_create: created PR but could not parse id from url '$url'" >&2
    return 1
  }
  jq -nc --arg id "$num" --arg url "$url" '{id: ($id | tonumber), url: $url}'
}

# ----------------------------------------------------------------------
# Workflow runs (GitHub Actions)
# ----------------------------------------------------------------------

git_pipeline_list() {
  local ref="" sha="" limit=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref)   ref="$2";   shift 2 ;;
      --sha)   sha="$2";   shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done

  local args=(--limit "$limit"
              --json databaseId,status,conclusion,headSha,headBranch,url,createdAt)
  [[ -n "$ref" ]] && args+=(--branch "$ref")
  local raw
  raw=$(_gh run list "${args[@]}") || return $?

  # GitHub doesn't accept --sha filter on `gh run list`; filter post-hoc.
  if [[ -n "$sha" ]]; then
    raw=$(jq --arg sha "$sha" '[.[] | select(.headSha == $sha)]' <<<"$raw")
  fi

  jq -c '[.[] | {
    id: .databaseId,
    status: (
      if .status != "completed" then "running"
      elif .conclusion == "success" then "success"
      elif .conclusion == "failure" or .conclusion == "timed_out" then "failed"
      elif .conclusion == "cancelled" or .conclusion == "skipped" then "cancelled"
      else "unknown" end),
    sha: .headSha, ref: .headBranch, url: .url, created_at: .createdAt, raw: .
  }]' <<<"$raw"
}

git_pipeline_status() {
  local id="${1:?id required}"
  local raw jobs status conclusion normalized
  raw=$(_gh_get run view "$id" --json databaseId,status,conclusion,jobs,url) || return $?
  status=$(jq -r .status <<<"$raw")
  conclusion=$(jq -r '.conclusion // ""' <<<"$raw")
  normalized=$(_github_normalize_status "$status" "$conclusion")
  jq -c --arg status "$normalized" '{
    id: .databaseId,
    status: $status,
    conclusion: (if .status == "completed" then .conclusion else null end),
    jobs: (.jobs | map({id: .databaseId, name: .name, status: .status, conclusion: .conclusion, url: .url})),
    raw: .
  }' <<<"$raw"
}

git_pipeline_logs() {
  local id="${1:?id required}" job_name="${2:-}"
  if [[ -n "$job_name" ]]; then
    # Find the job ID by name, then view its log
    local job_id
    job_id=$(_gh run view "$id" --json jobs \
             | jq -r --arg n "$job_name" '.jobs[] | select(.name == $n) | .databaseId' | head -1)
    if [[ -z "$job_id" ]]; then
      echo "git_pipeline_logs: no job named '$job_name' in run $id" >&2
      return 2
    fi
    _gh run view "$id" --job "$job_id" --log
  else
    _gh run view "$id" --log
  fi
}

# ----------------------------------------------------------------------
# Health
# ----------------------------------------------------------------------

git_health() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "git_health(github): gh CLI not authenticated (run: gh auth login)" >&2
    return 1
  fi
  return 0
}
