#!/usr/bin/env bash
#
# make-target-scan.sh — inventory every `make` target ever invoked across all
# projects, recovered from Claude Code conversation transcripts: how often each
# ran, how long it took, how many you cancelled, and whether the time cost has
# been rising over the last 3 months.
#
# Transcripts stamp a timestamp on both the Bash tool_use entry and its matching
# tool_result, so wall-clock duration is recoverable by joining on tool_use_id.
# Nothing had to be instrumented ahead of time — this is purely retrospective
# over ~/.claude/projects/*/*.jsonl.
#
# OUTCOME CLASSIFICATION (from the tool_result text):
#   completed  — ran to completion (may still be a lint/test FAILURE; see failures)
#   rejected   — you declined it at the permission prompt; it never ran, and the
#                duration is only how long the prompt sat unanswered
#   interrupted— it was running and you killed it (Esc); duration is real runtime
#   error      — tool-level error that is neither of the above
# "Cancelled" = rejected + interrupted. Keep them separate when reading: only
# interrupted durations reflect a target that was actually too slow to wait for.
#
# CAVEAT: duration is request -> result, so it also includes permission-prompt
# wait and container start-up. Trust min/median over max.
#
# RETENTION — read this before trusting a trend: Claude Code deletes transcripts
# older than settings.json `cleanupPeriodDays` (default 30), so a raw scan can
# only ever see the last month no matter how long you have been working. Run with
# --archive (e.g. from cron) to merge each scan into a cumulative store at
# ~/.claude/data/make-runs.jsonl; reports read the union of store + live scan, so
# history accrues from the first archive run onward. Raising cleanupPeriodDays
# widens the window for future pruning but cannot bring back what is already gone.
#
# Usage:
#   make-target-scan.sh                    # per-target summary (JSON)
#   make-target-scan.sh --table            # same, human-readable
#   make-target-scan.sh --trend            # monthly totals + 3-month comparison
#   make-target-scan.sh --trend --bucket week --table
#   make-target-scan.sh --archive          # merge this scan into the store
#   make-target-scan.sh --raw              # every individual invocation
#   make-target-scan.sh --project praxis   # filter by project dir substring
#   make-target-scan.sh --since 2026-01-01 # only runs on/after this date
#   make-target-scan.sh --top 25           # limit summary rows (default 40)
#
set -euo pipefail

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
PROJECT_FILTER=''
SINCE=''
MODE='summary'
TABLE=0
TOP=40
BUCKET='month'
ARCHIVE=0

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_FILTER="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --top) TOP="$2"; shift 2 ;;
    --trend) MODE='trend'; shift ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --archive) ARCHIVE=1; shift ;;
    --by-project) MODE='projects'; shift ;;
    --raw) MODE='raw'; shift ;;
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

# A make invocation, anchored to a position where a COMMAND can legally start:
# beginning of a line, or after ; | && || ( — not merely after a space. The word
# "make" frequently appears inside quoted arguments of otherwise-real Bash calls
# (`git commit -m "make sense of X"`, `--progress-note "...run make lint..."`),
# and a space-anchored match happily reads the following English word as the
# target. Anchoring here is what keeps prose out of the inventory.
MAKE_RE='(^|[|;&(]|&&|\|\|)[[:space:]]*make[[:space:]]+(-[A-Za-z][^[:space:]]*[[:space:]]+|-C[[:space:]]+[^[:space:]]+[[:space:]]+)*[A-Za-z][A-Za-z0-9_.-]*'

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_RUN}"' EXIT
RUNS="${TMPDIR_RUN}/runs.jsonl"
: >"${RUNS}"

JQ_EXTRACT='
# Transcript timestamps carry milliseconds ("...:19.595Z"), which
# fromdateiso8601 rejects outright — parse seconds and fraction apart.
def epoch:
  . as $t
  | ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $s
  | (try ($t | capture("\\.(?<f>[0-9]{1,3})").f) catch "0") as $ms
  | $s + (($ms | tonumber) / 1000);
def content: (.message.content? // empty) | if type == "array" then .[] else empty end;
# tool_result content is sometimes a bare string, sometimes an array of blocks.
def result_text:
  (.content // "")
  | if type == "array" then (map(.text? // "") | join("\n")) else tostring end;
# The make target: first non-flag word after `make`, ignoring -C <dir> / -j etc.
def target:
  . as $cmd
  | (try ($cmd | capture("(?:^|[|;&(]|&&|\\|\\|)[[:space:]]*make[[:space:]]+(?<rest>[^\n]*)"; "m").rest) catch "")
  | [ splits("[[:space:]]+") ]
  | map(select(. != ""))
  | reduce .[] as $w ({ skip: false, hit: null };
      if .hit != null then .
      elif .skip then { skip: false, hit: null }
      elif $w == "-C" or $w == "-f" or $w == "-j" then { skip: true, hit: null }
      elif ($w | startswith("-")) then { skip: false, hit: null }
      elif ($w | test("=")) then { skip: false, hit: null }   # VAR=value, not a target
      else { skip: false, hit: $w }
      end)
  | .hit // "make (default)"
  # The word "make" also appears in prose inside echo/grep/commit-message
  # strings. Those matches yield an English word or punctuation-laden token, not
  # a target — reject them so they do not pollute the inventory.
  | . as $tok
  | ($tok | ascii_downcase) as $lc
  | if (($tok | test("^[A-Za-z][A-Za-z0-9_.:-]*$")) | not) then ""
    elif (["the","a","an","as","it","this","that","these","those","them","your","you",
           "we","i","is","was","are","were","be","been","will","would","should","can",
           "could","must","not","no","yes","if","for","in","on","of","with","but","then",
           "also","just","do","does","did","done","use","uses","using","used","when",
           "which","what","how","why","all","any","only","sure","and","or","so","to",
           "sense","changes","edits","progress","targets","target"] | index($lc)) != null
      then "" else $tok end;
def outcome($txt; $err):
  if ($txt | test("doesn.t want to (proceed|take this action)|tool use was rejected"; "i"))
    then "rejected"
  elif ($txt | test("Request interrupted by user"; "i"))
    then "interrupted"
  elif $err then "error"
  else "completed" end;

def uses:
  [ .[]
    | . as $e
    | (.timestamp // empty) as $ts
    | ($e | content)
    | select(.type == "tool_use" and .name == "Bash")
    | select((.input.command // "") | test($pat; "m"))
    | { key: .id,
        value: { cmd: (.input.command // ""), start: $ts,
                 cwd: ($e.cwd // ""), branch: ($e.gitBranch // ""),
                 sidechain: ($e.isSidechain // false) } }
  ] | from_entries;
def results:
  [ .[]
    | . as $e
    | (.timestamp // empty) as $ts
    | ($e | content)
    | select(.type == "tool_result")
    | { id: .tool_use_id, end: $ts,
        txt: (. | result_text | .[0:400]),
        is_error: (.is_error // false) }
  ];
. as $all
| ($all | uses) as $u
| ($all | results)
| map(select($u[.id] != null))
| map(. as $r | $u[$r.id] as $x
      | (($r.end | epoch) - ($x.start | epoch)) as $dur
      # Key on tool_use_id ALONE, not session+id: resuming or forking a session
      # replays earlier messages into a new transcript file, so the same call
      # appears under several session ids and a composite key double-counts it.
      | { id: $r.id,
          project: $project,
          session: $session,
          target: ($x.cmd | target),
          command: ($x.cmd | split("\n")[0] | .[0:200]),
          cwd: $x.cwd,
          sidechain: $x.sidechain,
          started_at: $x.start,
          month: ($x.start | .[0:7]),
          week: ($x.start | epoch | strftime("%G-W%V")),
          outcome: outcome($r.txt; $r.is_error),
          duration_s: (($dur * 10 | round) / 10) })
| map(select(.duration_s >= 0 and .target != ""))
| .[]
'

shopt -s nullglob
scanned=0
# Subagent transcripts live at <project>/<session>/subagents/*.jsonl, and on this
# machine they outnumber top-level session files 5:1. A one-level glob silently
# drops every make command a subagent ran, so discovery must recurse.
while IFS= read -r transcript; do
  relpath="${transcript#"${PROJECTS_DIR}"/}"
  project="${relpath%%/*}"
  if [[ -n "${PROJECT_FILTER}" && "${project}" != *"${PROJECT_FILTER}"* ]]; then
    continue
  fi
  # Cheap pre-filter so jq only parses files that can possibly match.
  grep -qE "${MAKE_RE}" "${transcript}" || continue
  session="$(basename "${transcript}" .jsonl)"
  scanned=$((scanned + 1))
  jq -s -c \
    --arg pat "${MAKE_RE}" \
    --arg project "${project}" \
    --arg session "${session}" \
    "${JQ_EXTRACT}" "${transcript}" >>"${RUNS}" \
    || echo "warn: failed to parse ${transcript}" >&2
done < <(find "${PROJECTS_DIR}" -name '*.jsonl' -type f)
shopt -u nullglob

# Claude Code prunes transcripts after settings.json `cleanupPeriodDays` (default
# 30), so the raw scan can only ever see the last month — history older than that
# is gone for good. Merging each scan into a cumulative store means the record
# outlives the transcripts, and trend comparisons get answerable over time.
STORE="${MAKE_SCAN_STORE:-${HOME}/.claude/data/make-runs.jsonl}"
count_lines() { if [[ -f "$1" ]]; then grep -c '' "$1"; else echo 0; fi; }

if [[ "${ARCHIVE}" -eq 1 ]]; then
  mkdir -p "$(dirname "${STORE}")"
  before="$(count_lines "${STORE}")"
  touch "${STORE}"
  merged="${TMPDIR_RUN}/merged.jsonl"
  jq -s -c 'unique_by(.id) | sort_by(.started_at) | .[]' "${STORE}" "${RUNS}" >"${merged}"
  mv "${merged}" "${STORE}"
  echo "archived: ${STORE} went from ${before} to $(count_lines "${STORE}") unique runs" >&2
fi

# Reports read the union of the live scan and the store, so archived history
# keeps counting even once its transcripts have been pruned.
if [[ -s "${STORE}" ]]; then
  union="${TMPDIR_RUN}/union.jsonl"
  jq -s -c 'unique_by(.id) | .[]' "${STORE}" "${RUNS}" >"${union}"
  RUNS="${union}"
fi

JQ_REPORT='
def r1: . * 10 | round / 10;
def pct(v; p):
  (v | sort) as $s | ($s | length) as $n
  | if $n == 0 then null else $s[ ((($n - 1) * p) | floor) ] end;
def stats(rows):
  (rows | map(.duration_s)) as $d
  | { runs: (rows | length),
      completed: (rows | map(select(.outcome == "completed")) | length),
      rejected: (rows | map(select(.outcome == "rejected")) | length),
      interrupted: (rows | map(select(.outcome == "interrupted")) | length),
      errors: (rows | map(select(.outcome == "error")) | length),
      total_s: (($d | add // 0) | r1),
      median_s: pct($d; 0.5),
      p90_s: pct($d; 0.9),
      max_s: ($d | max) };
# Ran-to-completion only: the honest basis for "is it getting slower?", since
# rejected rows measure prompt wait and interrupted rows measure a partial run.
def ran(rows): rows | map(select(.outcome == "completed"));

map(select($since == "" or (.started_at >= $since))) as $all
| if $mode == "raw" then ($all | sort_by(.started_at))
  elif $mode == "trend" then
    ($all | map(. + { bucket: (if $bucket == "week" then .week else .month end) })
          | group_by(.bucket) | map(
        (ran(.)) as $c
        | { month: .[0].bucket,
            runs: length,
            completed: ($c | length),
            cancelled: (map(select(.outcome == "rejected" or .outcome == "interrupted")) | length),
            completed_total_s: (($c | map(.duration_s) | add // 0) | r1),
            completed_median_s: pct(($c | map(.duration_s)); 0.5),
            completed_mean_s: (if ($c | length) > 0
                               then (($c | map(.duration_s) | add) / ($c | length) | r1)
                               else null end) })
      | sort_by(.month)) as $months
    # Month mode compares calendar 3-month windows. Week mode has no calendar
    # anchor worth honouring, so it compares the last 4 buckets to the prior 4.
    | (if $bucket == "week"
       then ($months | .[-4:])
       else ($months | map(select(.month >= $recent_from))) end) as $recent
    | (if $bucket == "week"
       then ($months | .[-8:-4])
       else ($months | map(select(.month >= $prior_from and .month < $recent_from))) end) as $prior
    | def agg(ms): { months: (ms | map(.month)),
                     runs: (ms | map(.runs) | add // 0),
                     completed: (ms | map(.completed) | add // 0),
                     cancelled: (ms | map(.cancelled) | add // 0),
                     completed_total_s: ((ms | map(.completed_total_s) | add // 0) | r1),
                     mean_s: (if ((ms | map(.completed) | add // 0) > 0)
                              then ((ms | map(.completed_total_s) | add) / (ms | map(.completed) | add) | r1)
                              else null end) };
      (agg($recent)) as $R | (agg($prior)) as $P
    | { bucket: $bucket,
        # Transcripts are subject to retention, so state the real window rather
        # than letting a short history read as "no change".
        data_window: { first_run: ($all | map(.started_at) | min),
                       last_run: ($all | map(.started_at) | max),
                       buckets_available: ($months | length) },
        monthly: $months,
        recent_window: $R,
        prior_window: $P,
        change: { mean_duration_pct: (if ($P.mean_s != null and $P.mean_s > 0 and $R.mean_s != null)
                                      then ((($R.mean_s - $P.mean_s) / $P.mean_s) * 1000 | round / 10)
                                      else null end),
                  runs_pct: (if $P.runs > 0
                             then ((($R.runs - $P.runs) / $P.runs) * 1000 | round / 10)
                             else null end),
                  total_time_pct: (if $P.completed_total_s > 0
                                   then ((($R.completed_total_s - $P.completed_total_s) / $P.completed_total_s) * 1000 | round / 10)
                                   else null end),
                  verdict: (if ($P.mean_s == null or $R.mean_s == null or $P.mean_s == 0) then "insufficient prior data"
                            elif ($R.mean_s > $P.mean_s * 1.15) then "SLOWER — mean per-run duration up >15%"
                            elif ($R.mean_s < $P.mean_s * 0.85) then "FASTER — mean per-run duration down >15%"
                            else "flat — mean per-run duration within +/-15%" end) } }
  elif $mode == "projects" then
    # One row per (project, target) — the pairing is the point, since the same
    # target name behaves very differently across repos.
    def short: sub("^-Users-eric-turner-projects-"; "") | sub("^-Users-eric-turner"; "~");
    ($all | group_by([.project, .target]) | map(
        . as $rows | stats($rows)
        + { project: ($rows[0].project | short),
            target: $rows[0].target,
            mean_s: (($rows | map(select(.outcome == "completed") | .duration_s)) as $c
                     | if ($c | length) > 0 then (($c | add) / ($c | length) | r1) else null end),
            completed_median_s: pct(($rows | map(select(.outcome == "completed") | .duration_s)); 0.5),
            first_run: ($rows | map(.started_at) | min | .[0:10]),
            last_run: ($rows | map(.started_at) | max | .[0:10]) })
      | sort_by(-.total_s)) as $rows
    | { rollup: ($all | group_by(.project) | map(
          . as $p | { project: ($p[0].project | short),
                      runs: ($p | length),
                      distinct_targets: ($p | map(.target) | unique | length),
                      sessions: ($p | map(.session) | unique | length),
                      total_s: (($p | map(.duration_s) | add // 0) | r1),
                      median_s: pct(($p | map(.duration_s)); 0.5) })
        | sort_by(-.total_s)),
        rows: $rows }
  else
    ($all | group_by(.target) | map(
        . as $rows | stats($rows)
        + { target: $rows[0].target,
            projects: ($rows | map(.project) | unique | length),
            cancel_rate_pct: (((($rows | map(select(.outcome == "rejected" or .outcome == "interrupted")) | length)
                                / ($rows | length)) * 1000 | round) / 10),
            completed_median_s: pct(($rows | map(select(.outcome == "completed") | .duration_s)); 0.5),
            first_seen: ($rows | map(.started_at) | min | .[0:10]),
            last_seen: ($rows | map(.started_at) | max | .[0:10]) })
      | sort_by(-.total_s)) as $targets
    | { totals: (stats($all) + {
          distinct_targets: ($targets | length),
          cancelled: ($all | map(select(.outcome == "rejected" or .outcome == "interrupted")) | length),
          cancelled_time_s: (($all | map(select(.outcome == "rejected" or .outcome == "interrupted") | .duration_s) | add // 0) | r1),
          interrupted_time_s: (($all | map(select(.outcome == "interrupted") | .duration_s) | add // 0) | r1) }),
        targets: ($targets | .[0:$top]),
        truncated: (($targets | length) > $top) }
  end
'

# 3-month windows are computed from today so the comparison is calendar-aligned.
RECENT_FROM="$(date -u -v-2m +%Y-%m 2>/dev/null || date -u -d '-2 month' +%Y-%m)"
PRIOR_FROM="$(date -u -v-5m +%Y-%m 2>/dev/null || date -u -d '-5 month' +%Y-%m)"

payload="$(jq -s -c \
  --arg since "${SINCE}" \
  --arg mode "${MODE}" \
  --arg recent_from "${RECENT_FROM}" \
  --arg prior_from "${PRIOR_FROM}" \
  --arg bucket "${BUCKET}" \
  --argjson top "${TOP}" \
  "${JQ_REPORT}" "${RUNS}")"

if [[ "${TABLE}" -eq 1 ]]; then
  case "${MODE}" in
    summary)
      jq -r '.totals | "make invocations: \(.runs)   distinct targets: \(.distinct_targets)
completed: \(.completed)   rejected at prompt: \(.rejected)   interrupted mid-run: \(.interrupted)   errors: \(.errors)
cancelled total: \(.cancelled)  (time spent on cancelled: \(.cancelled_time_s)s, of which \(.interrupted_time_s)s was real runtime before you killed it)
wall clock, all invocations: \(.total_s)s   median \(.median_s)s   p90 \(.p90_s)s   max \(.max_s)s
"' <<<"${payload}"
      printf '%-26s %5s %5s %4s %4s %8s %7s %7s %7s %6s\n' \
        TARGET RUNS DONE REJ INT TOTAL_S MED_S P90_S MAX_S CANC%
      jq -r '.targets[] | [ .target, .runs, .completed, .rejected, .interrupted,
                            .total_s, (.completed_median_s // "-"), .p90_s, .max_s,
                            .cancel_rate_pct ] | @tsv' <<<"${payload}" \
        | awk -F'\t' '{printf "%-26s %5s %5s %4s %4s %8s %7s %7s %7s %6s\n",
                       $1,$2,$3,$4,$5,$6,$7,$8,$9,$10}'
      jq -r 'if .truncated then "\n(truncated — pass --top N for more)" else "" end' <<<"${payload}"
      ;;
    trend)
      printf '%-9s %5s %5s %6s %9s %7s %7s\n' \
        MONTH RUNS DONE CANCEL TOTAL_S MED_S MEAN_S
      jq -r '.monthly[] | [ .month, .runs, .completed, .cancelled,
                            .completed_total_s, (.completed_median_s // "-"),
                            (.completed_mean_s // "-") ] | @tsv' <<<"${payload}" \
        | awk -F'\t' '{printf "%-9s %5s %5s %6s %9s %7s %7s\n",$1,$2,$3,$4,$5,$6,$7}'
      jq -r '"\nrecent window (\(.recent_window.months | join(", "))): \(.recent_window.runs) runs, \(.recent_window.completed_total_s)s completed-time, mean \(.recent_window.mean_s // "-")s/run, \(.recent_window.cancelled) cancelled
prior window  (\(.prior_window.months | join(", "))): \(.prior_window.runs) runs, \(.prior_window.completed_total_s)s completed-time, mean \(.prior_window.mean_s // "-")s/run, \(.prior_window.cancelled) cancelled
change: mean/run \(.change.mean_duration_pct // "-")%   runs \(.change.runs_pct // "-")%   total time \(.change.total_time_pct // "-")%
verdict: \(.change.verdict)"' <<<"${payload}"
      ;;
    projects)
      printf '%-20s %5s %8s %9s %7s\n' PROJECT RUNS TARGETS TOTAL_S MED_S
      jq -r '.rollup[] | [ .project, .runs, .distinct_targets, .total_s,
                           (.median_s // "-") ] | @tsv' <<<"${payload}" \
        | awk -F'\t' '{printf "%-20s %5s %8s %9s %7s\n",$1,$2,$3,$4,$5}'
      printf '\n%-20s %-24s %5s %5s %4s %9s %7s %7s %7s %7s\n' \
        PROJECT TARGET RUNS DONE FAIL TOTAL_S MED_S MEAN_S P90_S MAX_S
      jq -r '.rows[] | [ .project, .target, .runs, .completed, .errors, .total_s,
                         (.completed_median_s // "-"), (.mean_s // "-"),
                         (.p90_s // "-"), (.max_s // "-") ] | @tsv' <<<"${payload}" \
        | awk -F'\t' '{printf "%-20s %-24s %5s %5s %4s %9s %7s %7s %7s %7s\n",
                       $1,$2,$3,$4,$5,$6,$7,$8,$9,$10}'
      ;;
    raw)
      printf '%-20s %-24s %-12s %8s %s\n' STARTED TARGET OUTCOME SECS PROJECT
      jq -r '.[] | [ (.started_at | .[0:19]), .target, .outcome,
                     (.duration_s | tostring), .project ] | @tsv' <<<"${payload}" \
        | awk -F'\t' '{printf "%-20s %-24s %-12s %8s %s\n",$1,$2,$3,$4,$5}'
      ;;
  esac
  exit 0
fi

jq -n \
  --argjson data "${payload}" \
  --arg mode "${MODE}" \
  --arg since "${SINCE}" \
  --argjson sessions "${scanned}" \
  '{ mode: $mode,
     since: (if $since == "" then null else $since end),
     transcripts_scanned: $sessions,
     measurement_note: "duration_s is tool_use -> tool_result wall clock; it includes permission-prompt wait and container start-up. rejected rows never ran (duration = prompt wait); interrupted rows are real partial runtime. Trust median over max.",
     results: $data }'
