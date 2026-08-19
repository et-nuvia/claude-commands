#!/usr/bin/env python3
"""Interactive picker for deleting stale git worktrees.

Same shape as the crashed-session picker: arrow through the list, space to
select, activate the action row to act on everything selected at once.

The difference that matters is direction — that picker restores, this one
destroys. So nothing is ever preselected, worktrees holding uncommitted work are
refused unless you explicitly turn on force, and the action row states the count
and the risk before you commit to it.
"""

from __future__ import annotations

import curses
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from worktree_sweep import (  # noqa: E402
    DEFAULT_ROOTS, ago, attach_summaries, delete, load_cache, scan, summarize,
)

VERDICT_LABEL = {
    "gone": "STALE",
    "empty": "EMPTY",
    "content": "CONTENT",
}


def risk_of(record: dict) -> str:
    """What deleting this would actually cost."""
    if record["verdict"] == "gone":
        return "nothing — directory already gone"
    if record["verdict"] == "empty":
        return "nothing unique — safe"
    parts = []
    if record.get("ahead"):
        parts.append(f"{record['ahead']} unique commit{'s' if record['ahead'] != 1 else ''}")
    if record.get("dirty"):
        parts.append(f"{record['dirty']} uncommitted")
    if record.get("untracked"):
        parts.append(f"{record['untracked']} untracked")
    return "LOSES " + ", ".join(parts) if parts else "unclear"


def draw(screen, records, selected, cursor, force, drop_branch) -> None:
    screen.erase()
    height, width = screen.getmaxyx()
    rows_per_record = 4

    def put(row: int, col: int, text: str, attr: int = 0) -> None:
        if 0 <= row < height:
            screen.addnstr(row, col, text, max(0, width - col - 1), attr)

    put(0, 0, "Stale git worktrees under ~/projects", curses.A_BOLD)
    put(1, 0, "↑↓/jk move · space select · e empty+stale · c closed tasks · "
              f"f force:{'ON' if force else 'off'} · "
              f"b branch:{'ON' if drop_branch else 'off'} · q quit",
        curses.A_DIM)

    # Scroll so the cursor stays on screen with a long list.
    visible = max(1, (height - 6) // rows_per_record)
    first = max(0, min(cursor - visible // 2, max(0, len(records) - visible)))
    row = 3

    for index in range(first, min(len(records), first + visible)):
        record = records[index]
        focused = index == cursor
        mark = "◉" if index in selected else "○"
        name = f"{record['repo']}/{os.path.basename(record['path'])}"
        tag = VERDICT_LABEL.get(record["verdict"], "?")

        task = record.get("task_status") or ""
        task_tag = f"  <task:{task}>" if task and task != "no-doc" else ""
        header = f" {mark} [{tag}] {name}{task_tag}   {record['branch']}"
        put(row, 0, header.ljust(max(0, width - 1)),
            curses.A_REVERSE if focused else curses.A_BOLD)
        row += 1

        put(row, 5, f"{record['reason']} · last activity {ago(record.get('last_activity') or 0)}",
            curses.A_DIM)
        row += 1

        summary = record.get("summary") or ""
        if summary:
            state = record.get("state") or ""
            put(row, 5, f"{summary}" + (f"  [{state}]" if state else ""), curses.A_DIM)
            row += 1
        elif record["verdict"] == "content":
            put(row, 5, "(no summary — run with --summarize)", curses.A_DIM)
            row += 1
        put(row, 5, risk_of(record),
            curses.A_DIM if record["verdict"] != "content" else 0)
        row += 2

    blocked = [i for i in selected
               if records[i]["verdict"] == "content"
               and (records[i].get("dirty") or records[i].get("untracked"))
               and not force]
    count = len(selected)
    label = f" ▶  Delete {count} worktree{'s' if count != 1 else ''} "
    if blocked:
        label += f"({len(blocked)} will be refused — press f to force) "
    attr = curses.A_REVERSE if cursor == len(records) else curses.A_BOLD
    if count == 0:
        attr |= curses.A_DIM
    put(height - 2, 0, label, attr)
    screen.refresh()


def run_picker(screen, records):
    curses.curs_set(0)
    screen.keypad(True)
    selected: set[int] = set()   # never preselected — this action destroys
    cursor = 0
    action = len(records)
    force = False
    drop_branch = False

    while True:
        draw(screen, records, selected, cursor, force, drop_branch)
        key = screen.getch()

        if key in (curses.KEY_UP, ord("k")):
            cursor = action if cursor == 0 else cursor - 1
        elif key in (curses.KEY_DOWN, ord("j"), ord("\t")):
            cursor = 0 if cursor == action else cursor + 1
        elif key == ord("e"):
            # The safe bulk action: everything with nothing to lose.
            safe = {i for i, r in enumerate(records) if r["verdict"] in ("gone", "empty")}
            selected = set() if selected >= safe and safe else safe
        elif key == ord("c"):
            # Worktrees whose task is closed. Deliberately separate from 'e':
            # a closed task can still have unmerged commits, so this selects
            # things that WILL be refused unless you also turn on force.
            closed = {i for i, r in enumerate(records)
                      if r.get("task_status") in ("completed", "deferred")}
            selected = set() if selected >= closed and closed else closed
        elif key == ord("f"):
            force = not force
        elif key == ord("b"):
            drop_branch = not drop_branch
        elif key == ord(" "):
            if cursor < action:
                selected.symmetric_difference_update({cursor})
        elif key in (curses.KEY_ENTER, 10, 13):
            if cursor == action:
                if selected:
                    return selected, force, drop_branch
            else:
                selected.symmetric_difference_update({cursor})
                cursor = min(cursor + 1, action)
        elif key in (ord("q"), 27):
            return set(), force, drop_branch


def main() -> int:
    args = sys.argv[1:]
    roots = [Path(a).expanduser() for a in args if not a.startswith("-")] or DEFAULT_ROOTS

    print("Scanning worktrees...")
    records = scan(roots)
    if not records:
        print("No worktrees found under " + ", ".join(str(r) for r in roots))
        return 0

    if "--summarize" in args or "--summarise" in args:
        pending = [r for r in records if r["verdict"] == "content"]
        print(f"Summarizing {len(pending)} worktree(s) via claude -p "
              "(cached by branch head, so later runs are instant)...")
        _, done, limit = summarize(records, force="--force-summaries" in args)
        if limit:
            # Never block the picker on this: classification, timestamps, and
            # deletion all work without summaries.
            print(f"\n  ! Stopped summarizing early — {limit}")
            print(f"  ! {done} summarized, {len(pending) - done} will show "
                  "'(no summary)'. Re-run later to fill them in.\n")
            time.sleep(2.5)  # make sure this is read before curses takes over

    attach_summaries(records, load_cache())

    try:
        selected, force, drop_branch = curses.wrapper(run_picker, records)
    except KeyboardInterrupt:
        return 130

    if not selected:
        print("Nothing selected. No worktrees were touched.")
        return 0

    print()
    failures = 0
    for index in sorted(selected):
        record = records[index]
        ok, message = delete(record, force=force, drop_branch=drop_branch)
        name = f"{record['repo']}/{os.path.basename(record['path'])}"
        print(f"  {'✓' if ok else '✗'} {name}: {message}")
        failures += 0 if ok else 1

    print()
    print(f"Deleted {len(selected) - failures} of {len(selected)} selected.")
    if failures:
        print("Refused entries still hold uncommitted work — rerun and press "
              "'f' to force if you truly want them gone.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
