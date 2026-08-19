#!/usr/bin/env bash
#
# lint-timing-scan.sh — recover how long `make lint` / `make typecheck` (and
# friends) actually took, per project, from Claude Code conversation transcripts.
#
# Transcripts record a timestamp on both the Bash tool_use entry and its
# tool_result entry, so wall-clock duration is recoverable by joining on
# tool_use_id. Nothing needs to be instrumented ahead of time — this is purely
# retrospective over ~/.claude/projects/*/*.jsonl.
#
# CAVEAT (important when reading the numbers): the measured span is
# request -> result, so it INCLUDES any time the call sat waiting on a
# permission prompt, and includes container start-up when the target brings a
# stack up. Use the median/min as the signal for real tool cost; a max far above
# the median usually means a prompt wait or a cold Docker build, not a slow
# linter. `--raw` lets you inspect individual runs to confirm.
#
# Usage:
#   lint-timing-scan.sh                      # all projects, JSON summary
#   lint-timing-scan.sh --project praxis     # filter by project dir substring
#   lint-timing-scan.sh --pattern 'make test' # scan a different command family
#   lint-timing-scan.sh --since 2026-06-01   # only runs on/after this date
#   lint-timing-scan.sh --raw                # every individual run, not stats
#   lint-timing-scan.sh --table              # human-readable table
#
set -euo pipefail

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
PATTERN='make [a-z-]*(lint|typecheck)[a-z-]*'
PROJECT_FILTER=''
SINCE=''
RAW=0
TABLE=0

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_FILTER="$2"; shift 2 ;;
    --pattern) PATTERN="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --raw) RAW=1; shift ;;
    --table) TABLE=1; shift ;;
    --json) shift ;;  # accepted for consistency; JSON is the default
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "${PROJECTS_DIR}" ]]; then
  echo "{\"error\":\"projects dir not found: ${PROJECTS_DIR}\"}" >&2
  exit 1
fi

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_RUN}"' EXIT
RUNS="${TMPDIR_RUN}/runs.jsonl"
: >"${RUNS}"

# Per-file extraction: build id -> {cmd, ts} from tool_use entries, then join
# each tool_result back to it and emit one record per completed run.
JQ_EXTRACT='
# Transcript timestamps carry milliseconds ("...:19.595Z"), which
# fromdateiso8601 rejects outright — parse the seconds and the fraction apart.
def epoch:
  . as $t
  | ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $s
  | (try ($t | capture("\\.(?<f>[0-9]{1,3})").f) catch "0") as $ms
  | $s + (($ms | tonumber) / 1000);
def content: (.message.content? // empty) | if type == "array" then .[] else empty end;
def uses:
  [ .[]
    | . as $e
    | (.timestamp // empty) as $ts
    | ($e.cwd // "") as $cwd
    | ($e.gitBranch // "") as $branch
    | ($e.isSidechain // false) as $side
    | ($e | content)
    | select(.type == "tool_use" and .name == "Bash")
    | select((.input.command // "") | test($pat))
    | { key: .id,
        value: { cmd: (.input.command // ""), start: $ts, cwd: $cwd,
                 branch: $branch, sidechain: $side } }
  ] | from_entries;
def results:
  [ .[]
    | . as $e
    | (.timestamp // empty) as $ts
    | ($e | content)
    | select(.type == "tool_result")
    | { id: .tool_use_id, end: $ts, is_error: (.is_error // false) }
  ];
. as $all
| ($all | uses) as $u
| ($all | results)
| map(select($u[.id] != null))
| map(. as $r | $u[$r.id] as $x
      | { project: $project,
          session: $session,
          command: ($x.cmd | split("\n")[0] | .[0:160]),
          target: (($x.cmd | match($pat).string) // ($x.cmd | split("\n")[0])),
          cwd: $x.cwd,
          branch: $x.branch,
          sidechain: $x.sidechain,
          started_at: $x.start,
          is_error: $r.is_error,
          duration_s: (((($r.end | epoch) - ($x.start | epoch)) * 10 | round) / 10) })
| map(select(.duration_s >= 0))
| .[]
'

shopt -s nullglob
for project_dir in "${PROJECTS_DIR}"/*; do
  [[ -d "${project_dir}" ]] || continue
  project="$(basename "${project_dir}")"
  if [[ -n "${PROJECT_FILTER}" && "${project}" != *"${PROJECT_FILTER}"* ]]; then
    continue
  fi
  for transcript in "${project_dir}"/*.jsonl; do
    # Cheap pre-filter so we only pay jq's parse cost on files that can match.
    grep -qE "${PATTERN}" "${transcript}" || continue
    session="$(basename "${transcript}" .jsonl)"
    jq -s -c \
      --arg pat "${PATTERN}" \
      --arg project "${project}" \
      --arg session "${session}" \
      "${JQ_EXTRACT}" "${transcript}" >>"${RUNS}" || {
        echo "warn: failed to parse ${transcript}" >&2
      }
  done
done
shopt -u nullglob

# Apply --since, then either dump raw runs or aggregate per project+target.
JQ_AGG='
def pct(v; p):
  (v | sort) as $s
  | ($s | length) as $n
  | if $n == 0 then null
    else $s[ (((($n - 1) * p) | floor)) ]
    end;
map(select($since == "" or (.started_at >= $since)))
| if $raw == 1 then sort_by(.started_at)
  else
    group_by([.project, .target])
    | map(
        (map(.duration_s)) as $d
        | { project: .[0].project,
            target: .[0].target,
            runs: length,
            failures: (map(select(.is_error)) | length),
            total_s: (($d | add) * 10 | round / 10),
            min_s: ($d | min),
            median_s: pct($d; 0.5),
            p90_s: pct($d; 0.9),
            max_s: ($d | max),
            first_seen: (map(.started_at) | min),
            last_seen: (map(.started_at) | max),
            example_command: .[0].command }
      )
    | sort_by(-.total_s)
  end
'

payload="$(jq -s -c --arg since "${SINCE}" --argjson raw "${RAW}" "${JQ_AGG}" "${RUNS}")"

if [[ "${TABLE}" -eq 1 ]]; then
  if [[ "${RAW}" -eq 1 ]]; then
    printf '%-28s %-34s %8s %s\n' PROJECT COMMAND SECS STARTED
    jq -r '.[] | [.project, (.command[0:34]), (.duration_s|tostring), .started_at]
           | @tsv' <<<"${payload}" \
      | awk -F'\t' '{printf "%-28s %-34s %8s %s\n", $1, $2, $3, $4}'
  else
    printf '%-28s %-24s %5s %7s %8s %8s %8s\n' \
      PROJECT TARGET RUNS TOTAL_S MEDIAN_S P90_S MAX_S
    jq -r '.[] | [.project, .target, (.runs|tostring), (.total_s|tostring),
                  (.median_s|tostring), (.p90_s|tostring), (.max_s|tostring)]
           | @tsv' <<<"${payload}" \
      | awk -F'\t' '{printf "%-28s %-24s %5s %7s %8s %8s %8s\n", $1, $2, $3, $4, $5, $6, $7}'
  fi
  exit 0
fi

jq -n \
  --argjson data "${payload}" \
  --arg pattern "${PATTERN}" \
  --arg since "${SINCE}" \
  --argjson raw "${RAW}" \
  '{ scanned_pattern: $pattern,
     since: (if $since == "" then null else $since end),
     mode: (if $raw == 1 then "raw" else "summary" end),
     measurement_note: "duration_s is tool_use -> tool_result wall clock; it includes permission-prompt wait and container start-up. Trust min/median over max.",
     total_records: ($data | length),
     results: $data }'
