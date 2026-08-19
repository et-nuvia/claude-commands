#!/usr/bin/env python3
"""Analyze captured GitHub Actions timing data and surface speed-up candidates.

Reads the JSONL written by ci-metrics-capture.sh and emits one JSON document:
where the wall-clock actually goes (workflow -> critical-path job -> step), how
much of it is queue rather than work, what retries cost, and a ranked list of
opportunities with an estimated per-run saving for each.

The estimates are deliberately conservative and stated in seconds saved off the
*critical path*, because that is the only saving a developer actually feels.

Usage:
  ci-metrics-analyze.py [--in DIR] [--workflow NAME] [--branch NAME]
                        [--top N] [--format json|markdown]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from typing import Any


def parse_ts(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").timestamp()
    except ValueError:
        return None


def pct(values: list[float], p: float) -> float:
    """Nearest-rank percentile. Small samples make interpolation dishonest."""
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(round(p / 100.0 * len(ordered) + 0.5)) - 1))
    return round(ordered[index], 1)


def stats(values: list[float]) -> dict[str, Any]:
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "p50": pct(values, 50),
        "p90": pct(values, 90),
        "max": round(max(values), 1),
        "total": round(sum(values), 1),
    }


def read_jsonl(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return rows


# Steps the runner injects into every job. They are real wall-clock but not
# something the pipeline author can edit, so they are tracked separately.
RUNNER_STEPS = {"Set up job", "Complete job", "Post job cleanup"}

CACHEABLE = re.compile(
    r"(npm|yarn|pnpm|pip|poetry|uv|bundle|composer|go mod|cargo)\b.*(install|ci|sync)"
    r"|install (deps|dependencies|packages)"
    r"|setup-(node|python|go|java)"
    r"|(^|\s)(build|compile)(\s|$)",
    re.IGNORECASE,
)
DOWNLOAD_BOUND = re.compile(
    r"(trivy|gitleaks|scan|audit|docker (build|pull|push)|buildx|login|checkout)",
    re.IGNORECASE,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="in_dir", default=None)
    parser.add_argument("--workflow", default=None, help="filter to one workflow name")
    parser.add_argument("--branch", default=None, help="filter to one branch")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--format", default="json", choices=["json", "markdown"])
    args = parser.parse_args()

    in_dir = args.in_dir
    if not in_dir:
        print(json.dumps({"error": "--in DIR required (see ci-metrics-capture.sh output)"}))
        return 2

    runs = read_jsonl(os.path.join(in_dir, "runs.jsonl"))
    jobs = read_jsonl(os.path.join(in_dir, "jobs.jsonl"))
    if not runs:
        print(json.dumps({"error": f"no runs captured in {in_dir}"}))
        return 1

    if args.workflow:
        runs = [r for r in runs if r.get("name") == args.workflow]
    if args.branch:
        runs = [r for r in runs if r.get("head_branch") == args.branch]

    run_by_id = {r["id"]: r for r in runs}
    jobs_by_run: dict[int, list[dict]] = defaultdict(list)
    for job in jobs:
        if job.get("run_id") in run_by_id:
            jobs_by_run[job["run_id"]].append(job)

    # ---- per-run rollup -------------------------------------------------
    wf_runs: dict[str, list[dict]] = defaultdict(list)
    job_durations: dict[tuple[str, str], list[float]] = defaultdict(list)
    job_queues: dict[tuple[str, str], list[float]] = defaultdict(list)
    job_fails: dict[tuple[str, str], int] = defaultdict(int)
    job_runs_seen: dict[tuple[str, str], int] = defaultdict(int)
    critical_hits: dict[tuple[str, str], int] = defaultdict(int)
    step_durations: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    retry_cost: list[float] = []

    for run in runs:
        wf = run.get("name") or run.get("path") or "unknown"
        run_jobs = [j for j in jobs_by_run.get(run["id"], []) if j.get("run_attempt", 1) == run.get("run_attempt", 1)]
        earlier = [j for j in jobs_by_run.get(run["id"], []) if j.get("run_attempt", 1) != run.get("run_attempt", 1)]
        if not run_jobs:
            continue

        start = parse_ts(run.get("run_started_at")) or parse_ts(run.get("created_at"))
        ends = [parse_ts(j.get("completed_at")) for j in run_jobs]
        ends = [e for e in ends if e]
        if not start or not ends:
            continue
        wall = max(ends) - start

        # Cost of discarded attempts, i.e. what flakiness/retries burn.
        for job in earlier:
            s, c = parse_ts(job.get("started_at")), parse_ts(job.get("completed_at"))
            if s and c:
                retry_cost.append(c - s)

        busy = 0.0
        longest_job = 0.0
        critical_job, critical_end = None, 0.0
        for job in run_jobs:
            name = job.get("name") or "?"
            key = (wf, name)
            created = parse_ts(job.get("created_at"))
            started = parse_ts(job.get("started_at"))
            completed = parse_ts(job.get("completed_at"))
            job_runs_seen[key] += 1
            if job.get("conclusion") not in ("success", "skipped", None):
                job_fails[key] += 1
            if created and started:
                job_queues[key].append(max(0.0, started - created))
            if started and completed:
                dur = completed - started
                job_durations[key].append(dur)
                busy += dur
                longest_job = max(longest_job, dur)
                if completed > critical_end:
                    critical_end, critical_job = completed, name
                for step in job.get("steps") or []:
                    ss, sc = parse_ts(step.get("started_at")), parse_ts(step.get("completed_at"))
                    if ss and sc and sc >= ss:
                        step_durations[(wf, name, step.get("name") or "?")].append(sc - ss)

        if critical_job:
            critical_hits[(wf, critical_job)] += 1

        wf_runs[wf].append(
            {
                "wall": wall,
                "busy": busy,
                # Wall clock NOT explained by the single longest job: setup/discover
                # jobs, runner spin-up, and every `needs:` hop. Deliberately not
                # "time until the critical job starts" — pipelines that end in a
                # trivial summary job make that metric read as pure overhead when
                # it is really the chain doing work.
                "overhead": max(0.0, wall - longest_job),
                "jobs": len(run_jobs),
                "ok": run.get("conclusion") == "success",
                "attempts": run.get("run_attempt", 1),
                "branch": run.get("head_branch"),
                "event": run.get("event"),
            }
        )

    # ---- workflow summaries ---------------------------------------------
    workflows = []
    for wf, entries in sorted(wf_runs.items(), key=lambda kv: -sum(e["wall"] for e in kv[1])):
        walls = [e["wall"] for e in entries]
        busies = [e["busy"] for e in entries]
        workflows.append(
            {
                "workflow": wf,
                "runs": len(entries),
                "success_rate": round(sum(1 for e in entries if e["ok"]) / len(entries), 3),
                "retried_runs": sum(1 for e in entries if e["attempts"] > 1),
                "wall_clock_s": stats(walls),
                "overhead_s": stats([e["overhead"] for e in entries]),
                "critical_job": max(
                    ((j, c) for (w, j), c in critical_hits.items() if w == wf),
                    key=lambda t: t[1],
                    default=(None, 0),
                )[0],
                # >1 means work genuinely overlaps; ~1 means the graph is a chain.
                "parallelism": round(sum(busies) / sum(walls), 2) if sum(walls) else 0,
                "jobs_per_run": round(statistics.mean(e["jobs"] for e in entries), 1),
            }
        )

    # ---- job table -------------------------------------------------------
    job_rows = []
    for key, durs in job_durations.items():
        wf, name = key
        seen = job_runs_seen[key] or 1
        job_rows.append(
            {
                "workflow": wf,
                "job": name,
                "duration_s": stats(durs),
                "queue_s": stats(job_queues.get(key, [])),
                "critical_path_share": round(critical_hits.get(key, 0) / seen, 2),
                "failure_rate": round(job_fails.get(key, 0) / seen, 3),
            }
        )
    job_rows.sort(key=lambda r: -(r["duration_s"]["p50"] * r["duration_s"]["n"]))

    # ---- step table ------------------------------------------------------
    step_rows = []
    for (wf, job, step), durs in step_durations.items():
        s = stats(durs)
        if s["p50"] < 1:
            continue
        step_rows.append(
            {
                "workflow": wf,
                "job": job,
                "step": step,
                "runner_managed": step in RUNNER_STEPS,
                "p50": s["p50"],
                "p90": s["p90"],
                "n": s["n"],
                # High spread = network/registry bound, not CPU bound.
                "spread": round(s["p90"] / s["p50"], 2) if s["p50"] else 0,
                "cumulative_s": s["total"],
            }
        )
    step_rows.sort(key=lambda r: -r["cumulative_s"])

    # ---- opportunity ranking --------------------------------------------
    critical_jobs = {
        (r["workflow"], r["job"]) for r in job_rows if r["critical_path_share"] >= 0.2
    }
    opportunities = []

    for row in step_rows:
        if row["runner_managed"]:
            continue
        on_critical = (row["workflow"], row["job"]) in critical_jobs
        weight = 1.0 if on_critical else 0.3

        if CACHEABLE.search(row["step"]) and row["p50"] >= 20:
            opportunities.append(
                {
                    "kind": "cacheable-step",
                    "where": f"{row['workflow']} / {row['job']} / {row['step']}",
                    "observed_p50_s": row["p50"],
                    "on_critical_path": on_critical,
                    "saving_type": "wall_clock" if on_critical else "runner_minutes",
                    "est_saving_s_per_run": round(row["p50"] * 0.6 * weight, 1),
                    "why": "dependency/build step long enough that a warm cache or a prebuilt "
                    "image should dominate it",
                }
            )
        elif row["spread"] >= 2.0 and row["p50"] >= 15:
            opportunities.append(
                {
                    "kind": "high-variance-step",
                    "where": f"{row['workflow']} / {row['job']} / {row['step']}",
                    "observed_p50_s": row["p50"],
                    "observed_p90_s": row["p90"],
                    "on_critical_path": on_critical,
                    "saving_type": "wall_clock" if on_critical else "runner_minutes",
                    "est_saving_s_per_run": round((row["p90"] - row["p50"]) * weight, 1),
                    "why": "p90 is far above p50 — network/registry bound; pin, mirror or cache "
                    "the artifact to cut the tail",
                }
            )

    for row in job_rows:
        q = row["queue_s"]
        if q.get("n") and q["p50"] >= 15:
            opportunities.append(
                {
                    "kind": "queue-wait",
                    "where": f"{row['workflow']} / {row['job']}",
                    "observed_p50_s": q["p50"],
                    "on_critical_path": row["critical_path_share"] >= 0.2,
                    "saving_type": "wall_clock" if row["critical_path_share"] >= 0.2 else "runner_minutes",
                    "est_saving_s_per_run": q["p50"],
                    "why": "time between job creation and a runner picking it up — split fewer, "
                    "fatter jobs or use a larger/self-hosted pool",
                }
            )
        if row["failure_rate"] >= 0.15:
            opportunities.append(
                {
                    "kind": "unreliable-job",
                    "where": f"{row['workflow']} / {row['job']}",
                    "failure_rate": row["failure_rate"],
                    "on_critical_path": row["critical_path_share"] >= 0.2,
                    # A failing job costs a whole extra pipeline round-trip for the human.
                    "saving_type": "developer_round_trips",
                    "est_saving_s_per_run": round(row["duration_s"]["p50"] * row["failure_rate"], 1),
                    "why": "fails often enough that retries are a material share of total CI time",
                }
            )

    # Duplicated work: the same step name doing real work in several jobs.
    by_step_name: dict[str, set[str]] = defaultdict(set)
    step_cost: dict[str, float] = defaultdict(float)
    for row in step_rows:
        if row["runner_managed"] or row["p50"] < 10:
            continue
        by_step_name[row["step"]].add(f"{row['workflow']}/{row['job']}")
        step_cost[row["step"]] += row["p50"]
    for step, places in by_step_name.items():
        if len(places) >= 3:
            opportunities.append(
                {
                    "kind": "duplicated-work",
                    "where": step,
                    "job_count": len(places),
                    "jobs": sorted(places)[:8],
                    # Billed runner time, NOT wall clock: these jobs run in parallel, so
                    # collapsing them frees budget rather than shortening the run.
                    "saving_type": "runner_minutes",
                    "est_saving_s_per_run": round(step_cost[step] - step_cost[step] / len(places), 1),
                    "caveat": "grouped by step NAME — confirm the jobs are doing identical work "
                    "(a matrix building three different services shares a step name but not the work)",
                    "why": "the same step name does real work in several parallel jobs — if it is "
                    "the same work, do it once and pass the result via an artifact or image",
                }
            )

    for wf in workflows:
        over = wf["overhead_s"]
        if over.get("n") and over["p50"] >= 20:
            opportunities.append(
                {
                    "kind": "orchestration-overhead",
                    "where": wf["workflow"],
                    "observed_p50_s": over["p50"],
                    "share_of_run": round(over["p50"] / wf["wall_clock_s"]["p50"], 2),
                    "saving_type": "wall_clock",
                    "est_saving_s_per_run": round(over["p50"] * 0.6, 1),
                    "why": "wall clock beyond the single longest job — setup/discover jobs, "
                    "runner spin-up and `needs:` hops; collapse cheap gating jobs or start "
                    "the long job in parallel with them",
                }
            )
        if wf["parallelism"] <= 1.2 and wf["jobs_per_run"] >= 3:
            opportunities.append(
                {
                    "kind": "serialized-graph",
                    "where": wf["workflow"],
                    "parallelism": wf["parallelism"],
                    "jobs_per_run": wf["jobs_per_run"],
                    "saving_type": "wall_clock",
                    "est_saving_s_per_run": round(wf["wall_clock_s"]["p50"] * 0.25, 1),
                    "why": "jobs barely overlap despite there being several of them — `needs:` "
                    "is probably stricter than the real data dependencies",
                }
            )

    # Wall-clock savings are what a developer actually feels; rank them above
    # savings that only free budget.
    rank = {"wall_clock": 0, "developer_round_trips": 1, "runner_minutes": 2}
    opportunities.sort(
        key=lambda o: (rank.get(o.get("saving_type"), 3), -o.get("est_saving_s_per_run", 0))
    )
    opportunities = opportunities[: args.top]

    report = {
        "source": in_dir,
        "window": {
            "runs_analyzed": sum(len(v) for v in wf_runs.values()),
            "first_run": min((r.get("created_at") or "") for r in runs),
            "last_run": max((r.get("created_at") or "") for r in runs),
        },
        "retry_waste": {
            "discarded_job_runs": len(retry_cost),
            "wasted_s_total": round(sum(retry_cost), 1),
        },
        "workflows": workflows,
        "jobs": job_rows[: args.top * 2],
        "steps": [s for s in step_rows if not s["runner_managed"]][: args.top * 2],
        "runner_overhead_steps": [s for s in step_rows if s["runner_managed"]][:10],
        "opportunities": opportunities,
    }

    if args.format == "markdown":
        emit_markdown(report)
    else:
        print(json.dumps(report, indent=2))
    return 0


def emit_markdown(report: dict) -> None:
    out = [f"# CI metrics — {report['window']['runs_analyzed']} runs", ""]
    out.append("## Workflows")
    out.append("| workflow | runs | p50 wall | p90 wall | overhead | parallelism | success | critical job |")
    out.append("|---|---|---|---|---|---|---|---|")
    for wf in report["workflows"]:
        out.append(
            f"| {wf['workflow']} | {wf['runs']} | {wf['wall_clock_s']['p50']}s | "
            f"{wf['wall_clock_s']['p90']}s | {wf['overhead_s']['p50']}s | {wf['parallelism']}x | "
            f"{wf['success_rate']} | {wf['critical_job'] or '-'} |"
        )
    out.append("")
    out.append("## Slowest steps")
    out.append("| workflow / job / step | p50 | p90 | n |")
    out.append("|---|---|---|---|")
    for s in report["steps"][:20]:
        out.append(f"| {s['workflow']} / {s['job']} / {s['step']} | {s['p50']}s | {s['p90']}s | {s['n']} |")
    out.append("")
    out.append("## Opportunities")
    for o in report["opportunities"]:
        out.append(
            f"- **{o['kind']}** [{o.get('saving_type', '?')}] — {o['where']} — "
            f"est. {o.get('est_saving_s_per_run', 0)}s/run — {o['why']}"
        )
    print("\n".join(out))


if __name__ == "__main__":
    sys.exit(main())
