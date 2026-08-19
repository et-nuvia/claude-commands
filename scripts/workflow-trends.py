#!/usr/bin/env python3
"""
workflow-trends.py — routine trend report over ~/.claude/tracking data.

Answers, from the command-tracking JSON logs:
  * How has task COMPLEXITY changed month over month?
  * Estimated effort (tokens_estimated) vs ACTUAL time (duration_seconds), and
    the effort-normalized efficiency trend (are we getting faster per unit of
    planned work?).
  * For the task workflow pipeline: per-command frequency, complexity, estimate,
    actual time — and how the SHAPE of the workflow has shifted over months
    (stage-adoption funnel relative to task-start).

Usage:
  workflow-trends.py                 # full human-readable report
  workflow-trends.py --json          # machine-readable JSON (LLM callers)
  workflow-trends.py --html OUT.html # write dashboard (Artifact-ready fragment;
                                     #   also opens standalone in a browser). In
                                     #   Claude Code, ask to "publish OUT.html as
                                     #   an artifact" to view it on claude.ai.
  workflow-trends.py --months 3      # restrict to the last N calendar months
  workflow-trends.py --dir PATH      # tracking dir (default ~/.claude/tracking)

Note on "estimated vs actual TIME": the tracker records an effort estimate in
TOKENS (tokens_estimated), not minutes, and command records live in a different
session-id space than the realized token counts — so a literal estimated-time
vs actual-time join is not possible. The honest proxy used here is
sec / 1k-estimated-tokens: actual wall-clock time spent per unit of planned
effort. Lower = delivering planned work faster.
"""
from __future__ import annotations
import argparse, json, sys, statistics
from collections import defaultdict, Counter
from datetime import datetime
from pathlib import Path

# The canonical task workflow pipeline, in order.
PIPELINE = [
    "task-capture", "task-start", "task-design", "task-plan", "task-continue",
    "task-audit", "task-arch-review", "task-code-review", "create-pr",
    "review-pr", "task-close",
]
EST_OUTLIER = 1_000_000  # ignore absurd tokens_estimated values above this


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def load(tracking_dir: Path, months: int | None):
    """Return command records that have a timestamp + command."""
    recs = []
    for f in sorted(tracking_dir.glob("*.json")):
        try:
            data = json.loads(f.read_text())
        except Exception as e:
            print(f"warn: skip {f.name}: {e}", file=sys.stderr)
            continue
        if not isinstance(data, list):
            continue
        for e in data:
            if not isinstance(e, dict) or not e.get("command"):
                continue
            ts = parse_ts(e.get("timestamp"))
            if ts is None:
                continue
            recs.append({
                "cmd": e["command"],
                "month": ts.strftime("%Y-%m"),
                "ts": ts,
                "project": (e.get("folder") or e.get("project") or "?").strip().strip('"'),
                "status": e.get("status") or "?",
                "complexity": e.get("complexity"),
                "est": e.get("tokens_estimated"),
                "dur": e.get("duration_seconds"),
                "cost": e.get("cost_estimated"),
            })
    recs.sort(key=lambda r: r["ts"])
    if months and recs:
        keep = sorted({r["month"] for r in recs})[-months:]
        recs = [r for r in recs if r["month"] in keep]
    return recs


def _med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else 0


def _mean(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.mean(xs) if xs else 0


def monthly_overall(recs):
    """Overall complexity / effort / time / efficiency per month (completed runs)."""
    out = {}
    by = defaultdict(list)
    for r in recs:
        if r["status"] == "completed" and r["complexity"] is not None:
            by[r["month"]].append(r)
    for m, rs in by.items():
        comps = [r["complexity"] for r in rs]
        durs = [r["dur"] for r in rs if r["dur"]]
        ests = [r["est"] for r in rs if r["est"] and r["est"] < EST_OUTLIER]
        pairs = [(r["dur"], r["est"]) for r in rs
                 if r["dur"] and r["est"] and r["est"] < EST_OUTLIER]
        tot_est = sum(p[1] for p in pairs)
        out[m] = {
            "runs": len(rs),
            "avg_complexity": round(_mean(comps), 2),
            "pct_hard": round(100 * sum(c >= 4 for c in comps) / len(rs)),
            "median_actual_sec": round(_med(durs)),
            "median_est_tokens": round(_med(ests)),
            "sec_per_1k_est": round(sum(p[0] for p in pairs) / (tot_est / 1000), 1) if tot_est else 0,
        }
    return dict(sorted(out.items()))


def duration_by_complexity(recs):
    """Median actual seconds per complexity level, per month. The cleanest
    'are we faster at equally-hard work' signal."""
    months = sorted({r["month"] for r in recs
                     if r["status"] == "completed" and r["complexity"] is not None})
    table = {}
    for cx in range(1, 6):
        table[cx] = []
        for m in months:
            ds = [r["dur"] for r in recs
                  if r["month"] == m and r["complexity"] == cx and r["dur"]
                  and r["status"] == "completed"]
            table[cx].append(round(_med(ds)) if ds else None)
    return months, table


def pipeline_command_stats(recs):
    """Per-pipeline-command aggregate stats (all-time)."""
    stats = {}
    for cmd in PIPELINE:
        rs = [r for r in recs if r["cmd"] == cmd]
        comp = [r["complexity"] for r in rs if r["complexity"] is not None]
        durs = [r["dur"] for r in rs if r["dur"]]
        ests = [r["est"] for r in rs if r["est"] and r["est"] < EST_OUTLIER]
        stats[cmd] = {
            "runs": len(rs),
            "avg_complexity": round(_mean(comp), 2) if comp else 0,
            "median_est_tokens": round(_med(ests)),
            "median_actual_sec": round(_med(durs)),
            "avg_actual_sec": round(_mean(durs)),
            "total_hours": round(sum(durs) / 3600, 1),
        }
    return stats


def pipeline_monthly_freq(recs):
    """Monthly run count per pipeline command (has the mix shifted?)."""
    months = sorted({r["month"] for r in recs})
    freq = {cmd: [sum(1 for r in recs if r["month"] == m and r["cmd"] == cmd)
                  for m in months] for cmd in PIPELINE}
    return months, freq


def stage_adoption(recs):
    """Per month: each pipeline stage's run count as a ratio of task-start count.
    Shows which stages you lean on more/less over time (workflow shape shift)."""
    months = sorted({r["month"] for r in recs})
    counts = {m: Counter() for m in months}
    for r in recs:
        if r["cmd"] in PIPELINE:
            counts[r["month"]][r["cmd"]] += 1
    adoption = {}
    for cmd in PIPELINE:
        row = []
        for m in months:
            base = counts[m].get("task-start", 0)
            row.append(round(counts[m][cmd] / base, 2) if base else None)
        adoption[cmd] = row
    return months, adoption


def build_report(recs):
    mo = monthly_overall(recs)
    dcx_months, dcx = duration_by_complexity(recs)
    freq_months, freq = pipeline_monthly_freq(recs)
    adopt_months, adopt = stage_adoption(recs)
    return {
        "generated": recs[-1]["ts"].strftime("%Y-%m-%d") if recs else None,
        "total_command_runs": len(recs),
        "date_range": [recs[0]["ts"].strftime("%Y-%m-%d"), recs[-1]["ts"].strftime("%Y-%m-%d")] if recs else [],
        "monthly_overall": mo,
        "duration_by_complexity": {"months": dcx_months, "median_sec": dcx},
        "pipeline_command_stats": pipeline_command_stats(recs),
        "pipeline_monthly_freq": {"months": freq_months, "counts": freq},
        "stage_adoption_vs_start": {"months": adopt_months, "ratio": adopt},
    }


# ---------------------------------------------------------------- human output
def fmt_sec(s):
    if not s:
        return "-"
    return f"{s/60:.1f}m" if s >= 90 else f"{int(s)}s"


def print_report(rep):
    R = rep
    p = print
    p(f"\n\033[1mWORKFLOW & COMPLEXITY TRENDS\033[0m")
    p(f"{R['total_command_runs']} command runs · {R['date_range'][0]} → {R['date_range'][1]}\n")

    p("\033[1m1. Complexity, effort & time by month\033[0m")
    p(f"  {'Month':<9}{'Runs':>6}{'AvgCx':>7}{'Hard%':>7}{'MedTime':>9}{'MedEst':>9}{'sec/1kEst':>11}")
    for m, d in R["monthly_overall"].items():
        p(f"  {m:<9}{d['runs']:>6}{d['avg_complexity']:>7.2f}{d['pct_hard']:>6}%"
          f"{fmt_sec(d['median_actual_sec']):>9}{d['median_est_tokens']//1000:>8}k{d['sec_per_1k_est']:>11}")
    p("  (Hard% = share of runs at complexity >=4.  sec/1kEst lower = faster per unit of planned work.)\n")

    p("\033[1m2. Median ACTUAL time at fixed complexity (are we faster at equally-hard work?)\033[0m")
    dm = R["duration_by_complexity"]["months"]
    lbl = [x[-2:] for x in dm]
    p(f"  {'Cx':<4}" + "".join(f"{l:>8}" for l in lbl))
    for cx in range(1, 6):
        row = R["duration_by_complexity"]["median_sec"][cx] if isinstance(R["duration_by_complexity"]["median_sec"], dict) else R["duration_by_complexity"]["median_sec"][str(cx)]
        p(f"  {cx:<4}" + "".join(f"{(fmt_sec(v) if v else '-'):>8}" for v in row))
    p("  (Downward left->right = improvement.)\n")

    p("\033[1m3. Task pipeline — per-command stats (all-time)\033[0m")
    p(f"  {'Command':<18}{'Runs':>6}{'AvgCx':>7}{'MedEst':>8}{'MedTime':>9}{'AvgTime':>9}{'TotHrs':>8}")
    for cmd in PIPELINE:
        d = R["pipeline_command_stats"][cmd]
        p(f"  {cmd:<18}{d['runs']:>6}{d['avg_complexity']:>7.2f}{d['median_est_tokens']//1000:>7}k"
          f"{fmt_sec(d['median_actual_sec']):>9}{fmt_sec(d['avg_actual_sec']):>9}{d['total_hours']:>8}")
    p()

    p("\033[1m4. Pipeline command frequency by month (has the workflow shifted?)\033[0m")
    fm = R["pipeline_monthly_freq"]["months"]
    lbl = [x[-2:] for x in fm]
    p(f"  {'Command':<18}" + "".join(f"{l:>6}" for l in lbl))
    for cmd in PIPELINE:
        row = R["pipeline_monthly_freq"]["counts"][cmd]
        p(f"  {cmd:<18}" + "".join(f"{v:>6}" for v in row))
    p()

    p("\033[1m5. Stage adoption relative to task-start (workflow shape)\033[0m")
    am = R["stage_adoption_vs_start"]["months"]
    lbl = [x[-2:] for x in am]
    p(f"  {'Per task-start':<18}" + "".join(f"{l:>7}" for l in lbl))
    for cmd in PIPELINE:
        if cmd == "task-start":
            continue
        row = R["stage_adoption_vs_start"]["ratio"][cmd]
        p(f"  {cmd:<18}" + "".join(f"{(f'{v:.2f}' if v is not None else '-'):>7}" for v in row))
    p("  (e.g. 0.50 = you ran this stage half as often as you started tasks that month.)\n")


def main():
    ap = argparse.ArgumentParser(description="Task workflow & complexity trend report.")
    ap.add_argument("--dir", default=str(Path.home() / ".claude" / "tracking"))
    ap.add_argument("--months", type=int, default=None, help="restrict to last N months")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    ap.add_argument("--html", metavar="OUT", help="write HTML dashboard to OUT")
    args = ap.parse_args()

    tracking = Path(args.dir).expanduser()
    if not tracking.is_dir():
        print(f"error: tracking dir not found: {tracking}", file=sys.stderr)
        sys.exit(1)

    recs = load(tracking, args.months)
    if not recs:
        print("error: no command records found", file=sys.stderr)
        sys.exit(1)

    rep = build_report(recs)

    if args.html:
        Path(args.html).write_text(render_html(rep))
        print(f"wrote {args.html}")
        return
    if args.json:
        print(json.dumps(rep, indent=2))
        return
    print_report(rep)


def render_html(rep):
    data = json.dumps(rep)
    return HTML_TEMPLATE.replace("__DATA__", data)


# NOTE: emitted as an Artifact-ready fragment — no <!doctype>/<html>/<head>/<body>
# wrapper (the Artifact host adds those). It still renders when opened directly
# in a browser. Scoped under #wft so the page's own reset can't bleed in.
HTML_TEMPLATE = r"""<title>Task Workflow & Complexity Trends</title>
<style>
#wft{--bg:#0f1115;--panel:#171a21;--ink:#e8ecf2;--muted:#96a0b0;--line:#2a313d;
--good:#43c59e;--bad:#e5686a;--warn:#e0a44a;font-family:-apple-system,Segoe UI,Roboto,sans-serif;
background:var(--bg);color:var(--ink);margin:0;padding:28px;min-height:100vh}
#wft *{box-sizing:border-box}
.wrap{max-width:1080px;margin:0 auto}h1{font-size:24px;margin:0 0 2px}
#wft .sub{color:var(--muted);font-size:13px;margin-bottom:24px}
#wft h2{font-size:13px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin:30px 0 12px}
#wft .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px;overflow-x:auto}
#wft table{width:100%;border-collapse:collapse;font-size:13px;font-variant-numeric:tabular-nums}
#wft th,#wft td{text-align:right;padding:7px 9px;border-bottom:1px solid var(--line)}
#wft th:first-child,#wft td:first-child{text-align:left}#wft th{color:var(--muted);font-size:11px;text-transform:uppercase}
#wft tr:last-child td{border-bottom:none}#wft .note{font-size:12px;color:var(--muted);margin-top:8px}
#wft svg{width:100%;height:auto}#wft .legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin-bottom:8px}
#wft .legend i{width:10px;height:10px;border-radius:3px;display:inline-block;margin-right:5px}
</style><div id="wft"><div class="wrap">
<h1>Task Workflow & Complexity Trends</h1><div class="sub" id="sub"></div>
<h2>Complexity, effort &amp; time by month</h2><div class="panel"><table id="t1"></table></div>
<h2>Actual time at fixed complexity — faster at equally-hard work?</h2>
<div class="panel"><div class="legend" id="lg"></div><svg id="cx" viewBox="0 0 980 320"></svg></div>
<h2>Pipeline command frequency by month</h2><div class="panel"><table id="t2"></table></div>
<h2>Per-command stats (all-time)</h2><div class="panel"><table id="t3"></table></div>
<h2>Stage adoption relative to task-start</h2><div class="panel"><table id="t4"></table>
<div class="note">Ratio of stage runs to task-start runs that month. Rising = you lean on that stage more.</div></div>
</div><script>
const R=__DATA__;const CC=['#5b6bff','#43c59e','#6ea8fe','#e0a44a','#e5686a'];
const mo=(m)=>({'01':'Jan','02':'Feb','03':'Mar','04':'Apr','05':'May','06':'Jun','07':'Jul','08':'Aug','09':'Sep','10':'Oct','11':'Nov','12':'Dec'}[m.slice(5)]);
document.getElementById('sub').textContent=`${R.total_command_runs} command runs · ${R.date_range[0]} → ${R.date_range[1]}`;
// t1
let mm=Object.keys(R.monthly_overall);
document.getElementById('t1').innerHTML='<thead><tr><th>Month</th><th>Runs</th><th>Avg cx</th><th>Hard%</th><th>Med time</th><th>Med est</th><th>sec/1k est</th></tr></thead><tbody>'+
mm.map(m=>{let d=R.monthly_overall[m];return `<tr><td>${mo(m)}</td><td>${d.runs}</td><td>${d.avg_complexity}</td><td>${d.pct_hard}%</td><td>${d.median_actual_sec}s</td><td>${d.median_est_tokens/1000}k</td><td>${d.sec_per_1k_est}</td></tr>`}).join('')+'</tbody>';
// cx chart
const dm=R.duration_by_complexity.months, med=R.duration_by_complexity.median_sec;
document.getElementById('lg').innerHTML=[1,2,3,4,5].map(c=>`<span><i style="background:${CC[c-1]}"></i>Cx ${c}</span>`).join('');
(function(){const svg=document.getElementById('cx');const W=980,H=320,L=44,Rp=14,T=14,B=30,pw=W-L-Rp,ph=H-T-B;
let ymax=0;[1,2,3,4,5].forEach(c=>(med[c]||med[String(c)]||[]).forEach(v=>{if(v)ymax=Math.max(ymax,v)}));ymax=Math.ceil(ymax/100)*100||100;
const n=dm.length,x=i=>L+pw*(n<2?.5:i/(n-1)),y=v=>T+ph*(1-v/ymax);let g='';
for(let t=0;t<=4;t++){let gv=ymax*t/4,yy=y(gv);g+=`<line x1="${L}" y1="${yy}" x2="${W-Rp}" y2="${yy}" stroke="#2a313d"/><text x="${L-6}" y="${yy+4}" fill="#96a0b0" font-size="11" text-anchor="end">${Math.round(gv)}s</text>`}
dm.forEach((m,i)=>g+=`<text x="${x(i)}" y="${H-10}" fill="#96a0b0" font-size="11" text-anchor="middle">${mo(m)}</text>`);
[1,2,3,4,5].forEach(c=>{let row=med[c]||med[String(c)]||[];let pts=row.map((v,i)=>v?[x(i),y(v)]:null).filter(Boolean);
if(pts.length){g+=`<path d="${pts.map((p,i)=>(i?'L':'M')+p[0].toFixed(1)+','+p[1].toFixed(1)).join(' ')}" fill="none" stroke="${CC[c-1]}" stroke-width="2.5"/>`;pts.forEach(p=>g+=`<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="3.4" fill="${CC[c-1]}"/>`)}});
svg.innerHTML=g})();
// t2 freq
const fm=R.pipeline_monthly_freq.months, fc=R.pipeline_monthly_freq.counts;
document.getElementById('t2').innerHTML='<thead><tr><th>Command</th>'+fm.map(m=>`<th>${mo(m)}</th>`).join('')+'</tr></thead><tbody>'+
Object.keys(fc).map(c=>`<tr><td>${c}</td>`+fc[c].map(v=>`<td>${v}</td>`).join('')+'</tr>').join('')+'</tbody>';
// t3
const ps=R.pipeline_command_stats;
document.getElementById('t3').innerHTML='<thead><tr><th>Command</th><th>Runs</th><th>Avg cx</th><th>Med est</th><th>Med time</th><th>Avg time</th><th>Total hrs</th></tr></thead><tbody>'+
Object.keys(ps).map(c=>{let d=ps[c];return `<tr><td>${c}</td><td>${d.runs}</td><td>${d.avg_complexity}</td><td>${Math.round(d.median_est_tokens/1000)}k</td><td>${d.median_actual_sec}s</td><td>${d.avg_actual_sec}s</td><td>${d.total_hours}</td></tr>`}).join('')+'</tbody>';
// t4
const am=R.stage_adoption_vs_start.months, ar=R.stage_adoption_vs_start.ratio;
document.getElementById('t4').innerHTML='<thead><tr><th>Per task-start</th>'+am.map(m=>`<th>${mo(m)}</th>`).join('')+'</tr></thead><tbody>'+
Object.keys(ar).filter(c=>c!=='task-start').map(c=>`<tr><td>${c}</td>`+ar[c].map(v=>`<td>${v==null?'-':v.toFixed(2)}</td>`).join('')+'</tr>').join('')+'</tbody>';
</script></div>"""


if __name__ == "__main__":
    main()
