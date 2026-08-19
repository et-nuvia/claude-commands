#!/usr/bin/env bash
set -euo pipefail

# Capture raw GitHub Actions timing data (runs + jobs + steps) to JSONL for
# later offline analysis by ci-metrics-analyze.py.
#
# Deliberately dumb: it fetches and stores, it does not interpret. Re-running is
# incremental — runs already captured are skipped — so a long history can be
# built up cheaply and the analyzer re-run as often as wanted without paying the
# API cost again.
#
# Usage:
#   ci-metrics-capture.sh [--repo owner/name] [--days 30] [--max-runs 300]
#                         [--workflow ci.yml] [--branch dev] [--out DIR]
#                         [--refresh] [--json]

REPO=""
DAYS=30
MAX_RUNS=300
WORKFLOW=""
BRANCH=""
OUT_DIR=""
REFRESH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --days)      DAYS="$2"; shift 2 ;;
    --max-runs)  MAX_RUNS="$2"; shift 2 ;;
    --workflow)  WORKFLOW="$2"; shift 2 ;;
    --branch)    BRANCH="$2"; shift 2 ;;
    --out)       OUT_DIR="$2"; shift 2 ;;
    --refresh)   REFRESH=1; shift ;;
    --json)      shift ;;   # accepted for convention; output is always JSON
    -h|--help)
      sed -n '3,20p' "$0" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo '{"error":"gh CLI not found"}'; exit 1; }
command -v jq >/dev/null || { echo '{"error":"jq not found"}'; exit 1; }

if [[ -z "${REPO}" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

SLUG="${REPO//\//-}"
: "${OUT_DIR:="${HOME}/.cache/ci-metrics/${SLUG}"}"
mkdir -p "${OUT_DIR}"

RUNS_FILE="${OUT_DIR}/runs.jsonl"
JOBS_FILE="${OUT_DIR}/jobs.jsonl"
[[ "${REFRESH}" -eq 1 ]] && rm -f "${RUNS_FILE}" "${JOBS_FILE}"
touch "${RUNS_FILE}" "${JOBS_FILE}"

# Portable "N days ago" — BSD date has no -d, GNU date has no -v.
if date -u -v-1d >/dev/null 2>&1; then
  SINCE=$(date -u -v-"${DAYS}"d +%Y-%m-%d)
else
  SINCE=$(date -u -d "${DAYS} days ago" +%Y-%m-%d)
fi

# Runs already captured, so a re-run only pays for new ones.
SEEN=$(jq -r 'select(.id != null) | .id' "${RUNS_FILE}" 2>/dev/null | sort -u || true)

QUERY="created=>=${SINCE}"
[[ -n "${BRANCH}" ]] && QUERY="${QUERY}&branch=${BRANCH}"

if [[ -n "${WORKFLOW}" ]]; then
  RUNS_PATH="repos/${REPO}/actions/workflows/${WORKFLOW}/runs"
else
  RUNS_PATH="repos/${REPO}/actions/runs"
fi

# --paginate with a jq filter streams; cap pages via --slurp-free per_page math.
PER_PAGE=100
PAGES=$(( (MAX_RUNS + PER_PAGE - 1) / PER_PAGE ))

RUNS_TMP=$(mktemp)
trap 'rm -f "${RUNS_TMP}"' EXIT

page=1
while [[ ${page} -le ${PAGES} ]]; do
  gh api "${RUNS_PATH}?per_page=${PER_PAGE}&page=${page}&${QUERY}" \
    --jq '.workflow_runs[] | {
            id, name, path, event, status, conclusion, run_attempt,
            created_at, run_started_at, updated_at,
            head_branch, head_sha, actor: (.actor.login // null)
          }' >> "${RUNS_TMP}" 2>/dev/null || break
  count=$(wc -l < "${RUNS_TMP}" | tr -d ' ')
  [[ "${count}" -lt $(( page * PER_PAGE )) ]] && break
  page=$(( page + 1 ))
done

# Only keep completed runs — an in-flight run has no meaningful duration and
# would poison the percentiles.
NEW_RUNS=0
FETCHED=0
SKIPPED=0

while IFS= read -r run; do
  [[ -z "${run}" ]] && continue
  status=$(jq -r '.status' <<<"${run}")
  [[ "${status}" != "completed" ]] && continue
  id=$(jq -r '.id' <<<"${run}")

  if grep -qx "${id}" <<<"${SEEN}"; then
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi

  # Jobs for every attempt of the run; attempt number rides along so the
  # analyzer can separate first-try cost from retry cost.
  attempts=$(jq -r '.run_attempt // 1' <<<"${run}")
  a=1
  while [[ ${a} -le ${attempts} ]]; do
    gh api "repos/${REPO}/actions/runs/${id}/attempts/${a}/jobs?per_page=100" --paginate \
      --jq ".jobs[] | {
              run_id: ${id}, run_attempt: ${a},
              id, name, workflow_name, conclusion, status,
              created_at, started_at, completed_at,
              runner_name, labels,
              steps: [ .steps[]? | {name, number, conclusion, started_at, completed_at} ]
            }" >> "${JOBS_FILE}" 2>/dev/null || true
    a=$(( a + 1 ))
  done

  printf '%s\n' "${run}" >> "${RUNS_FILE}"
  NEW_RUNS=$(( NEW_RUNS + 1 ))
  FETCHED=$(( FETCHED + 1 ))
done < "${RUNS_TMP}"

TOTAL_RUNS=$(wc -l < "${RUNS_FILE}" | tr -d ' ')
TOTAL_JOBS=$(wc -l < "${JOBS_FILE}" | tr -d ' ')

jq -n \
  --arg repo "${REPO}" --arg since "${SINCE}" --arg out "${OUT_DIR}" \
  --argjson new "${NEW_RUNS}" --argjson skipped "${SKIPPED}" \
  --argjson runs "${TOTAL_RUNS}" --argjson jobs "${TOTAL_JOBS}" \
  '{status:"ok", repo:$repo, since:$since, out_dir:$out,
    captured:{new_runs:$new, already_had:$skipped},
    totals:{runs:$runs, jobs:$jobs},
    next_action:"~/.claude/scripts/ci-metrics-analyze.py --in \($out)"}'
