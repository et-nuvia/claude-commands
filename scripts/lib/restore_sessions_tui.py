#!/usr/bin/env python3
"""Interactive picker for Claude Code sessions killed by a forced reboot.

Run it from any terminal after the machine comes back up: arrow to each session,
space/return to select, then activate "Start sessions" to relaunch them all at
once — each in the right project folder, and in the same kind of terminal it was
running in before (VS Code integrated terminal, iTerm, or Terminal.app).

Launch mechanics differ per target because the tools differ: Terminal and iTerm
both take a "run this command in a new window" AppleScript verb, but VS Code has
no scriptable terminal at all, so its integrated terminal has to be driven by
keystroke — which is why VS Code needs Accessibility permission and the others
do not.
"""

from __future__ import annotations

import curses
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from session_registry import (  # noqa: E402
    ORPHANS, VSCODE_CLI_FALLBACK, ago, drop, read_records, sweep,
)

ACTION_ROW = "__start__"


# ─── launching ────────────────────────────────────────────────────────────────

def resume_command(record: dict) -> str:
    return f"cd {record.get('cwd', '')} && claude --resume {record['session_id']}"


def osascript(script: str) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True, timeout=45
        )
    except Exception as error:
        return False, str(error)
    return result.returncode == 0, (result.stderr or "").strip()


def launch_vscode(record: dict) -> tuple[bool, str]:
    cli = os.environ.get("VSCODE_CLI") or _which_code()
    folder = record.get("project_root") or record.get("cwd", "")
    if cli and folder:
        # Focuses the existing window when that folder is already open, so a
        # macOS-restored window is reused rather than duplicated.
        subprocess.run([cli, folder], capture_output=True, text=True, timeout=60)
        time.sleep(2.2)
    else:
        return False, "VS Code CLI not found (install 'code' in PATH)"

    ok, error = osascript(f'''
    tell application "Visual Studio Code" to activate
    delay 0.7
    tell application "System Events"
        tell process "Code"
            keystroke "`" using {{control down, shift down}}
            delay 0.9
            keystroke {json.dumps(resume_command(record))}
            key code 36
        end tell
    end tell
    ''')
    if not ok:
        return False, error or "osascript failed (grant Accessibility permission)"
    return True, ""


def launch_terminal(record: dict) -> tuple[bool, str]:
    command = json.dumps(resume_command(record))
    ok, error = osascript(f'''
    tell application "Terminal"
        activate
        do script {command}
    end tell
    ''')
    return ok, error


def launch_iterm(record: dict) -> tuple[bool, str]:
    command = json.dumps(resume_command(record))
    ok, error = osascript(f'''
    tell application "iTerm"
        activate
        set newWindow to (create window with default profile)
        tell current session of newWindow to write text {command}
    end tell
    ''')
    return ok, error


def _which_code() -> str | None:
    import shutil
    return shutil.which("code") or (
        VSCODE_CLI_FALLBACK if os.path.isfile(VSCODE_CLI_FALLBACK) else None
    )


def launch(record: dict) -> tuple[bool, str]:
    terminal = (record.get("terminal") or "").lower()
    if terminal == "vscode":
        return launch_vscode(record)
    if terminal == "iterm.app":
        return launch_iterm(record)
    return launch_terminal(record)


def target_label(record: dict) -> str:
    terminal = (record.get("terminal") or "").lower()
    if terminal == "vscode":
        return "VS Code"
    if terminal == "iterm.app":
        return "iTerm"
    return "Terminal"


# ─── tui ──────────────────────────────────────────────────────────────────────

def draw(screen, records: list[dict], selected: set[int], cursor: int) -> None:
    screen.erase()
    height, width = screen.getmaxyx()

    def put(row: int, col: int, text: str, attr: int = 0) -> None:
        if 0 <= row < height:
            screen.addnstr(row, col, text, max(0, width - col - 1), attr)

    put(0, 0, "Crashed Claude Code sessions", curses.A_BOLD)
    put(1, 0, "↑↓/jk move · space or return select · a all · q quit",
        curses.A_DIM)

    row = 3
    for index, record in enumerate(records):
        focused = index == cursor
        mark = "◉" if index in selected else "○"
        name = record.get("name") or record["session_id"][:8]
        project = os.path.basename(record.get("project_root") or record.get("cwd", "")) or "?"
        branch = record.get("git_branch") or "-"

        header = f" {mark} {name}   [{project} · {branch}]   → {target_label(record)}"
        put(row, 0, header.ljust(max(0, width - 1)),
            curses.A_REVERSE if focused else curses.A_BOLD)
        row += 1

        put(row, 5, f"{record.get('cwd', '')}", curses.A_DIM)
        row += 1
        detail = (f"last active {ago(record.get('last_activity') or 0)} · "
                  f"died: {record.get('died_reason', '?')}")
        put(row, 5, detail, curses.A_DIM)
        row += 1
        if record.get("last_prompt"):
            put(row, 5, f"\"{record['last_prompt'][:width - 8]}\"", curses.A_DIM)
            row += 1
        row += 1

    count = len(selected)
    label = f" ▶  Start {count} session{'s' if count != 1 else ''} "
    attr = curses.A_REVERSE if cursor == len(records) else curses.A_BOLD
    if count == 0:
        attr |= curses.A_DIM
    put(row, 0, label, attr)
    screen.refresh()


def run_picker(screen, records: list[dict]) -> set[int]:
    curses.curs_set(0)
    screen.keypad(True)
    selected: set[int] = set()
    cursor = 0
    last = len(records)  # index of the action row

    while True:
        draw(screen, records, selected, cursor)
        key = screen.getch()

        if key in (curses.KEY_UP, ord("k")):
            cursor = last if cursor == 0 else cursor - 1
        elif key in (curses.KEY_DOWN, ord("j"), ord("\t")):
            cursor = 0 if cursor == last else cursor + 1
        elif key == ord("a"):
            selected = set() if len(selected) == len(records) else set(range(len(records)))
        elif key == ord(" "):
            if cursor < last:
                selected.symmetric_difference_update({cursor})
        elif key in (curses.KEY_ENTER, 10, 13):
            if cursor == last:
                if selected:
                    return selected
            else:
                selected.symmetric_difference_update({cursor})
                cursor += 1  # selecting walks you down the list
        elif key in (ord("q"), 27):
            return set()


def main() -> int:
    sweep()
    records = read_records(ORPHANS)
    records.sort(key=lambda record: record.get("last_activity") or 0, reverse=True)

    if not records:
        print("No crashed sessions — everything exited cleanly.")
        return 0

    try:
        selected = curses.wrapper(run_picker, records)
    except KeyboardInterrupt:
        return 130

    if not selected:
        print("Nothing selected. Records kept — run this again any time.")
        return 0

    print()
    failures = []
    for index in sorted(selected):
        record = records[index]
        name = record.get("name") or record["session_id"][:8]
        print(f"  starting {name} in {target_label(record)} ({record.get('cwd', '')})")
        ok, error = launch(record)
        if ok:
            drop(record["_path"])  # the resumed session re-registers on SessionStart
        else:
            failures.append((record, error))
        # Serialize: each launch steals focus, so overlapping them would type
        # into whichever window happened to win the race.
        time.sleep(1.2)

    print()
    if failures:
        print(f"{len(failures)} session(s) could not be started automatically:")
        for record, error in failures:
            print(f"  - {record.get('name') or record['session_id'][:8]}: {error}")
            print(f"    {resume_command(record)}")
        print("\nVS Code needs Accessibility permission: System Settings > Privacy & "
              "Security > Accessibility (grant it to the terminal app you ran this from).")
        return 1

    print(f"Restored {len(selected)} session(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
