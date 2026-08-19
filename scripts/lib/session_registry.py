#!/usr/bin/env python3
"""Crash-survivable registry of running Claude Code sessions.

Problem this solves: IT-forced reboots kill every terminal without warning, so
sessions never fire SessionEnd. Their records are left behind, and a record left
behind is exactly the evidence needed to offer them back.

Liveness is decided by the machine's boot time, not by PID liveness alone: PIDs
are reused across a reboot, so a record stamped with an older boot is provably
dead no matter what is running under that PID now. Within one boot we fall back
to "PID exists AND its start time still matches what we recorded".

Boot time also decides staleness, and there is deliberately no age cutoff: a
session left open for days is normal, so wall-clock age proves nothing. A record
is restorable while the boot it ran in is either the current boot (it crashed on
its own) or the one immediately before (a reboot killed it); older boots are
cleared automatically. That needs a record of which boots happened, kept in
boots.json. Restoring re-registers the session under the current boot, so a
resumed session is current again.

Subcommands:
  hook-start / hook-end   read a hook payload on stdin (see session-registry.sh)
  sweep                   reclassify dead active records as orphans
  list [--json]           show orphaned sessions
  restore <n|id> [--print]  reopen VS Code + relaunch `claude --resume <id>`
  clear <n|id|--all>      drop records without restoring; --all sweeps first so
                          it clears every session that is not running
                          (`forget` is accepted as the original name)
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import environment  # noqa: E402  (path must be set first)

HOME = Path.home()
REGISTRY = HOME / ".claude" / "session-registry"
ACTIVE = REGISTRY / "active"
ORPHANS = REGISTRY / "orphans"
BOOTS = REGISTRY / "boots.json"
BOOT_HISTORY_KEEP = 10
CC_SESSIONS = HOME / ".claude" / "sessions"

VSCODE_CLI_FALLBACK = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"


# ─── system facts ─────────────────────────────────────────────────────────────

def boot_seconds() -> int:
    """Epoch seconds of the current boot. Same value for every session in a boot.

    Delegates to lib/environment.py so the macOS/Linux split lives in one place.
    """
    return environment.boot_seconds()


def proc_info(pid: int) -> tuple[str, str] | None:
    """(start_time, command) for a live PID, or None if it is gone."""
    if pid <= 0:
        return None
    try:
        result = subprocess.run(
            ["ps", "-o", "lstart=,command=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return None
    line = result.stdout.strip()
    if result.returncode != 0 or not line:
        return None
    # lstart renders as "Wed Aug 12 14:36:36 2026", with the day space-padded.
    match = re.match(r"^(\w{3} \w{3} [ \d]?\d \d{2}:\d{2}:\d{2} \d{4})\s+(.*)$", line)
    if not match:
        return None
    return match.group(1), match.group(2).strip()


def claude_process(session_id: str) -> dict:
    """Claude's own live registry keys by PID and carries the session id."""
    try:
        for path in CC_SESSIONS.glob("*.json"):
            try:
                data = json.loads(path.read_text())
            except Exception:
                continue
            if data.get("sessionId") == session_id:
                return data
    except Exception:
        pass
    return {}


def enclosing_claude_pid() -> int:
    """Walk up from this hook process to the `claude` that spawned it."""
    pid = os.getppid()
    for _ in range(6):
        info = proc_info(pid)
        if info is None:
            return 0
        _, command = info
        if "claude" in command:
            return pid
        try:
            parent = subprocess.run(
                ["ps", "-o", "ppid=", "-p", str(pid)],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
            pid = int(parent)
        except Exception:
            return 0
        if pid <= 1:
            return 0
    return 0


def git_context(cwd: str) -> tuple[str, str]:
    """(repo root or cwd, branch or '') — the folder a VS Code window would hold."""
    def git(*args: str) -> str:
        try:
            result = subprocess.run(
                ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=5
            )
            return result.stdout.strip() if result.returncode == 0 else ""
        except Exception:
            return ""

    # A worktree's own root is the right folder to reopen, not the main checkout.
    root = git("rev-parse", "--show-toplevel") or cwd
    return root, git("rev-parse", "--abbrev-ref", "HEAD")


def last_prompt(transcript_path: str) -> tuple[str, float]:
    """Last thing the user typed, to jog memory in the restore list."""
    if not transcript_path or not os.path.isfile(transcript_path):
        return "", 0.0
    text, stamp = "", 0.0
    try:
        with open(transcript_path, errors="replace") as handle:
            for line in handle:
                if '"user"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("type") != "user":
                    continue
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, list):
                    content = " ".join(
                        part.get("text", "") for part in content if isinstance(part, dict)
                    )
                if not isinstance(content, str) or not content.strip():
                    continue
                if content.lstrip().startswith("<"):  # system-reminder / tool noise
                    continue
                text = " ".join(content.split())[:160]
                stamp = os.path.getmtime(transcript_path)
    except Exception:
        pass
    return text, stamp


# ─── registry io ──────────────────────────────────────────────────────────────

def ensure_dirs() -> None:
    ACTIVE.mkdir(parents=True, exist_ok=True)
    ORPHANS.mkdir(parents=True, exist_ok=True)
    observe_boot(boot_seconds())


def read_boots() -> list[int]:
    try:
        return [int(value) for value in json.loads(BOOTS.read_text())["boots"]]
    except Exception:
        return []


def observe_boot(current: int) -> list[int]:
    """Append this boot to the history the moment any registry op runs.

    Deciding whether an orphan is one reboot old or five requires knowing which
    boots happened, and boot time alone cannot tell them apart. Appending on
    every op means the history is written by whichever session touches the
    registry first after a boot. The append is idempotent, so a lost race
    between two simultaneous SessionStarts costs nothing.
    """
    if not current:
        return read_boots()
    boots = read_boots()
    if boots and boots[-1] == current:
        return boots
    boots = [boot for boot in boots if boot != current] + [current]
    boots = boots[-BOOT_HISTORY_KEEP:]
    try:
        REGISTRY.mkdir(parents=True, exist_ok=True)
        tmp = BOOTS.with_suffix(".json.tmp")
        tmp.write_text(json.dumps({"boots": boots}, indent=2))
        tmp.replace(BOOTS)
    except Exception:
        pass
    return boots


def previous_boot() -> int | None:
    """The boot immediately before the current one, or None if never recorded."""
    boots = read_boots()
    return boots[-2] if len(boots) >= 2 else None


def read_records(directory: Path) -> list[dict]:
    records = []
    for path in sorted(directory.glob("*.json")):
        try:
            record = json.loads(path.read_text())
        except Exception:
            continue
        record["_path"] = str(path)
        records.append(record)
    return records


def write_record(directory: Path, record: dict) -> None:
    payload = {key: value for key, value in record.items() if not key.startswith("_")}
    path = directory / f"{record['session_id']}.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(path)


def drop(path: str | Path) -> None:
    try:
        Path(path).unlink()
    except FileNotFoundError:
        pass


# ─── hooks ────────────────────────────────────────────────────────────────────

def hook_start(payload: dict) -> None:
    ensure_dirs()
    session_id = payload.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not session_id:
        return

    cwd = payload.get("cwd") or os.getcwd()
    live = claude_process(session_id)
    root, branch = git_context(cwd)

    pid = int(live.get("pid") or 0) or enclosing_claude_pid()
    # Claude's own record stamps procStart in UTC; `ps` reports local time. Take
    # our own reading so the sweep compares like with like.
    info = proc_info(pid)
    proc_start = info[0] if info else live.get("procStart", "")

    write_record(ACTIVE, {
        "session_id": session_id,
        "pid": pid,
        "proc_start": proc_start,
        "boot_sec": boot_seconds(),
        "name": live.get("name", ""),
        "cwd": cwd,
        "project_root": root,
        "git_branch": branch,
        "terminal": os.environ.get("TERM_PROGRAM", ""),
        "transcript_path": payload.get("transcript_path", ""),
        "started_at": time.time(),
    })
    # Resuming a session clears its own orphan record.
    drop(ORPHANS / f"{session_id}.json")

    sweep(exclude=session_id)

    # Surface every orphan, not only ones this sweep just found: the reboot is
    # usually detected by the first session to come back, and the user is just as
    # likely to notice in the third. No age cutoff — sessions are legitimately
    # left open for days, so staleness is decided by boot boundary (see
    # prune_stale_orphans) rather than by wall clock.
    recent = [
        record for record in read_records(ORPHANS)
        if record.get("session_id") != session_id
    ]
    if recent:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": summarize(recent),
        }}))


def hook_end(payload: dict) -> None:
    """A clean exit is the one case that is definitively not a crash."""
    ensure_dirs()
    session_id = payload.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if session_id:
        drop(ACTIVE / f"{session_id}.json")


# ─── sweep ────────────────────────────────────────────────────────────────────

def prune_stale_orphans(current_boot: int) -> list[dict]:
    """Drop orphans that ran in a boot older than the previous one.

    A restorable session is one that either crashed during this boot or was
    killed by the reboot that ended the previous boot. Anything older has been
    through a boot the user already had the chance to restore it in, so it is
    noise in the picker.

    This deliberately replaces a wall-clock timeout — a session left open for
    days is normal, so age alone proves nothing about whether it is wanted. Only
    a boot boundary does. Note the test is the boot the session RAN in, not the
    boot that noticed it was dead: a sweep can first run several boots late, and
    that lateness says nothing about the session's age.

    Restoring is therefore self-correcting: the resumed session re-registers on
    SessionStart stamped with the current boot, so it is current again and stays
    restorable until a reboot it did not live through.
    """
    if not current_boot:
        return []  # cannot establish a boot boundary; leave everything alone

    keep = {current_boot}
    prior = previous_boot()
    if prior:
        keep.add(prior)

    dropped = []
    for record in read_records(ORPHANS):
        ran_in = record.get("boot_sec")
        if not ran_in or ran_in in keep:
            continue
        if prior is None:
            # No history yet, so "the previous boot" is unknowable and an older
            # boot_sec cannot be proven stale. Offer it once; the history being
            # written now makes the next pass decisive.
            continue
        drop(record["_path"])
        dropped.append(record)
    return dropped


def sweep(exclude: str = "") -> list[dict]:
    ensure_dirs()
    current_boot = boot_seconds()
    newly_dead = []

    # Prune before reclassifying so records found in this sweep are never
    # pruned by it.
    prune_stale_orphans(current_boot)

    for record in read_records(ACTIVE):
        session_id = record.get("session_id", "")
        if not session_id or session_id == exclude:
            continue

        reason = ""
        if current_boot and record.get("boot_sec") and record["boot_sec"] != current_boot:
            reason = "reboot"
        else:
            info = proc_info(int(record.get("pid") or 0))
            if info is None:
                reason = "process-gone"
            else:
                start, command = info
                recorded = record.get("proc_start", "")
                if recorded and start != recorded:
                    reason = "pid-reused"
                elif "claude" not in command:
                    reason = "pid-reused"

        if not reason:
            continue

        text, stamp = last_prompt(record.get("transcript_path", ""))
        record["died_reason"] = reason
        record["died_detected_at"] = time.time()
        record["died_boot_sec"] = current_boot
        record["last_prompt"] = text
        record["last_activity"] = stamp
        write_record(ORPHANS, record)
        drop(record["_path"])
        newly_dead.append(record)

    return newly_dead


def summarize(orphans: list[dict]) -> str:
    lines = [
        f"{len(orphans)} Claude Code session(s) died without a clean exit "
        f"(likely a forced reboot). Tell the user they can recover them with "
        f"/resume-crashed:"
    ]
    for record in orphans:
        lines.append(
            f"  - {record.get('name') or record['session_id'][:8]} "
            f"[{record.get('git_branch') or '-'}] {record.get('cwd', '')}"
        )
    return "\n".join(lines)


# ─── cli ──────────────────────────────────────────────────────────────────────

def ago(stamp: float) -> str:
    if not stamp:
        return "unknown"
    delta = max(0, int(time.time() - stamp))
    if delta < 3600:
        return f"{delta // 60}m ago"
    if delta < 86400:
        return f"{delta // 3600}h ago"
    return f"{delta // 86400}d ago"


def cmd_list(as_json: bool) -> int:
    sweep()
    orphans = read_records(ORPHANS)
    orphans.sort(key=lambda record: record.get("last_activity") or 0, reverse=True)

    if as_json:
        print(json.dumps({
            "status": "ok",
            "count": len(orphans),
            "orphans": [
                {key: value for key, value in record.items() if not key.startswith("_")}
                for record in orphans
            ],
        }, indent=2))
        return 0

    if not orphans:
        print("No orphaned sessions. Everything exited cleanly.")
        return 0

    print(f"{len(orphans)} orphaned session(s):\n")
    for index, record in enumerate(orphans, 1):
        print(f"  [{index}] {record.get('name') or record['session_id'][:8]}")
        print(f"      dir     {record.get('cwd', '')}")
        print(f"      branch  {record.get('git_branch') or '-'}   "
              f"died: {record.get('died_reason', '?')}   "
              f"last active: {ago(record.get('last_activity') or 0)}")
        if record.get("last_prompt"):
            print(f"      last    \"{record['last_prompt']}\"")
        print(f"      resume  cd {record.get('cwd', '')} && claude --resume {record['session_id']}")
        print()
    return 0


def pick(selector: str) -> dict | None:
    orphans = read_records(ORPHANS)
    orphans.sort(key=lambda record: record.get("last_activity") or 0, reverse=True)
    if selector.isdigit():
        index = int(selector) - 1
        return orphans[index] if 0 <= index < len(orphans) else None
    for record in orphans:
        if record.get("session_id", "").startswith(selector) or record.get("name") == selector:
            return record
    return None


def vscode_cli() -> str | None:
    return shutil.which("code") or (
        VSCODE_CLI_FALLBACK if os.path.isfile(VSCODE_CLI_FALLBACK) else None
    )


def applescript_type(command: str) -> tuple[bool, str]:
    """Open a fresh integrated terminal in the focused VS Code window and run `command`.

    VS Code exposes no CLI for its terminals, so keystroke automation is the only
    route. It needs Accessibility permission; failure here is non-fatal — the
    caller falls back to printing the command.
    """
    script = f'''
    tell application "Visual Studio Code" to activate
    delay 0.6
    tell application "System Events"
        tell process "Code"
            keystroke "`" using {{control down, shift down}}
            delay 0.8
            keystroke {json.dumps(command)}
            key code 36
        end tell
    end tell
    '''
    try:
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True, timeout=30
        )
    except Exception as error:
        return False, str(error)
    return result.returncode == 0, result.stderr.strip()


def cmd_restore(selector: str, print_only: bool, here: bool = False) -> int:
    record = pick(selector)
    if record is None:
        print(f"No orphaned session matching '{selector}'. Run: session-registry.sh list")
        return 1

    session_id = record["session_id"]
    cwd = record.get("cwd", "")
    command = f"cd {cwd} && claude --resume {session_id}"

    if here:
        # The caller is a shell that will exec into this session itself, so the
        # window/terminal automation is unnecessary — hand back the raw parts.
        drop(record["_path"])
        print(f"{cwd}\t{session_id}")
        return 0

    if print_only:
        print(command)
        return 0

    cli = vscode_cli()
    if cli:
        folder = record.get("project_root") or cwd
        # `code <folder>` focuses the existing window when that folder is already open.
        subprocess.run([cli, folder], capture_output=True, text=True, timeout=60)
        time.sleep(2.0)

    ok, error = applescript_type(command)
    if not ok:
        print("Could not drive the VS Code terminal automatically "
              f"({error or 'osascript failed'}).")
        print("Grant Accessibility permission to VS Code in System Settings > Privacy & "
              "Security > Accessibility, or paste this into a terminal:\n")
        print(f"  {command}")
        return 1

    drop(record["_path"])  # the resumed session re-registers itself on SessionStart
    print(f"Restored {record.get('name') or session_id[:8]} in {cwd}")
    return 0


def cmd_clear(selector: str) -> int:
    """Drop registry records without restoring them.

    `--all` sweeps first so that every session that is not currently running is
    cleared, not just the ones a previous sweep happened to notice. A live
    session is never touched: sweep only reclassifies records whose process is
    provably gone, and clearing only ever reads from ORPHANS.
    """
    if selector == "--all":
        sweep()
        cleared = read_records(ORPHANS)
        for record in cleared:
            drop(record["_path"])
        if not cleared:
            print("Nothing to clear — no non-running sessions in the registry.")
            return 0
        print(f"Cleared {len(cleared)} non-running session(s):")
        for record in cleared:
            print(f"  - {record.get('name') or record['session_id'][:8]} "
                  f"{record.get('cwd', '')}")
        return 0

    record = pick(selector)
    if record is None:
        print(f"No non-running session matching '{selector}'. "
              f"Run: session-registry.sh list")
        return 1
    drop(record["_path"])
    print(f"Cleared {record.get('name') or record['session_id'][:8]} "
          f"({record.get('cwd', '')}).")
    return 0


def main(argv: list[str]) -> int:
    command = argv[0] if argv else "list"
    args = argv[1:]

    if command in ("hook-start", "hook-end"):
        try:
            payload = json.loads(sys.stdin.read() or "{}")
        except Exception:
            payload = {}
        try:
            (hook_start if command == "hook-start" else hook_end)(payload)
        except Exception:
            pass  # a hook must never break the session
        return 0

    if command == "sweep":
        found = sweep()
        print(f"{len(found)} session(s) reclassified as orphaned.")
        return 0
    if command == "list":
        return cmd_list("--json" in args)
    if command == "restore":
        if not args:
            print("usage: session-registry.sh restore <n|session_id> [--print]")
            return 1
        return cmd_restore(args[0], "--print" in args, "--here" in args)
    if command in ("clear", "forget"):  # forget kept as the original name
        if not args:
            print(f"usage: session-registry.sh {command} <n|session_id|--all>")
            return 1
        return cmd_clear(args[0])

    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
