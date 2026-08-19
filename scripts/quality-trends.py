#!/usr/bin/env python3
"""
quality-trends.py — track review/audit FINDINGS over time.

Theory: as we build code the right way, the number of issues surfaced by
task-audit / task-arch-review / task-code-review should trend DOWN.

Those counts don't live in ~/.claude/tracking (that only logs command runs);
they live in the V4 review DOCUMENTS the commands emit:
  CRV = code review   AUD = audit   ARC = architecture review   FRV = feature review

This walks the project tree, parses each doc's findings by severity, dates it
from the V4 filename (<TASKID>-<YYMMDDHHMM>-<TYPE>-...), and reports counts +
issues-per-review by month. Issues-per-review (not raw counts) is the real
improvement signal, since raw counts scale with how many reviews you ran.

Severity detection (a doc uses one style; we don't double-count):
  1. inline tags  ... (HIGH, security) / (MEDIUM, migration) / (CRITICAL) ...
  2. emoji tables 🔴 Critical | 🟠 High | 🟡 Medium | 🔵 Low   (placeholder rows skipped)
  3. P0/P1/P2/P3  mapped to critical/high/medium/low

Usage:
  quality-trends.py                     # human-readable report
  quality-trends.py --json              # machine-readable
  quality-trends.py --html OUT.html     # Artifact-ready dashboard fragment
  quality-trends.py --root PATH ...     # project roots (default ~/projects)
  quality-trends.py --months N          # last N months only
"""
from __future__ import annotations
import argparse, json, os, re, sys
from collections import defaultdict
from pathlib import Path

TYPES = ["CRV", "AUD", "ARC", "FRV"]
SEVS = ["critical", "high", "medium", "low"]
FNAME_DT = re.compile(r"-(\d{10})-(?:" + "|".join(TYPES) + r")-", re.I)
# External = reviewing someone else's PR (didn't write the code). These use a
# PR-style name (CRV-pr-51-..., review-pr) instead of the V4 <TASKID>-<dt> form.
# Kept OUT of the "am I building my own code better?" headline.
EXTERNAL_RX = re.compile(r"(?:^|[-_])pr[-_]?\d+|review[-_]pr|[-_]pr-", re.I)
INLINE = re.compile(r"\((?:\s*)(CRITICAL|HIGH|MEDIUM|LOW)(?:\s*[,)])", re.I)
EMOJI = {"🔴": "critical", "🟠": "high", "🟡": "medium", "🔵": "low"}
PMAP = {"P0": "critical", "P1": "high", "P2": "medium", "P3": "low"}
PLACEHOLDER = re.compile(r"\[Issue\]|\[Recommendation\]|\[File:line\]", re.I)


def doc_month(path: str):
    m = FNAME_DT.search(os.path.basename(path))
    if not m:
        return None
    yy, mm = m.group(1)[:2], m.group(1)[2:4]
    if not ("01" <= mm <= "12"):
        return None
    return f"20{yy}-{mm}"


def doc_type(path: str):
    b = os.path.basename(path)
    for t in TYPES:
        if f"-{t}-" in b:
            return t
    return "?"


def doc_origin(path: str):
    """'external' = a PR review of code I didn't write; 'own' = my task work."""
    b = os.path.basename(path)
    # A V4 task doc (<TASKID>-<10-digit-dt>-TYPE) is always my own task work,
    # even if the slug mentions a PR number.
    if FNAME_DT.search(b):
        return "own"
    return "external" if EXTERNAL_RX.search(b) else "own"


def month_from_mtime(path: str):
    import time
    try:
        return time.strftime("%Y-%m", time.localtime(os.path.getmtime(path)))
    except OSError:
        return None


# AUD docs don't use severity tags — they list concerns under headings.
# Map heading -> severity bucket; count bullets/numbered items beneath.
AUD_SECTIONS = [
    (re.compile(r"critical issues?", re.I), "critical"),
    (re.compile(r"concerns?", re.I), "high"),
    (re.compile(r"code quality issues?|quality improvements?", re.I), "medium"),
]
HEADING = re.compile(r"^#{2,4}\s+(.*)$")
BULLET = re.compile(r"^\s*(?:[-*]\s+|\d+\.\s+)")


def _count_aud_sections(text: str):
    """Count real concern bullets under AUD finding-headings (skip ✅ / None)."""
    counts = defaultdict(int)
    cur = None
    for line in text.splitlines():
        h = HEADING.match(line)
        if h:
            cur = None
            for rx, sev in AUD_SECTIONS:
                if rx.search(h.group(1)):
                    cur = sev
                    break
            continue
        if cur and BULLET.match(line):
            body = BULLET.sub("", line).strip()
            if not body or body.startswith("✅") or re.match(r"(none|n/?a|no )", body, re.I):
                continue
            counts[cur] += 1
    return counts


def count_findings(text: str, dtype: str = "?"):
    """Return {severity: count} using the single most-populated style."""
    counts = defaultdict(int)
    for m in INLINE.finditer(text):
        counts[m.group(1).lower()] += 1
    if sum(counts.values()) == 0:
        for line in text.splitlines():
            if PLACEHOLDER.search(line):
                continue
            for e, sev in EMOJI.items():
                if e in line:
                    counts[sev] += 1
    if sum(counts.values()) == 0:
        for m in re.finditer(r"\b(P[0-3])\b", text):
            counts[PMAP[m.group(1)]] += 1
    # AUD fallback: section-based concern counting when no severity markers found
    if sum(counts.values()) == 0 and dtype == "AUD":
        counts = _count_aud_sections(text)
    return counts


def collect(roots, months):
    docs = {}  # basename -> path (dedup worktree/completed copies)
    skip = ("node_modules", "/templates/", "/.git/")
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            if any(s.strip("/") in dirpath.split(os.sep) for s in ("node_modules", ".git")):
                dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".git")]
            if "/templates/" in dirpath + "/":
                continue
            for fn in filenames:
                if not fn.endswith(".md"):
                    continue
                # match both V4 (-CRV-) and PR-review (CRV-pr-...) namings
                if not any(re.search(rf"(?:^|[-_]){t}[-_]", fn) for t in TYPES):
                    continue
                docs.setdefault(fn, os.path.join(dirpath, fn))

    rows = []
    for path in docs.values():
        origin = doc_origin(path)
        mon = doc_month(path) or (month_from_mtime(path) if origin == "external" else None)
        if not mon:
            continue
        try:
            text = open(path, errors="replace").read()
        except Exception:
            continue
        dt = doc_type(path)
        rows.append({"month": mon, "type": dt, "origin": origin,
                     "counts": count_findings(text, dt), "path": path})
    if months and rows:
        keep = sorted({r["month"] for r in rows})[-months:]
        rows = [r for r in rows if r["month"] in keep]
    return rows


def build_report(all_rows):
    """Two tracks, kept separate (an audit 'concern' != a code-review HIGH):
      * review track  = CRV + ARC, severity-tagged (crit/high/med/low)
      * audit track   = AUD, concern counts
    Only OWN work (code I wrote) feeds the tracks; external PR reviews of others'
    code are summarized separately so they don't skew the improvement signal.
    """
    external = [r for r in all_rows if r.get("origin") == "external"]
    rows = [r for r in all_rows if r.get("origin") != "external"]
    ext_summary = {"docs": len(external), "issues": sum(sum(r["counts"].values()) for r in external)}
    if not rows:
        rows = all_rows  # degenerate: everything external; still report something
    months = sorted({r["month"] for r in rows})
    rev = {m: {"reviews": 0, **{s: 0 for s in SEVS}} for m in months}   # CRV+ARC
    aud = {m: {"audits": 0, "issues": 0, "critical": 0} for m in months}
    per_type = {t: {"reviews": 0, **{s: 0 for s in SEVS}} for t in TYPES}
    for r in rows:
        t, c = r["type"], r["counts"]
        pt = per_type[t]
        pt["reviews"] += 1
        for s, v in c.items():
            pt[s] += v
        if t in ("CRV", "ARC"):
            rm = rev[r["month"]]
            rm["reviews"] += 1
            for s, v in c.items():
                rm[s] += v
        elif t == "AUD":
            am = aud[r["month"]]
            am["audits"] += 1
            am["issues"] += sum(c.values())
            am["critical"] += c.get("critical", 0)

    review = {}
    for m in months:
        rm = rev[m]
        n = rm["reviews"] or 1
        tot = sum(rm[s] for s in SEVS)
        hc = rm["critical"] + rm["high"]
        review[m] = {
            "reviews": rm["reviews"], "total": tot, "high_crit": hc,
            "per_review_total": round(tot / n, 2),
            "per_review_high_crit": round(hc / n, 2),
            **{s: rm[s] for s in SEVS},
        }
    audit = {}
    for m in months:
        am = aud[m]
        n = am["audits"] or 1
        audit[m] = {"audits": am["audits"], "issues": am["issues"],
                    "critical": am["critical"],
                    "per_audit": round(am["issues"] / n, 2)}
    return {
        "docs_parsed": len(rows),
        "own_docs": len(rows),
        "external_prs": ext_summary,
        "date_range": [months[0], months[-1]] if months else [],
        "review_track": review,
        "audit_track": audit,
        "by_type": per_type,
    }


def fmt(rep):
    R = rep
    p = print
    p(f"\n\033[1mCODE-QUALITY (REVIEW FINDINGS) TRENDS\033[0m")
    ext = R.get("external_prs", {})
    p(f"{R['own_docs']} own-work review docs · {R['date_range'][0]} → {R['date_range'][1]}")
    p(f"(excluded {ext.get('docs',0)} external PR-review docs / {ext.get('issues',0)} findings "
      f"— reviewing others' code, not counted toward your own quality trend)\n")

    p("\033[1m1. Code + arch review issues by month (CRV+ARC)\033[0m")
    p("   Theory: high+critical per review should fall as we build things right.")
    p(f"  {'Month':<9}{'Reviews':>8}{'Crit':>6}{'High':>6}{'Med':>6}{'Low':>6}"
      f"{'Total':>7}{'/rev':>7}{'HC/rev':>8}")
    for m, d in R["review_track"].items():
        p(f"  {m:<9}{d['reviews']:>8}{d['critical']:>6}{d['high']:>6}{d['medium']:>6}"
          f"{d['low']:>6}{d['total']:>7}{d['per_review_total']:>7.2f}{d['per_review_high_crit']:>8.2f}")
    p("   (HC/rev = high+critical per review — the key improvement line.)\n")

    p("\033[1m2. Audit concerns by month (AUD)\033[0m")
    p(f"  {'Month':<9}{'Audits':>8}{'Concerns':>10}{'Critical':>10}{'/audit':>9}")
    for m, d in R["audit_track"].items():
        p(f"  {m:<9}{d['audits']:>8}{d['issues']:>10}{d['critical']:>10}{d['per_audit']:>9.2f}")
    p()

    p("\033[1m3. By review type (all-time)\033[0m")
    p(f"  {'Type':<6}{'Docs':>6}{'Crit':>6}{'High':>6}{'Med':>6}{'Low':>6}{'/doc':>7}")
    names = {"CRV": "code", "AUD": "audit", "ARC": "arch", "FRV": "feature"}
    for t in TYPES:
        d = R["by_type"][t]
        rv = d["reviews"] or 1
        tot = sum(d[s] for s in SEVS)
        p(f"  {t:<6}{d['reviews']:>6}{d['critical']:>6}{d['high']:>6}{d['medium']:>6}"
          f"{d['low']:>6}{tot/rv:>7.2f}   ({names[t]})")
    p()


def render_html(rep):
    return HTML.replace("__DATA__", json.dumps(rep))


HTML = r"""<title>Code-Quality Findings Trends</title>
<style>
#qt{--bg:#0f1115;--panel:#171a21;--ink:#e8ecf2;--muted:#96a0b0;--line:#2a313d;
--crit:#e5686a;--high:#e0a44a;--med:#6ea8fe;--low:#43c59e;
font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--ink);
margin:0;padding:28px;min-height:100vh}
#qt *{box-sizing:border-box}#qt .wrap{max-width:1040px;margin:0 auto}
#qt h1{font-size:24px;margin:0 0 2px}#qt .sub{color:var(--muted);font-size:13px;margin-bottom:24px}
#qt h2{font-size:13px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin:30px 0 12px}
#qt .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px;overflow-x:auto}
#qt table{width:100%;border-collapse:collapse;font-size:13px;font-variant-numeric:tabular-nums}
#qt th,#qt td{text-align:right;padding:7px 9px;border-bottom:1px solid var(--line)}
#qt th:first-child,#qt td:first-child{text-align:left}
#qt th{color:var(--muted);font-size:11px;text-transform:uppercase}#qt tr:last-child td{border-bottom:none}
#qt svg{width:100%;height:auto}#qt .note{font-size:12px;color:var(--muted);margin-top:8px}
#qt .legend{display:flex;gap:14px;font-size:12px;color:var(--muted);margin-bottom:8px}
#qt .legend i{width:10px;height:10px;border-radius:3px;display:inline-block;margin-right:5px}
</style>
<div id="qt"><div class="wrap">
<h1>Code-Quality Findings Trends</h1><div class="sub" id="sub"></div>
<h2>High+Critical review issues per review (CRV+ARC — should trend down)</h2>
<div class="panel"><div class="legend"><span><i style="background:var(--crit)"></i>HC per review</span><span><i style="background:var(--muted)"></i>reviews (context)</span></div>
<svg id="chart" viewBox="0 0 980 300"></svg></div>
<h2>Code + arch review issues by month</h2><div class="panel"><table id="t1"></table></div>
<h2>Audit concerns by month (AUD)</h2><div class="panel"><table id="t3"></table></div>
<h2>By review type (all-time)</h2><div class="panel"><table id="t2"></table></div>
</div></div>
<script>
const R=__DATA__;const mo=m=>({'01':'Jan','02':'Feb','03':'Mar','04':'Apr','05':'May','06':'Jun','07':'Jul','08':'Aug','09':'Sep','10':'Oct','11':'Nov','12':'Dec'}[m.slice(5)]);
document.getElementById('sub').textContent=`${R.own_docs} own-work review docs · ${R.date_range[0]} → ${R.date_range[1]} · excludes ${(R.external_prs||{}).docs||0} external PR reviews of others' code`;
const RT=R.review_track,AT=R.audit_track,M=Object.keys(RT);
// chart: HC/rev line + reviews bars
(function(){const svg=document.getElementById('chart'),W=980,H=300,L=44,Rp=44,T=16,B=30,pw=W-L-Rp,ph=H-T-B;
let hcmax=Math.max(...M.map(m=>RT[m].per_review_high_crit),0.5)*1.15;
let rvmax=Math.max(...M.map(m=>RT[m].reviews),1)*1.15;
const n=M.length,x=i=>L+pw*(i+.5)/n,yl=v=>T+ph*(1-v/hcmax),yb=v=>T+ph*(1-v/rvmax),bw=pw/n*0.5;
let g='';for(let t=0;t<=4;t++){let gv=hcmax*t/4,yy=yl(gv);g+=`<line x1="${L}" y1="${yy}" x2="${W-Rp}" y2="${yy}" stroke="#2a313d"/><text x="${L-6}" y="${yy+4}" fill="#96a0b0" font-size="11" text-anchor="end">${gv.toFixed(1)}</text>`}
M.forEach((m,i)=>{let rv=RT[m].reviews;g+=`<rect x="${x(i)-bw/2}" y="${yb(rv)}" width="${bw}" height="${T+ph-yb(rv)}" rx="3" fill="#2f3947"/>`;
g+=`<text x="${x(i)}" y="${H-10}" fill="#96a0b0" font-size="11" text-anchor="middle">${mo(m)}</text>`;
g+=`<text x="${x(i)}" y="${yb(rv)-4}" fill="#5b6572" font-size="10" text-anchor="middle">${rv}</text>`});
let pts=M.map((m,i)=>[x(i),yl(RT[m].per_review_high_crit)]);
g+=`<path d="${pts.map((p,i)=>(i?'L':'M')+p[0].toFixed(1)+','+p[1].toFixed(1)).join(' ')}" fill="none" stroke="#e5686a" stroke-width="2.5"/>`;
pts.forEach((p,i)=>{g+=`<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="3.6" fill="#e5686a"/>`;g+=`<text x="${p[0]}" y="${p[1]-8}" fill="#e5686a" font-size="10" text-anchor="middle">${RT[M[i]].per_review_high_crit}</text>`});
svg.innerHTML=g})();
// t1 review track
document.getElementById('t1').innerHTML='<thead><tr><th>Month</th><th>Reviews</th><th>Crit</th><th>High</th><th>Med</th><th>Low</th><th>Total</th><th>/review</th><th>HC/review</th></tr></thead><tbody>'+
M.map(m=>{let d=RT[m];return `<tr><td>${mo(m)} ${m.slice(0,4)}</td><td>${d.reviews}</td><td style="color:var(--crit)">${d.critical}</td><td style="color:var(--high)">${d.high}</td><td style="color:var(--med)">${d.medium}</td><td style="color:var(--low)">${d.low}</td><td>${d.total}</td><td>${d.per_review_total}</td><td>${d.per_review_high_crit}</td></tr>`}).join('')+'</tbody>';
// t3 audit track
document.getElementById('t3').innerHTML='<thead><tr><th>Month</th><th>Audits</th><th>Concerns</th><th>Critical</th><th>Per audit</th></tr></thead><tbody>'+
M.map(m=>{let d=AT[m];return `<tr><td>${mo(m)} ${m.slice(0,4)}</td><td>${d.audits}</td><td>${d.issues}</td><td style="color:var(--crit)">${d.critical}</td><td>${d.per_audit}</td></tr>`}).join('')+'</tbody>';
// t2
const nm={CRV:'code review',AUD:'audit',ARC:'arch review',FRV:'feature review'};
document.getElementById('t2').innerHTML='<thead><tr><th>Type</th><th>Reviews</th><th>Crit</th><th>High</th><th>Med</th><th>Low</th><th>/review</th></tr></thead><tbody>'+
Object.keys(R.by_type).map(t=>{let d=R.by_type[t],tot=d.critical+d.high+d.medium+d.low,rv=d.reviews||1;return `<tr><td>${t} <span style="color:var(--muted)">${nm[t]}</span></td><td>${d.reviews}</td><td style="color:var(--crit)">${d.critical}</td><td style="color:var(--high)">${d.high}</td><td style="color:var(--med)">${d.medium}</td><td style="color:var(--low)">${d.low}</td><td>${(tot/rv).toFixed(2)}</td></tr>`}).join('')+'</tbody>';
</script>"""


def main():
    ap = argparse.ArgumentParser(description="Review-findings quality trends.")
    ap.add_argument("--root", action="append", default=None,
                    help="project root(s) to scan (default ~/projects)")
    ap.add_argument("--months", type=int, default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--html", metavar="OUT")
    args = ap.parse_args()

    roots = args.root or [str(Path.home() / "projects")]
    roots = [str(Path(r).expanduser()) for r in roots]
    rows = collect(roots, args.months)
    if not rows:
        print("error: no dated review docs found under: " + ", ".join(roots), file=sys.stderr)
        sys.exit(1)
    rep = build_report(rows)

    if args.html:
        Path(args.html).write_text(render_html(rep))
        print(f"wrote {args.html}")
        return
    if args.json:
        print(json.dumps(rep, indent=2))
        return
    fmt(rep)


if __name__ == "__main__":
    main()
