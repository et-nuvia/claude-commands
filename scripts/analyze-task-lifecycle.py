#!/usr/bin/env python3
"""analyze-task-lifecycle.py - Mine Claude Code transcripts for the task lifecycle.

Reconstructs, across every project, how tasks actually move through the
capture -> start -> design -> plan -> work -> review -> close -> merge chain:
which commands get used, in what order, where work stalls or is abandoned, and
where you pause for interactive verification (AskUserQuestion / plan approval).

The output is the data substrate for designing a hook-driven auto-advance
orchestrator: it tells you which transitions are deterministic enough to
auto-advance and which are real human gates.

Transcripts live at ~/.claude/projects/<slug>/*.jsonl (one JSON object per line).

Usage:
  analyze-task-lifecycle.py [--json] [--limit N] [--since YYYY-MM-DD]
                            [--project SUBSTR] [--output FILE]

Output: structured JSON to stdout + /tmp/task-lifecycle-analysis.json,
status/progress to stderr. next_action drives the LLM recommendation phase.
"""

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from glob import glob
from statistics import median

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
DEFAULT_OUTPUT = "/tmp/task-lifecycle-analysis.json"

# Lifecycle commands we care about (the task chain + the merge/deploy tail).
LIFECYCLE = {
    "task-capture", "task-fetch", "task-start", "task-design", "task-plan",
    "task-continue", "task-audit", "task-arch-review", "task-code-review",
    "task-feature-review", "task-risk", "task-summary", "task-hold",
    "task-resume", "task-close", "deploy-to-stage", "git-merge",
    "create-pr", "review-pr", "deploy-to-prod", "deploy-risk",
}

# Canonical happy-path order used for the funnel and out-of-order detection.
CANON = [
    "task-capture", "task-start", "task-design", "task-plan", "task-continue",
    "task-audit", "task-arch-review", "task-code-review", "task-close",
    "deploy-to-stage", "git-merge",
]
CANON_INDEX = {c: i for i, c in enumerate(CANON)}

# Interactive-checkpoint signals (where you verify the work is being built right).
INTERACTIVE_TOOLS = {"AskUserQuestion", "ExitPlanMode"}

CMD_RE = re.compile(r"<command-name>/([a-zA-Z0-9-]+)")
CMDARGS_RE = re.compile(r"<command-args>\s*([0-9A-Fa-f]{6})")
TASKID_BRANCH_RE = re.compile(r"(?:^|/)([0-9A-Fa-f]{6})-")
TASKID_WORKTREE_RE = re.compile(r"\.worktrees/([0-9A-Fa-f]{6})")


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def task_id_from(branch, cwd):
    for src, rx in ((branch, TASKID_BRANCH_RE), (cwd, TASKID_WORKTREE_RE)):
        if src:
            m = rx.search(src)
            if m:
                return m.group(1).upper()
    return None


def extract_events(path):
    """Yield event dicts from one transcript: lifecycle commands + interaction signals."""
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            rtype = rec.get("type")
            ts = parse_ts(rec.get("timestamp"))
            branch = rec.get("gitBranch") or ""
            cwd = rec.get("cwd") or ""
            msg = rec.get("message") or {}
            content = msg.get("content")
            content_str = content if isinstance(content, str) else json.dumps(content) if content else ""

            # Lifecycle command invocation (user turn carrying <command-name>).
            cmd_match = CMD_RE.search(content_str)
            if cmd_match:
                cmd = cmd_match.group(1)
                if cmd in LIFECYCLE:
                    # Prefer the explicit task id passed as a command arg (e.g.
                    # /task-start 86CBB3) — task-start runs before the feature
                    # branch exists, so branch/cwd can't identify it yet.
                    args_match = CMDARGS_RE.search(content_str)
                    tid = args_match.group(1).upper() if args_match else task_id_from(branch, cwd)
                    yield {"kind": "cmd", "cmd": cmd, "ts": ts, "branch": branch,
                           "cwd": cwd, "task": tid}

            # Interaction signals + errors (assistant/tool turns, content is a list).
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    bt = block.get("type")
                    if bt == "tool_use" and block.get("name") in INTERACTIVE_TOOLS:
                        yield {"kind": "interact", "tool": block.get("name"), "ts": ts,
                               "branch": branch, "cwd": cwd, "task": task_id_from(branch, cwd)}
                    elif bt == "tool_result" and block.get("is_error"):
                        yield {"kind": "error", "ts": ts, "branch": branch, "cwd": cwd,
                               "task": task_id_from(branch, cwd)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", default=True)
    ap.add_argument("--limit", type=int, default=0, help="max transcript files (0 = all)")
    ap.add_argument("--since", default="", help="only files modified on/after YYYY-MM-DD")
    ap.add_argument("--project", default="", help="only project dirs containing this substring")
    ap.add_argument("--output", default=DEFAULT_OUTPUT)
    args = ap.parse_args()

    since_ts = None
    if args.since:
        try:
            since_ts = datetime.strptime(args.since, "%Y-%m-%d").timestamp()
        except ValueError:
            print(f"bad --since: {args.since}", file=sys.stderr)
            return 2

    files = sorted(glob(os.path.join(PROJECTS_DIR, "**", "*.jsonl"), recursive=True))
    if args.project:
        files = [f for f in files if args.project in f]
    if since_ts:
        files = [f for f in files if os.path.getmtime(f) >= since_ts]
    if args.limit:
        files = files[: args.limit]

    if not files:
        out = {"status": "error", "error": "no transcripts matched", "next_action": "fix_error"}
        print(json.dumps(out)); open(args.output, "w").write(json.dumps(out))
        return 0

    # Aggregates
    cmd_counts = Counter()
    projects_seen = set()
    sessions = 0
    all_ts = []
    # task_id -> ordered list of (ts, cmd); plus project/branch
    task_events = defaultdict(list)
    task_meta = {}
    # session-scoped journeys for tasks we cannot key by id (no branch yet)
    session_cmd_events = defaultdict(list)  # path -> [(ts, cmd)]
    interactive_by_stage = Counter()  # stage(cmd) -> interaction count
    interactive_total = Counter()     # tool -> count
    errors_by_stage = Counter()
    transitions = Counter()           # (from,to) -> n
    out_of_order = 0

    for i, path in enumerate(files):
        sessions += 1
        slug = os.path.basename(os.path.dirname(path))
        projects_seen.add(slug)
        # Materialize the session's events so we can backfill task ids: a session
        # is almost always one task, so unkeyed events (e.g. interaction signals,
        # or commands run before the branch existed) inherit the session's
        # dominant task id.
        evlist = list(extract_events(path))
        sess_ids = Counter(ev["task"] for ev in evlist if ev["task"])
        session_task = sess_ids.most_common(1)[0][0] if sess_ids else None
        if session_task:
            for ev in evlist:
                if not ev["task"]:
                    ev["task"] = session_task
        # Per-session "current stage" for attributing interaction/errors.
        current_stage = None
        for ev in evlist:
            if ev["ts"]:
                all_ts.append(ev["ts"])
            if ev["kind"] == "cmd":
                cmd = ev["cmd"]
                cmd_counts[cmd] += 1
                current_stage = cmd
                session_cmd_events[path].append((ev["ts"], cmd))
                tid = ev["task"]
                if tid:
                    task_events[tid].append((ev["ts"], cmd))
                    meta = task_meta.setdefault(tid, {"project": slug, "branch": ev["branch"]})
            elif ev["kind"] == "interact":
                interactive_total[ev["tool"]] += 1
                if current_stage:
                    interactive_by_stage[current_stage] += 1
            elif ev["kind"] == "error":
                if current_stage:
                    errors_by_stage[current_stage] += 1
        if (i + 1) % 200 == 0:
            print(f"  ...{i + 1}/{len(files)} files", file=sys.stderr)

    # Build per-task ordered journeys + transitions + funnel + durations.
    funnel_reach = {stage: set() for stage in CANON}
    durations_start_to_close = []  # seconds
    stage_gaps = defaultdict(list)  # "from->to" -> [seconds]
    journeys = []
    abandoned = []   # started but never closed
    repeated_stage_tasks = 0

    for tid, evs in task_events.items():
        evs = [(t, c) for t, c in evs if c]  # keep all
        # order by timestamp (None sorts last)
        evs.sort(key=lambda x: (x[0] is None, x[0]))
        seq = [c for _, c in evs]
        # de-dup consecutive duplicates for the "shape" but track repeats
        if any(seq[i] == seq[i - 1] for i in range(1, len(seq))):
            repeated_stage_tasks += 1
        # funnel
        present = set(seq)
        for stage in CANON:
            if stage in present:
                funnel_reach[stage].add(tid)
        # transitions (collapse consecutive repeats for transition graph)
        collapsed = [seq[0]] if seq else []
        for c in seq[1:]:
            if c != collapsed[-1]:
                collapsed.append(c)
        for a, b in zip(collapsed, collapsed[1:]):
            transitions[(a, b)] += 1
            if a in CANON_INDEX and b in CANON_INDEX and CANON_INDEX[b] < CANON_INDEX[a]:
                pass  # backward = repeat/rework, counted below
        # durations start->close
        ts_by_cmd = {}
        for t, c in evs:
            if t and c not in ts_by_cmd:
                ts_by_cmd[c] = t
        if "task-start" in ts_by_cmd and "task-close" in ts_by_cmd:
            d = (ts_by_cmd["task-close"] - ts_by_cmd["task-start"]).total_seconds()
            if d >= 0:
                durations_start_to_close.append(d)
        # adjacent canon gaps
        for a, b in zip(collapsed, collapsed[1:]):
            if a in ts_by_cmd and b in ts_by_cmd:
                g = (ts_by_cmd[b] - ts_by_cmd[a]).total_seconds()
                if g >= 0:
                    stage_gaps[f"{a}->{b}"].append(g)
        # abandonment
        if ("task-start" in present) and ("task-close" not in present):
            abandoned.append(tid)
        journeys.append({"task": tid, "project": task_meta.get(tid, {}).get("project", ""),
                         "stages": collapsed, "events": len(seq)})

    # out-of-order count (recompute cleanly)
    out_of_order = sum(
        n for (a, b), n in transitions.items()
        if a in CANON_INDEX and b in CANON_INDEX and CANON_INDEX[b] < CANON_INDEX[a]
    )

    n_tasks = len(task_events)
    funnel = []
    for stage in CANON:
        cnt = len(funnel_reach[stage])
        funnel.append({"stage": stage, "tasks": cnt,
                       "pct_of_tasks": round(100 * cnt / n_tasks, 1) if n_tasks else 0.0})

    # commonly skipped stages: of tasks that reached close, how many skipped each mid stage
    closed_tasks = funnel_reach["task-close"]
    skipped = []
    for stage in ["task-design", "task-plan", "task-audit", "task-arch-review", "task-code-review"]:
        missed = len([t for t in closed_tasks if t not in funnel_reach[stage]])
        skipped.append({"stage": stage, "closed_tasks_skipping_it": missed,
                        "pct": round(100 * missed / len(closed_tasks), 1) if closed_tasks else 0.0})

    gap_summary = {}
    for k, vals in stage_gaps.items():
        if vals:
            gap_summary[k] = {"n": len(vals), "median_min": round(median(vals) / 60, 1),
                              "max_hr": round(max(vals) / 3600, 1)}
    # keep the most-traveled transitions only
    gap_summary = dict(sorted(gap_summary.items(), key=lambda kv: -kv[1]["n"])[:15])

    top_transitions = [
        {"from": a, "to": b, "n": n, "backward": bool(
            a in CANON_INDEX and b in CANON_INDEX and CANON_INDEX[b] < CANON_INDEX[a])}
        for (a, b), n in transitions.most_common(20)
    ]

    # interactive checkpoint rate per stage (verification density)
    interactive_stages = [
        {"stage": s, "interactions": interactive_by_stage[s],
         "invocations": cmd_counts.get(s, 0),
         "per_invocation": round(interactive_by_stage[s] / cmd_counts[s], 2) if cmd_counts.get(s) else 0.0}
        for s in sorted(interactive_by_stage, key=lambda s: -interactive_by_stage[s])
    ]

    out = {
        "status": "success",
        "next_action": "recommend_orchestration",
        "meta": {
            "files_scanned": len(files),
            "sessions": sessions,
            "projects": len(projects_seen),
            "tasks_identified": n_tasks,
            "date_range": {
                "first": min(all_ts).isoformat() if all_ts else None,
                "last": max(all_ts).isoformat() if all_ts else None,
            },
            "note": "Tasks keyed by 6-hex id from branch (feature/<ID>-) or worktree path. "
                    "task-capture often runs before a branch exists, so capture->start linkage is "
                    "intentionally weak here — that gap is itself a finding.",
        },
        "lifecycle_usage": [{"command": c, "count": n} for c, n in cmd_counts.most_common()],
        "adoption_funnel": funnel,
        "stages_skipped_by_closed_tasks": skipped,
        "ordering": {
            "top_transitions": top_transitions,
            "backward_transitions_total": out_of_order,
            "tasks_with_repeated_stages": repeated_stage_tasks,
        },
        "interactive_checkpoints": {
            "by_tool": dict(interactive_total),
            "by_stage": interactive_stages,
            "note": "Interactions attributed to the most recent lifecycle command in the same "
                    "session. High per_invocation => that stage is a genuine human gate, not a "
                    "candidate for silent auto-advance.",
        },
        "friction": {
            "abandoned_tasks_started_not_closed": len(abandoned),
            "abandoned_sample": abandoned[:15],
            "errors_by_stage": dict(errors_by_stage.most_common(10)),
            "stage_gaps_median": gap_summary,
            "start_to_close": {
                "n": len(durations_start_to_close),
                "median_hr": round(median(durations_start_to_close) / 3600, 1) if durations_start_to_close else None,
                "max_hr": round(max(durations_start_to_close) / 3600, 1) if durations_start_to_close else None,
            },
        },
        "journey_samples": sorted(journeys, key=lambda j: -j["events"])[:15],
    }

    payload = json.dumps(out, indent=2)
    print(payload)
    try:
        with open(args.output, "w") as fh:
            fh.write(payload)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
