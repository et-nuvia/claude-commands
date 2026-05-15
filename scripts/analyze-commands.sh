#!/usr/bin/env bash
# analyze-commands.sh — Parse command tracking data and produce usage reports
#
# Usage:
#   analyze-commands.sh [--project <name>] [--days <n>] [--date <YYYY-MM-DD>]
#                       [--from <YYYY-MM-DD>] [--to <YYYY-MM-DD>]
#                       [--command <name>] [--group <name>]
#                       [--format text|json]

set -euo pipefail

readonly TRACKING_DIR="${HOME}/.claude/tracking"

# ─── Defaults ─────────────────────────────────────────────────────────────────

OPT_PROJECT=""
OPT_DAYS="7"
OPT_DATE=""
OPT_FROM=""
OPT_TO=""
OPT_COMMAND=""
OPT_GROUP=""
OPT_FORMAT="text"

# ─── Argument Parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)  OPT_PROJECT="$2";  shift 2 ;;
    --days)     OPT_DAYS="$2";     shift 2 ;;
    --date)     OPT_DATE="$2";     shift 2 ;;
    --from)     OPT_FROM="$2";     shift 2 ;;
    --to)       OPT_TO="$2";       shift 2 ;;
    --command)  OPT_COMMAND="$2";  shift 2 ;;
    --group)    OPT_GROUP="$2";    shift 2 ;;
    --format)   OPT_FORMAT="$2";   shift 2 ;;
    --help|-h)
      sed -n '/^# Usage/,/^$/p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "${TRACKING_DIR}" ]]; then
  echo "No tracking data found at ${TRACKING_DIR}" >&2
  exit 0
fi

# ─── Main Analysis (Python) ───────────────────────────────────────────────────

ANALYZE_TRACKING_DIR="${TRACKING_DIR}" \
OPT_PROJECT="${OPT_PROJECT}" OPT_DAYS="${OPT_DAYS}" OPT_DATE="${OPT_DATE}" \
OPT_FROM="${OPT_FROM}" OPT_TO="${OPT_TO}" OPT_COMMAND="${OPT_COMMAND}" \
OPT_GROUP="${OPT_GROUP}" OPT_FORMAT="${OPT_FORMAT}" \
python3 - <<'PYEOF'
import json
import os
import sys
from collections import defaultdict
from datetime import date, timedelta, datetime

# ── Config from env ────────────────────────────────────────────────────────────

e = os.environ
opt_project  = e.get("OPT_PROJECT", "")
opt_days     = int(e.get("OPT_DAYS", "7"))
opt_date     = e.get("OPT_DATE", "")
opt_from     = e.get("OPT_FROM", "")
opt_to       = e.get("OPT_TO", "")
opt_command  = e.get("OPT_COMMAND", "")
opt_group    = e.get("OPT_GROUP", "")
opt_format   = e.get("OPT_FORMAT", "text")
tracking_dir = e.get("ANALYZE_TRACKING_DIR", os.path.expanduser("~/.claude/tracking"))

# ── Command Groups ─────────────────────────────────────────────────────────────

GROUPS = {
    "task":     lambda c: c.startswith("task-") or c == "execute-tasks",
    "deploy":   lambda c: c.startswith("deploy-") or c.startswith("deploy-to-"),
    "test":     lambda c: c.startswith("test-") or c == "test",
    "git":      lambda c: c.startswith("git-") or c in ("create-pr", "review-pr", "review-mr", "undo"),
    "plan":     lambda c: c.startswith("plan-"),
    "security": lambda c: c.startswith("security-") or c == "docker-hardening",
    "db":       lambda c: c.startswith("db-"),
    "infra":    lambda c: c.startswith("infra-"),
    "ops":      lambda c: c.startswith("ops-"),
    "rca":      lambda c: c.startswith("rca-"),
    "refactor": lambda c: c in ("refactor", "find-dead-code", "find-todos", "format", "remove-comments")
                          or c.startswith("fix-"),
    "feature":  lambda c: c.startswith("feature-"),
    "pipeline": lambda c: c.startswith("pipeline-"),
}

# ── Date Range ─────────────────────────────────────────────────────────────────

today = date.today()

if opt_date:
    date_from = date_to = date.fromisoformat(opt_date)
elif opt_from and opt_to:
    date_from = date.fromisoformat(opt_from)
    date_to   = date.fromisoformat(opt_to)
elif opt_from:
    date_from = date.fromisoformat(opt_from)
    date_to   = today
else:
    date_from = today - timedelta(days=opt_days - 1)
    date_to   = today

# ── Load Events ───────────────────────────────────────────────────────────────

all_events = []
d = date_from
while d <= date_to:
    path = os.path.join(tracking_dir, f"{d}.json")
    if os.path.exists(path):
        try:
            with open(path) as f:
                events = json.load(f)
            all_events.extend(events)
        except (json.JSONDecodeError, IOError):
            pass
    d += timedelta(days=1)

# ── Filter Events ─────────────────────────────────────────────────────────────

def matches_group(cmd, group):
    fn = GROUPS.get(group)
    return fn(cmd) if fn else False

def should_include(ev):
    if opt_project and ev.get("project", "") != opt_project:
        return False
    cmd = ev.get("command", "")
    if opt_command and cmd != opt_command:
        return False
    if opt_group and not matches_group(cmd, opt_group):
        return False
    return True

filtered = [ev for ev in all_events if should_include(ev)]

# Separate start events from terminal events (completed/errored)
terminal_events = [ev for ev in filtered if ev.get("status") in ("completed", "errored")]
start_events    = [ev for ev in filtered if ev.get("status") == "started"]

# Deduplicate: one entry per session (prefer terminal event)
sessions_seen = set()
deduped = []
for ev in terminal_events:
    sid = ev.get("session_id", "")
    if sid not in sessions_seen:
        sessions_seen.add(sid)
        deduped.append(ev)
# Include starts without a matching terminal event
for ev in start_events:
    sid = ev.get("session_id", "")
    if sid not in sessions_seen:
        sessions_seen.add(sid)
        deduped.append(ev)

# ── JSON Output ───────────────────────────────────────────────────────────────

if opt_format == "json":
    out = {
        "date_from":   str(date_from),
        "date_to":     str(date_to),
        "total_events": len(deduped),
        "events":       deduped,
    }
    print(json.dumps(out, indent=2))
    sys.exit(0)

# ── Text Report ───────────────────────────────────────────────────────────────

def section(title):
    print(f"\n{'─' * 60}")
    print(f"  {title}")
    print(f"{'─' * 60}")

def bold(s):
    return f"\033[1m{s}\033[0m"

total = len(deduped)
unique_cmds = {ev.get("command", "") for ev in deduped}
projects    = {ev.get("project", "") for ev in deduped if ev.get("project")}

# ── 1. Summary ─────────────────────────────────────────────────────────────────

section("SUMMARY")
print(f"  Date range:       {date_from}  →  {date_to}")
print(f"  Commands run:     {total}")
print(f"  Unique commands:  {len(unique_cmds)}")
print(f"  Projects:         {', '.join(sorted(projects)) if projects else 'none'}")
if opt_group:
    print(f"  Group filter:     {opt_group}")
if opt_command:
    print(f"  Command filter:   {opt_command}")

if total == 0:
    print("\n  No data found for the specified filters.")
    sys.exit(0)

# ── 2. Usage Frequency ────────────────────────────────────────────────────────

section("USAGE FREQUENCY  (top 10)")
counts = defaultdict(int)
for ev in deduped:
    counts[ev.get("command", "unknown")] += 1
top10 = sorted(counts.items(), key=lambda x: -x[1])[:10]
max_count = top10[0][1] if top10 else 1
for cmd, cnt in top10:
    bar = "█" * int(cnt / max_count * 20)
    print(f"  {cmd:<30} {cnt:>4}  {bar}")

# ── 3. Success / Error Rates ──────────────────────────────────────────────────

section("SUCCESS / ERROR RATES")
status_by_cmd = defaultdict(lambda: {"completed": 0, "errored": 0, "started": 0})
for ev in deduped:
    cmd    = ev.get("command", "unknown")
    status = ev.get("status", "unknown")
    if status in status_by_cmd[cmd]:
        status_by_cmd[cmd][status] += 1

# Sort by error rate descending
def error_rate(d):
    total_done = d["completed"] + d["errored"]
    return d["errored"] / total_done if total_done else 0

rows = sorted(status_by_cmd.items(), key=lambda x: -error_rate(x[1]))
print(f"  {'Command':<30} {'OK':>4}  {'ERR':>4}  {'ERR%':>6}")
print(f"  {'-'*30}  {'-'*4}  {'-'*4}  {'-'*6}")
for cmd, d in rows:
    rate = error_rate(d)
    pct  = f"{rate * 100:.0f}%"
    flag = "  ⚠" if rate >= 0.2 else ""
    print(f"  {cmd:<30} {d['completed']:>4}  {d['errored']:>4}  {pct:>6}{flag}")

# ── 4. Model Usage ─────────────────────────────────────────────────────────────

section("MODEL USAGE")
model_counts = defaultdict(int)
model_by_cmd = defaultdict(lambda: defaultdict(int))
for ev in deduped:
    m   = ev.get("model") or ev.get("selected_model") or "unknown"
    cmd = ev.get("command", "unknown")
    model_counts[m] += 1
    model_by_cmd[cmd][m] += 1

for model, cnt in sorted(model_counts.items(), key=lambda x: -x[1]):
    print(f"  {model:<30} {cnt:>4} uses")

# Mismatch detection: complexity=1 on opus
print()
for cmd, models in model_by_cmd.items():
    # Find events for this command with complexity
    cmd_events = [ev for ev in deduped if ev.get("command") == cmd and ev.get("complexity")]
    if not cmd_events:
        continue
    avg_complexity = sum(ev["complexity"] for ev in cmd_events) / len(cmd_events)
    if avg_complexity <= 1.5 and "claude-opus" in " ".join(models.keys()):
        print(f"  ⚠  {cmd}: avg complexity={avg_complexity:.1f} but ran on opus — consider haiku/sonnet")

# ── 5. Token & Cost Analysis ──────────────────────────────────────────────────

section("TOKEN & COST ANALYSIS")
cost_by_cmd   = defaultdict(list)
tokens_by_cmd = defaultdict(list)
for ev in deduped:
    cmd = ev.get("command", "unknown")
    if ev.get("cost_estimated") is not None:
        cost_by_cmd[cmd].append(ev["cost_estimated"])
    if ev.get("tokens_estimated") is not None:
        tokens_by_cmd[cmd].append(ev["tokens_estimated"])

total_cost   = sum(c for costs in cost_by_cmd.values() for c in costs)
total_tokens = sum(t for tok in tokens_by_cmd.values() for t in tok)
print(f"  Total cost (tracked):   ${total_cost:.4f}")
print(f"  Total tokens (tracked): {total_tokens:,}")

if cost_by_cmd:
    print()
    print(f"  {'Command':<30} {'Runs':>4}  {'Avg Tokens':>11}  {'Avg Cost':>9}  {'Total Cost':>10}")
    print(f"  {'-'*30}  {'-'*4}  {'-'*11}  {'-'*9}  {'-'*10}")
    sorted_by_cost = sorted(cost_by_cmd.items(), key=lambda x: -sum(x[1]))
    for cmd, costs in sorted_by_cost:
        toks = tokens_by_cmd.get(cmd, [])
        avg_tok  = int(sum(toks) / len(toks))  if toks  else 0
        avg_cost = sum(costs) / len(costs)
        tot_cost = sum(costs)
        print(f"  {cmd:<30} {len(costs):>4}  {avg_tok:>11,}  ${avg_cost:>8.4f}  ${tot_cost:>9.4f}")

# ── 6. Complexity Distribution ────────────────────────────────────────────────

section("COMPLEXITY DISTRIBUTION")
comp_events = [ev for ev in deduped if ev.get("complexity")]
if comp_events:
    overall = defaultdict(int)
    for ev in comp_events:
        overall[ev["complexity"]] += 1
    labels = {1: "read-only", 2: "simple git", 3: "multi-file", 4: "cross-system", 5: "prod/infra"}
    print(f"  {'Level':<8}  {'Label':<15}  {'Count':>5}  {'Bar'}")
    for lvl in range(1, 6):
        cnt = overall.get(lvl, 0)
        bar = "█" * cnt
        print(f"  {lvl:<8}  {labels[lvl]:<15}  {cnt:>5}  {bar}")
else:
    print("  No complexity data recorded yet.")

# ── 7. Duration Analysis ──────────────────────────────────────────────────────

section("DURATION ANALYSIS")
dur_by_cmd = defaultdict(list)
for ev in deduped:
    if ev.get("duration_seconds"):
        dur_by_cmd[ev.get("command", "unknown")].append(ev["duration_seconds"])

if dur_by_cmd:
    sorted_dur = sorted(dur_by_cmd.items(), key=lambda x: -(sum(x[1]) / len(x[1])))
    print(f"  {'Command':<30} {'Runs':>4}  {'Avg (s)':>7}  {'Max (s)':>7}")
    print(f"  {'-'*30}  {'-'*4}  {'-'*7}  {'-'*7}")
    for cmd, durs in sorted_dur[:10]:
        avg_d = int(sum(durs) / len(durs))
        max_d = max(durs)
        print(f"  {cmd:<30} {len(durs):>4}  {avg_d:>7}  {max_d:>7}")
else:
    print("  No duration data recorded yet.")

# ── 8. Optimization Recommendations ──────────────────────────────────────────

section("OPTIMIZATION RECOMMENDATIONS")
recs = []

# Most-called command
if top10:
    top_cmd, top_cnt = top10[0]
    if top_cnt >= 5:
        recs.append(f"'{top_cmd}' is your most-called command ({top_cnt}x) — ensure it's well-optimized.")

# High error rate
for cmd, d in status_by_cmd.items():
    rate = error_rate(d)
    total_runs = d["completed"] + d["errored"]
    if rate >= 0.25 and total_runs >= 3:
        recs.append(f"'{cmd}' has {rate*100:.0f}% error rate ({d['errored']}/{total_runs} runs) — review error messages.")

# Costliest command
if cost_by_cmd:
    costliest = max(cost_by_cmd.items(), key=lambda x: sum(x[1]))
    total_c = sum(costliest[1])
    if total_c > 1.0:
        recs.append(f"'{costliest[0]}' is your costliest command (${total_c:.2f} total) — review token usage.")

# Model mismatch (low complexity on expensive model)
for cmd, models in model_by_cmd.items():
    cmd_events = [ev for ev in deduped if ev.get("command") == cmd and ev.get("complexity")]
    if not cmd_events:
        continue
    avg_c = sum(ev["complexity"] for ev in cmd_events) / len(cmd_events)
    used_models = list(models.keys())
    if avg_c <= 1.5 and any("opus" in m for m in used_models):
        recs.append(f"'{cmd}' averages complexity {avg_c:.1f} but uses opus — consider haiku for cost savings.")

if recs:
    for i, rec in enumerate(recs, 1):
        print(f"  {i}. {rec}")
else:
    print("  No recommendations — usage looks well-optimized.")

print()
PYEOF
