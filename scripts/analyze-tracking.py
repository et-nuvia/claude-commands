#!/usr/bin/env python3
"""Analyze ~/.claude/tracking/*.json to surface command-usage patterns
and emit an interactive HTML report.

Usage:
    analyze-tracking.py                          # writes default outputs
    analyze-tracking.py --gap-minutes 90         # session boundary in minutes
    analyze-tracking.py --out /path/to/page.html
    analyze-tracking.py --json /path/to/data.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
DEFAULT_TRACKING = HOME / ".claude" / "tracking"
DEFAULT_COMMANDS = HOME / ".claude" / "commands"
DEFAULT_OUT_HTML = HOME / ".claude" / "tracking" / "analysis.html"
DEFAULT_OUT_JSON = HOME / ".claude" / "tracking" / "analysis.json"
DEFAULT_SYNTH_JSON = HOME / ".claude" / "tracking" / "workflows-synthesized.json"
DEFAULT_DETAILS_JSON = HOME / ".claude" / "tracking" / "command-details.json"


def parse_ts(s: str):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        # tracking uses '-0700' (no colon); fromisoformat handles it on 3.11+,
        # but normalize just in case.
        m = re.match(r"(.+)([+-]\d{2})(\d{2})$", s)
        if m:
            return datetime.fromisoformat(f"{m.group(1)}{m.group(2)}:{m.group(3)}")
        return None


def load_events(tracking_dir: Path):
    events = []
    for f in sorted(tracking_dir.glob("*.json")):
        try:
            data = json.loads(f.read_text())
        except Exception as e:
            print(f"warn: failed to parse {f}: {e}", file=sys.stderr)
            continue
        if not isinstance(data, list):
            continue
        for e in data:
            if not isinstance(e, dict):
                continue
            cmd = e.get("command")
            if not cmd:
                continue
            ts = parse_ts(e.get("timestamp"))
            if ts is None:
                continue
            events.append({
                "command": cmd,
                "project": (e.get("folder") or e.get("project") or "?").strip().strip('"'),
                "status": e.get("status") or "?",
                "ts": ts,
                "duration_seconds": e.get("duration_seconds"),
                "cost_estimated": e.get("cost_estimated"),
                "session_id": e.get("session_id"),
            })
    events.sort(key=lambda x: x["ts"])
    return events


def load_command_descriptions(commands_dir: Path):
    descs = {}
    for f in commands_dir.glob("*.md"):
        try:
            text = f.read_text(errors="replace")
        except Exception:
            continue
        name = f.stem
        desc = ""
        m = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
        if m:
            front = m.group(1)
            nm = re.search(r"^name:\s*(.+)$", front, re.MULTILINE)
            if nm:
                name = nm.group(1).strip()
            dm = re.search(r"^description:\s*(.+)$", front, re.MULTILINE)
            if dm:
                desc = dm.group(1).strip()
        descs[name] = desc
    return descs


def build_sessions(events, gap_minutes: int):
    """A 'session' = consecutive command starts within `gap_minutes` of each
    other in the same project. We only count one event per (command, session)
    using the START event (or first event for that command).
    """
    gap = timedelta(minutes=gap_minutes)
    # Keep only 'started' events (or fallback: first occurrence per command).
    starts = [e for e in events if e["status"] == "started"]
    if not starts:
        starts = events

    sessions = []
    cur = None
    for e in starts:
        if cur is None:
            cur = {"project": e["project"], "events": [e], "start": e["ts"], "end": e["ts"]}
            continue
        same_proj = e["project"] == cur["project"]
        in_window = (e["ts"] - cur["end"]) <= gap
        if same_proj and in_window:
            cur["events"].append(e)
            cur["end"] = e["ts"]
        else:
            sessions.append(cur)
            cur = {"project": e["project"], "events": [e], "start": e["ts"], "end": e["ts"]}
    if cur:
        sessions.append(cur)
    return sessions


def compute_workflows(sessions, min_len=2, max_len=5, top_n=40):
    """N-gram of command sequences within sessions. Drops repeated consecutive
    identical commands so e.g. task-continue x10 doesn't dominate."""
    seq_counter = Counter()
    seq_examples = defaultdict(list)
    for s in sessions:
        cmds = []
        for ev in s["events"]:
            if cmds and cmds[-1] == ev["command"]:
                continue
            cmds.append(ev["command"])
        for n in range(min_len, max_len + 1):
            for i in range(0, len(cmds) - n + 1):
                gram = tuple(cmds[i : i + n])
                seq_counter[gram] += 1
                if len(seq_examples[gram]) < 3:
                    seq_examples[gram].append({
                        "project": s["project"],
                        "date": s["start"].strftime("%Y-%m-%d"),
                    })

    workflows = []
    for gram, count in seq_counter.most_common(top_n):
        if count < 2:
            break
        workflows.append({
            "sequence": list(gram),
            "length": len(gram),
            "count": count,
            "examples": seq_examples[gram],
        })
    return workflows


def compute_command_stats(events):
    stats = defaultdict(lambda: {"count": 0, "total_duration": 0, "total_cost": 0.0, "projects": Counter()})
    for e in events:
        if e["status"] not in ("completed", "started"):
            continue
        s = stats[e["command"]]
        if e["status"] == "started":
            s["count"] += 1
            s["projects"][e["project"]] += 1
        if e["status"] == "completed":
            if isinstance(e.get("duration_seconds"), (int, float)):
                s["total_duration"] += e["duration_seconds"]
            if isinstance(e.get("cost_estimated"), (int, float)):
                s["total_cost"] += e["cost_estimated"]
    out = []
    for cmd, s in stats.items():
        out.append({
            "command": cmd,
            "count": s["count"],
            "avg_duration_sec": (s["total_duration"] / s["count"]) if s["count"] else 0,
            "total_cost": round(s["total_cost"], 2),
            "top_projects": s["projects"].most_common(5),
        })
    out.sort(key=lambda x: x["count"], reverse=True)
    return out


HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Claude Code — Command Usage Analysis</title>
<style>
  :root { --bg:#0f1419; --fg:#e6e6e6; --muted:#888; --accent:#7aa2f7; --card:#1a1f2e; --border:#2a3142; }
  body { background:var(--bg); color:var(--fg); font-family:-apple-system,BlinkMacSystemFont,sans-serif; margin:0; padding:24px; }
  h1 { margin:0 0 8px; font-size:22px; }
  .subtitle { color:var(--muted); margin-bottom:24px; font-size:13px; }
  .tabs { border-bottom:1px solid var(--border); margin-bottom:20px; }
  .tab { background:none; border:none; color:var(--muted); padding:10px 16px; cursor:pointer; font-size:14px; }
  .tab.active { color:var(--accent); border-bottom:2px solid var(--accent); }
  .view { display:none; }
  .view.active { display:block; }
  .filter { margin-bottom:16px; }
  .filter input { background:var(--card); border:1px solid var(--border); color:var(--fg); padding:8px 12px; border-radius:6px; width:280px; font-size:13px; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:16px; margin-bottom:12px; }
  .card-head { display:flex; justify-content:space-between; align-items:baseline; gap:12px; }
  .cmd-name { font-family:ui-monospace,monospace; color:var(--accent); font-size:15px; }
  .count { color:var(--muted); font-size:12px; }
  .desc { color:#bbb; margin-top:6px; font-size:13px; line-height:1.5; }
  .meta { color:var(--muted); margin-top:8px; font-size:12px; }
  .seq { font-family:ui-monospace,monospace; font-size:13px; }
  .seq .step { display:inline-block; background:#243047; padding:3px 8px; border-radius:4px; margin:2px; color:#aac; }
  .seq .arrow { color:var(--muted); margin:0 4px; }
  .examples { color:var(--muted); font-size:11px; margin-top:8px; }
  .editable { color:#888; font-style:italic; cursor:text; min-height:16px; outline:none; }
  .editable:focus { color:#fff; background:#1f2538; padding:2px 4px; border-radius:3px; font-style:normal; }
  .editable.has-content { color:#ddd; font-style:normal; }
  .pill { display:inline-block; background:#243047; color:#aac; padding:2px 8px; border-radius:10px; font-size:11px; margin-right:6px; }
  .actions { margin-bottom:14px; }
  .actions button { background:var(--accent); border:none; color:#0c1320; padding:6px 12px; border-radius:6px; cursor:pointer; font-size:12px; margin-right:8px; }
</style>
</head>
<body>
<h1>Claude Code — Command Usage</h1>
<div class="subtitle">__GENERATED__ &middot; __TOTAL_EVENTS__ events &middot; __TOTAL_SESSIONS__ sessions (gap=__GAP__ min)</div>

<div class="tabs">
  <button class="tab active" data-view="synth">Curated workflows (__N_SYNTH__)</button>
  <button class="tab" data-view="commands">Commands (__N_COMMANDS__)</button>
  <button class="tab" data-view="workflows">Raw n-grams (__N_WORKFLOWS__)</button>
</div>

<div class="actions">
  <button onclick="exportNotes()">Export notes JSON</button>
  <button onclick="document.getElementById('import').click()">Import notes</button>
  <input type="file" id="import" style="display:none" onchange="importNotes(event)" accept="application/json"/>
  <span class="count" id="save-status"></span>
</div>

<div id="view-synth" class="view active">
  <div class="filter"><input id="synth-filter" placeholder="filter curated workflows..." oninput="renderSynth()"/></div>
  <div id="synth-list"></div>
</div>

<div id="view-commands" class="view">
  <div class="filter"><input id="cmd-filter" placeholder="filter commands..." oninput="renderCommands()"/></div>
  <div id="commands-list"></div>
</div>

<div id="view-workflows" class="view">
  <div class="filter"><input id="wf-filter" placeholder="filter by command in workflow..." oninput="renderWorkflows()"/></div>
  <div id="workflows-list"></div>
</div>

<script>
const DATA = __DATA__;
const STORAGE_KEY = "claude-tracking-notes";

function loadNotes() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}"); } catch { return {}; }
}
function saveNotes(notes) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
  const el = document.getElementById("save-status");
  el.textContent = "saved " + new Date().toLocaleTimeString();
  setTimeout(() => el.textContent = "", 2000);
}

const notes = loadNotes();

function fmtDuration(s) {
  if (!s) return "—";
  if (s < 60) return s.toFixed(0) + "s";
  if (s < 3600) return (s/60).toFixed(1) + "m";
  return (s/3600).toFixed(1) + "h";
}

function escapeHtml(s) {
  return (s||"").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
}

function renderCommands() {
  const q = document.getElementById("cmd-filter").value.toLowerCase();
  const root = document.getElementById("commands-list");
  const items = DATA.commands.filter(c => !q || c.command.toLowerCase().includes(q));
  root.innerHTML = items.map(c => {
    const oneline = escapeHtml(DATA.descriptions[c.command] || "");
    const det = (DATA.details && DATA.details[c.command]) || null;
    const note = notes["cmd:"+c.command] || "";
    const projects = "";
    let detailHtml = "";
    if (det) {
      const section = (label, val) => val ? `
        <div style="margin-top:12px;">
          <div style="color:#7aa2f7;font-size:11px;font-weight:600;letter-spacing:0.5px;text-transform:uppercase;margin-bottom:4px;">${label}</div>
          <div style="color:#ccc;font-size:13px;line-height:1.55;">${escapeHtml(val)}</div>
        </div>` : "";
      let phasesHtml = "";
      if (det.phases && det.phases.length) {
        const items = det.phases.map(p => `
          <div style="margin:8px 0 8px 0;padding:8px 12px;background:#1f2538;border-left:3px solid #7aa2f7;border-radius:0 4px 4px 0;">
            <div style="font-family:ui-monospace,monospace;color:#aac;font-size:12px;font-weight:600;margin-bottom:3px;">${escapeHtml(p.name || "")}</div>
            <div style="color:#bbb;font-size:12px;line-height:1.55;">${escapeHtml(p.detail || "")}</div>
          </div>`).join("");
        phasesHtml = `
          <div style="margin-top:14px;">
            <div style="color:#7aa2f7;font-size:11px;font-weight:600;letter-spacing:0.5px;text-transform:uppercase;margin-bottom:6px;">How it works (${det.phases.length} phases) — implementation breakdown</div>
            <details><summary style="cursor:pointer;color:#888;font-size:12px;margin-bottom:4px;">expand phases</summary>${items}</details>
          </div>`;
      }
      detailHtml = `
        <div style="margin-top:14px;color:#ddd;font-size:14px;line-height:1.6;">${escapeHtml(det.what || "")}</div>
        ${section("Inputs", det.inputs)}
        ${section("Produces", det.produces)}
        ${section("When to use", det.when)}
        ${section("Integrates with", det.integrates_with)}
        ${section("Example", det.example)}
        ${phasesHtml}
        ${section("Notes", det.notes)}`;
    } else {
      detailHtml = `<div class="desc">${oneline || '<em style="color:#666">no detailed description — add one in tracking/command-details.json</em>'}</div>`;
    }
    return `
      <div class="card">
        <div class="card-head">
          <div class="cmd-name">/${escapeHtml(c.command)}</div>
          <div class="count">${c.count} runs</div>
        </div>
        ${oneline && det ? `<div class="meta" style="color:#888;font-size:12px;">${oneline}</div>` : ""}
        ${detailHtml}
        <div class="meta">Your notes: <span class="editable ${note?'has-content':''}" contenteditable="true" data-key="cmd:${c.command}">${escapeHtml(note) || "click to add your own notes"}</span></div>
      </div>`;
  }).join("");
  attachEditableHandlers();
}

function renderWorkflows() {
  const q = document.getElementById("wf-filter").value.toLowerCase();
  const root = document.getElementById("workflows-list");
  const items = DATA.workflows.filter(w => !q || w.sequence.some(s => s.toLowerCase().includes(q)));
  root.innerHTML = items.map((w, i) => {
    const key = "wf:" + w.sequence.join(">");
    const note = notes[key] || "";
    const seq = w.sequence.map(s =>
      `<span class="step">/${escapeHtml(s)}</span>`
    ).join('<span class="arrow">→</span>');
    const examples = "";
    return `
      <div class="card">
        <div class="card-head">
          <div class="seq">${seq}</div>
          <div class="count">${w.count} occurrences &middot; ${w.length} steps</div>
        </div>
        <div class="examples">${examples}</div>
        <div class="meta">Workflow notes: <span class="editable ${note?'has-content':''}" contenteditable="true" data-key="${key}">${escapeHtml(note) || "click to describe when/why you use this workflow"}</span></div>
      </div>`;
  }).join("");
  attachEditableHandlers();
}

function attachEditableHandlers() {
  document.querySelectorAll(".editable").forEach(el => {
    el.addEventListener("blur", () => {
      const key = el.dataset.key;
      const val = el.textContent.trim();
      if (val && val !== "click to add your own notes" && val !== "click to describe when/why you use this workflow") {
        notes[key] = val;
        el.classList.add("has-content");
      } else {
        delete notes[key];
        el.classList.remove("has-content");
      }
      saveNotes(notes);
    });
    el.addEventListener("focus", () => {
      if (!notes[el.dataset.key]) el.textContent = "";
    });
  });
}

function exportNotes() {
  const blob = new Blob([JSON.stringify(notes, null, 2)], {type:"application/json"});
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = "claude-tracking-notes.json"; a.click();
  URL.revokeObjectURL(url);
}

function importNotes(ev) {
  const file = ev.target.files[0]; if (!file) return;
  const r = new FileReader();
  r.onload = () => {
    try {
      const obj = JSON.parse(r.result);
      Object.assign(notes, obj);
      saveNotes(notes);
      renderCommands(); renderWorkflows();
    } catch (e) { alert("invalid JSON"); }
  };
  r.readAsText(file);
}

document.querySelectorAll(".tab").forEach(b => {
  b.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach(t => t.classList.remove("active"));
    document.querySelectorAll(".view").forEach(v => v.classList.remove("active"));
    b.classList.add("active");
    document.getElementById("view-"+b.dataset.view).classList.add("active");
  });
});

function renderSynth() {
  const q = document.getElementById("synth-filter").value.toLowerCase();
  const root = document.getElementById("synth-list");
  const items = (DATA.synthesized || []).filter(w =>
    !q || w.name.toLowerCase().includes(q) || w.steps.some(s => s.toLowerCase().includes(q))
  );
  if (!items.length) {
    root.innerHTML = '<div class="card"><em>No curated workflows. Create ~/.claude/tracking/workflows-synthesized.json and re-run analyze-tracking.py.</em></div>';
    return;
  }
  root.innerHTML = items.map((w, i) => {
    const key = "synth:" + (w.name || i);
    const note = notes[key] || "";
    const seq = w.steps.map(s => `<span class="step">/${escapeHtml(s)}</span>`).join('<span class="arrow">→</span>');
    const evidence = (w.evidence || []).map(e => `<div style="font-family:ui-monospace,monospace;font-size:11px;color:#9aa;">${escapeHtml(e)}</div>`).join("");
    return `
      <div class="card">
        <div class="card-head">
          <div style="font-size:15px;color:var(--accent);font-weight:600;">${escapeHtml(w.name)}</div>
          <div class="count">${w.steps.length} steps</div>
        </div>
        <div class="desc">${escapeHtml(w.summary || "")}</div>
        <div class="seq" style="margin-top:10px;">${seq}</div>
        ${w.when_to_use ? `<div class="meta"><strong style="color:#bbb">When:</strong> ${escapeHtml(w.when_to_use)}</div>` : ""}
        <details style="margin-top:10px;"><summary style="color:var(--muted);cursor:pointer;font-size:12px;">evidence (${(w.evidence||[]).length} n-grams)</summary>${evidence}</details>
        <div class="meta">Your notes: <span class="editable ${note?'has-content':''}" contenteditable="true" data-key="${key}">${escapeHtml(note) || "click to add notes about this workflow"}</span></div>
      </div>`;
  }).join("");
  attachEditableHandlers();
}

renderSynth();
renderCommands();
renderWorkflows();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tracking-dir", default=str(DEFAULT_TRACKING))
    ap.add_argument("--commands-dir", default=str(DEFAULT_COMMANDS))
    ap.add_argument("--out", default=str(DEFAULT_OUT_HTML))
    ap.add_argument("--json", default=str(DEFAULT_OUT_JSON))
    ap.add_argument("--synthesized", default=str(DEFAULT_SYNTH_JSON),
                    help="optional curated workflows JSON to render in a third tab")
    ap.add_argument("--details", default=str(DEFAULT_DETAILS_JSON),
                    help="optional richer per-command descriptions JSON")
    ap.add_argument("--gap-minutes", type=int, default=60,
                    help="commands within this gap (same project) belong to one session")
    ap.add_argument("--top-workflows", type=int, default=60)
    ap.add_argument("--min-len", type=int, default=2)
    ap.add_argument("--max-len", type=int, default=5)
    args = ap.parse_args()

    tracking_dir = Path(args.tracking_dir)
    commands_dir = Path(args.commands_dir)
    if not tracking_dir.exists():
        sys.exit(f"tracking dir not found: {tracking_dir}")

    events = load_events(tracking_dir)
    descs = load_command_descriptions(commands_dir) if commands_dir.exists() else {}
    sessions = build_sessions(events, args.gap_minutes)
    workflows = compute_workflows(sessions, args.min_len, args.max_len, args.top_workflows)
    cmd_stats = compute_command_stats(events)

    synth = {"workflows": []}
    synth_path = Path(args.synthesized)
    if synth_path.exists():
        try:
            synth = json.loads(synth_path.read_text())
        except Exception as e:
            print(f"warn: failed to parse {synth_path}: {e}", file=sys.stderr)

    details = {"commands": {}}
    details_path = Path(args.details)
    if details_path.exists():
        try:
            details = json.loads(details_path.read_text())
        except Exception as e:
            print(f"warn: failed to parse {details_path}: {e}", file=sys.stderr)

    data = {
        "generated": datetime.now().isoformat(timespec="seconds"),
        "total_events": len(events),
        "total_sessions": len(sessions),
        "gap_minutes": args.gap_minutes,
        "descriptions": descs,
        "commands": cmd_stats,
        "workflows": workflows,
        "synthesized": synth.get("workflows", []),
        "details": details.get("commands", {}),
    }

    Path(args.json).write_text(json.dumps(data, indent=2, default=str))

    # Build a share-safe copy for embedding in the HTML — strips local-only
    # signals (project/folder names, costs, durations, occurrence dates) so the
    # rendered page can be uploaded to public hosts without leaking them.
    public_data = {
        "generated": data["generated"],
        "total_events": data["total_events"],
        "total_sessions": data["total_sessions"],
        "gap_minutes": data["gap_minutes"],
        "descriptions": data["descriptions"],
        "commands": [
            {"command": c["command"], "count": c["count"]}
            for c in data["commands"]
        ],
        "workflows": [
            {"sequence": w["sequence"], "length": w["length"], "count": w["count"]}
            for w in data["workflows"]
        ],
        "synthesized": data["synthesized"],
        "details": data["details"],
    }

    html = (HTML_TEMPLATE
            .replace("__DATA__", json.dumps(public_data, default=str))
            .replace("__GENERATED__", data["generated"])
            .replace("__TOTAL_EVENTS__", str(data["total_events"]))
            .replace("__TOTAL_SESSIONS__", str(data["total_sessions"]))
            .replace("__GAP__", str(args.gap_minutes))
            .replace("__N_COMMANDS__", str(len(cmd_stats)))
            .replace("__N_WORKFLOWS__", str(len(workflows)))
            .replace("__N_SYNTH__", str(len(data["synthesized"]))))
    Path(args.out).write_text(html)

    print(f"events={len(events)}  sessions={len(sessions)}  commands={len(cmd_stats)}  workflows={len(workflows)}")
    print(f"html: {args.out}")
    print(f"json: {args.json}")


if __name__ == "__main__":
    main()
