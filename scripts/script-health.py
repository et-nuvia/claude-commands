#!/usr/bin/env python3
"""
script-health.py — find ~/.claude/scripts that error and force manual fallback.

Goal: identify scripts that throw real errors (not intentional control-flow
stops) and, right after, make the LLM do the work by hand with raw primitives
(cat/grep/sed/awk/find/head/tail/jq/python3 -c/curl). Those are the scripts to
fix so the command tooling stays trustworthy.

Data source: Claude Code session transcripts (~/.claude/projects/*/*.jsonl),
which record every Bash tool_use (command) and its tool_result (is_error +
output), matchable by tool_use_id.

Classification of a script invocation's result:
  controlled_stop  valid JSON with status blocked/review_failed/needs_input +
                   next_action — the script gating on purpose (NOT a bug).
  script_bug       Traceback / command not found / No such file / Permission
                   denied / unbound variable / syntax error / ModuleNotFound.
  parse_fallback   inline `python3 -c` / `jq` run against a script's output that
                   itself errored — the LLM hand-parsing because the script's
                   output wasn't cleanly consumable.
  other_error      is_error true but none of the above signatures.
  ok               success.

manual_fallback: within a session, when a script invocation is a script_bug /
other_error, the next few Bash commands are raw primitives → counted against
that script (the concrete "LLM did it manually" evidence).

Usage:
  script-health.py                 # human report, all transcripts
  script-health.py --days 30       # only transcripts modified in last N days
  script-health.py --json
  script-health.py --html OUT.html
  script-health.py --script NAME   # deep-dive one script (all error samples)
  script-health.py --transcripts DIR
"""
from __future__ import annotations
import argparse, json, os, re, sys, time
from collections import defaultdict
from pathlib import Path

SCRIPT_RX = re.compile(r"(?:\.claude/scripts/|scripts/)([A-Za-z0-9_.-]+\.(?:sh|py))")
BUG_RX = re.compile(
    r"Traceback \(most recent call last\)|command not found|No such file or directory"
    r"|Permission denied|unbound variable|syntax error|ModuleNotFoundError"
    r"|: line \d+:|/bin/sh:|/bin/bash:|cannot execute", re.I)
# A structured response carrying BOTH status and next_action is the script
# signaling on purpose (TOON/JSON contract) — not a crash, even at exit 1.
CONTROLLED_RX = re.compile(r'"?next_action"?\s*[:=]', re.I)
# Permission prompts the user declined — not a script failure at all.
REJECTED_RX = re.compile(r"doesn't want to proceed|tool use was rejected|User rejected", re.I)
# Environmental (git worktree contention, transient) — causes manual work but
# isn't a script bug to fix in the script's own logic.
ENV_RX = re.compile(r"index\.lock.*File exists|Another git process|did not match any files"
                    r"|Connection refused|Could not resolve host|no space left", re.I)
INLINE_PARSE = re.compile(r"python3?\s+-c|(?:^|\|)\s*jq\b")
# manual primitives (first meaningful token) used as fallback
MANUAL_FIRST = {"cat", "grep", "egrep", "rg", "sed", "awk", "find", "head",
                "tail", "ls", "less", "cut", "sort", "uniq", "wc", "curl", "wget"}


def result_text(c):
    txt = c.get("content")
    if isinstance(txt, list):
        txt = " ".join(x.get("text", "") for x in txt if isinstance(x, dict))
    return str(txt or "")


def classify(text, is_error):
    if REJECTED_RX.search(text):
        return "rejected"          # user declined a permission prompt
    if BUG_RX.search(text):
        return "script_bug"        # traceback / not-found / syntax error
    if ENV_RX.search(text):
        return "environmental"     # git lock, network, disk — transient
    if CONTROLLED_RX.search(text):
        return "controlled_stop"   # structured status+next_action gate
    if is_error:
        return "other_error"
    return "ok"


def first_token(cmd):
    # strip leading 'cd X &&' / env assignments, take first real token
    parts = re.split(r"&&|\|\||\||;", cmd)
    for seg in parts:
        seg = seg.strip()
        seg = re.sub(r"^(cd\s+\S+\s*)", "", seg).strip()
        seg = re.sub(r"^([A-Za-z_][A-Za-z0-9_]*=\S+\s+)+", "", seg).strip()
        if seg:
            return seg.split()[0] if seg.split() else ""
    return ""


def is_manual(cmd):
    if SCRIPT_RX.search(cmd):
        return False
    if INLINE_PARSE.search(cmd):
        return True
    return first_token(cmd) in MANUAL_FIRST


def scan(transcript_dir, since_ts):
    files = []
    for p in Path(transcript_dir).glob("*/*.jsonl"):
        try:
            if since_ts and p.stat().st_mtime < since_ts:
                continue
        except OSError:
            continue
        files.append(p)

    stats = defaultdict(lambda: {"calls": 0, "ok": 0, "controlled_stop": 0,
                                 "script_bug": 0, "parse_fallback": 0,
                                 "other_error": 0, "environmental": 0,
                                 "rejected": 0, "manual_fallback": 0,
                                 "samples": []})
    files_scanned = 0
    for f in files:
        files_scanned += 1
        # ordered bash events in this session + pending id->result resolution
        events = []           # {name, id, manual}
        pending = {}          # tool_use_id -> event index
        try:
            fh = open(f, errors="replace")
        except OSError:
            continue
        for line in fh:
            if '"tool_use"' not in line and '"tool_result"' not in line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            cont = (r.get("message") or {}).get("content")
            if not isinstance(cont, list):
                continue
            for c in cont:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use" and c.get("name") == "Bash":
                    cmd = (c.get("input") or {}).get("command", "") or ""
                    m = SCRIPT_RX.search(cmd)
                    if m:
                        ev = {"kind": "script", "name": m.group(1), "cls": None,
                              "inline_parse": bool(INLINE_PARSE.search(cmd))}
                        events.append(ev)
                        pending[c.get("id")] = len(events) - 1
                    elif is_manual(cmd):
                        events.append({"kind": "manual", "cmd": cmd[:80]})
                    else:
                        events.append({"kind": "other"})
                elif c.get("type") == "tool_result":
                    idx = pending.pop(c.get("tool_use_id"), None)
                    if idx is not None:
                        txt = result_text(c)
                        cls = classify(txt, bool(c.get("is_error")))
                        # inline python/jq against script output that errored
                        if cls in ("script_bug", "other_error") and events[idx]["inline_parse"]:
                            cls = "parse_fallback"
                        events[idx]["cls"] = cls
                        events[idx]["err"] = txt[:200].replace("\n", " ") if cls not in ("ok", "controlled_stop", "rejected") else ""
        # aggregate + detect manual fallback after failures
        for i, ev in enumerate(events):
            if ev.get("kind") != "script":
                continue
            name = ev["name"]
            s = stats[name]
            s["calls"] += 1
            cls = ev.get("cls") or "ok"
            s[cls] += 1
            if cls in ("script_bug", "other_error", "parse_fallback"):
                # look ahead up to 3 bash commands for manual primitives
                for nxt in events[i + 1:i + 4]:
                    if nxt.get("kind") == "manual":
                        s["manual_fallback"] += 1
                        break
                if ev.get("err") and len(s["samples"]) < 12:
                    s["samples"].append({"cls": cls, "msg": ev["err"]})
    return stats, files_scanned


def build_report(stats, files_scanned):
    rows = []
    for name, s in stats.items():
        fails = s["script_bug"] + s["other_error"] + s["parse_fallback"]
        rows.append({
            "script": name, "calls": s["calls"],
            "controlled_stop": s["controlled_stop"], "rejected": s["rejected"],
            "environmental": s["environmental"],
            "script_bug": s["script_bug"], "parse_fallback": s["parse_fallback"],
            "other_error": s["other_error"], "real_failures": fails,
            "fail_rate": round(100 * fails / s["calls"], 1) if s["calls"] else 0,
            "manual_fallback": s["manual_fallback"],
            "samples": s["samples"],
        })
    rows.sort(key=lambda r: (r["real_failures"], r["manual_fallback"]), reverse=True)
    return {"files_scanned": files_scanned,
            "total_script_calls": sum(r["calls"] for r in rows),
            "total_real_failures": sum(r["real_failures"] for r in rows),
            "total_manual_fallback": sum(r["manual_fallback"] for r in rows),
            "scripts": rows}


def fmt(rep, focus=None):
    p = print
    p(f"\n\033[1mSCRIPT HEALTH — errors & manual fallback\033[0m")
    p(f"{rep['files_scanned']} transcripts · {rep['total_script_calls']} script calls · "
      f"{rep['total_real_failures']} real failures · {rep['total_manual_fallback']} manual fallbacks\n")
    if focus:
        r = next((x for x in rep["scripts"] if x["script"] == focus), None)
        if not r:
            p(f"no data for {focus}"); return
        p(f"\033[1m{focus}\033[0m  calls={r['calls']} failures={r['real_failures']} "
          f"({r['fail_rate']}%) manual_fallback={r['manual_fallback']}")
        for s in r["samples"]:
            p(f"  [{s['cls']}] {s['msg']}")
        return
    p(f"  {'Script':<26}{'Calls':>6}{'Bug':>5}{'Parse':>6}{'Other':>6}{'Fail%':>7}{'CtrlStop':>9}{'Manual→':>8}")
    for r in rep["scripts"]:
        if r["real_failures"] == 0 and r["manual_fallback"] == 0:
            continue
        p(f"  {r['script']:<26}{r['calls']:>6}{r['script_bug']:>5}{r['parse_fallback']:>6}"
          f"{r['other_error']:>6}{r['fail_rate']:>6}%{r['controlled_stop']:>9}{r['manual_fallback']:>8}")
    p("\n  Bug=traceback/not-found  Parse=inline python/jq on script output failed")
    p("  CtrlStop=intentional gate (not a bug)  Manual→=raw primitives run right after a failure\n")
    p("  Top offenders — sample errors (run --script NAME for full detail):")
    for r in rep["scripts"][:5]:
        if r["real_failures"] == 0:
            continue
        p(f"\n  \033[1m{r['script']}\033[0m ({r['real_failures']} failures, {r['manual_fallback']} manual):")
        for s in r["samples"][:3]:
            p(f"    [{s['cls']}] {s['msg'][:150]}")
    p()


def render_html(rep):
    return HTML.replace("__DATA__", json.dumps(rep))


HTML = r"""<title>Script Health — Errors & Manual Fallback</title>
<style>
#sh{--bg:#0f1115;--panel:#171a21;--ink:#e8ecf2;--muted:#96a0b0;--line:#2a313d;
--bad:#e5686a;--warn:#e0a44a;--ok:#43c59e;font-family:-apple-system,Segoe UI,Roboto,sans-serif;
background:var(--bg);color:var(--ink);margin:0;padding:28px;min-height:100vh}
#sh *{box-sizing:border-box}#sh .wrap{max-width:1080px;margin:0 auto}
#sh h1{font-size:24px;margin:0 0 2px}#sh .sub{color:var(--muted);font-size:13px;margin-bottom:20px}
#sh .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:24px}
#sh .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
#sh .card .k{font-size:11px;color:var(--muted);text-transform:uppercase}#sh .card .v{font-size:26px;font-weight:650;margin-top:4px}
#sh h2{font-size:13px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin:26px 0 12px}
#sh .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px;overflow-x:auto}
#sh table{width:100%;border-collapse:collapse;font-size:13px;font-variant-numeric:tabular-nums}
#sh th,#sh td{text-align:right;padding:7px 9px;border-bottom:1px solid var(--line)}
#sh th:first-child,#sh td:first-child{text-align:left}#sh th{color:var(--muted);font-size:11px;text-transform:uppercase}
#sh tr:last-child td{border-bottom:none}#sh .mono{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:var(--muted)}
#sh details{margin:6px 0;border-bottom:1px solid var(--line);padding-bottom:6px}
#sh summary{cursor:pointer;font-size:13px}#sh .err{font-family:ui-monospace,Menlo,monospace;font-size:11.5px;color:#d9a0a0;margin:4px 0 4px 14px}
#sh .tag{font-size:10px;padding:1px 6px;border-radius:10px;background:#2a313d;color:var(--warn);margin-right:6px}
</style>
<div id="sh"><div class="wrap">
<h1>Script Health — Errors &amp; Manual Fallback</h1><div class="sub" id="sub"></div>
<div class="cards" id="cards"></div>
<h2>Scripts by real failures</h2><div class="panel"><table id="t1"></table>
<div class="mono" style="margin-top:8px">Bug = traceback / not-found · Parse = inline python/jq on script output failed · CtrlStop = intentional gate (not a bug) · Manual→ = raw primitives run right after a failure</div></div>
<h2>Sample errors (top offenders)</h2><div class="panel" id="samples"></div>
</div></div>
<script>
const R=__DATA__;
document.getElementById('sub').textContent=`${R.files_scanned} transcripts · ${R.total_script_calls} script calls`;
const card=(k,v)=>`<div class="card"><div class="k">${k}</div><div class="v">${v}</div></div>`;
document.getElementById('cards').innerHTML=
 card('Script calls',R.total_script_calls)+card('Real failures',R.total_real_failures)+
 card('Manual fallbacks',R.total_manual_fallback)+card('Scripts w/ failures',R.scripts.filter(s=>s.real_failures>0).length);
const rows=R.scripts.filter(s=>s.real_failures>0||s.manual_fallback>0);
document.getElementById('t1').innerHTML='<thead><tr><th>Script</th><th>Calls</th><th>Bug</th><th>Parse</th><th>Other</th><th>Fail%</th><th>CtrlStop</th><th>Manual→</th></tr></thead><tbody>'+
rows.map(r=>`<tr><td class="mono">${r.script}</td><td>${r.calls}</td><td style="color:var(--bad)">${r.script_bug||''}</td><td style="color:var(--warn)">${r.parse_fallback||''}</td><td>${r.other_error||''}</td><td style="color:${r.fail_rate>15?'var(--bad)':'var(--ink)'}">${r.fail_rate}%</td><td class="mono">${r.controlled_stop||''}</td><td style="color:var(--warn)">${r.manual_fallback||''}</td></tr>`).join('')+'</tbody>';
document.getElementById('samples').innerHTML=R.scripts.filter(s=>s.samples.length).slice(0,10).map(r=>
 `<details><summary><b>${r.script}</b> — ${r.real_failures} failures, ${r.manual_fallback} manual fallback</summary>`+
 r.samples.map(s=>`<div class="err"><span class="tag">${s.cls}</span>${s.msg.replace(/</g,'&lt;')}</div>`).join('')+'</details>').join('');
</script>"""


def main():
    ap = argparse.ArgumentParser(description="Script error / manual-fallback health from transcripts.")
    ap.add_argument("--transcripts", default=str(Path.home() / ".claude" / "projects"))
    ap.add_argument("--days", type=int, default=None, help="only transcripts modified in last N days")
    ap.add_argument("--script", help="deep-dive one script name")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--html", metavar="OUT")
    args = ap.parse_args()

    tdir = Path(args.transcripts).expanduser()
    if not tdir.is_dir():
        print(f"error: transcripts dir not found: {tdir}", file=sys.stderr)
        sys.exit(1)
    since = (time.time() - args.days * 86400) if args.days else None
    stats, n = scan(tdir, since)
    if n == 0:
        print("error: no transcripts matched", file=sys.stderr)
        sys.exit(1)
    rep = build_report(stats, n)

    if args.html:
        Path(args.html).write_text(render_html(rep))
        print(f"wrote {args.html}")
        return
    if args.json:
        print(json.dumps(rep, indent=2))
        return
    fmt(rep, focus=args.script)


if __name__ == "__main__":
    main()
