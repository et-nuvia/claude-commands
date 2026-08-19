#!/usr/bin/env python3
"""Find every git worktree under the project roots and decide which are junk.

Task worktrees accumulate: `/task-start` creates one per task, and finishing the
task rarely includes removing it. Months later there are dozens, and no way to
tell from the directory listing which ones still hold unmerged work and which are
empty shells left behind by a task that was abandoned or already merged.

Classification is deliberately conservative — the cost of a wrong "empty" call is
lost work, while the cost of a wrong "has content" call is one more line to read:

  gone      the registration outlives its directory (git calls this prunable)
  empty     no unmerged commits, no uncommitted edits, no untracked files
  content   anything else — unmerged commits, dirty tree, or stray files

"Unmerged" is measured against the repo's own default branch resolved from
origin/HEAD, because these repos do not agree on a name (praxis integrates into
dev, others into main).

Subcommands:
  scan [--json]              classify every worktree, no model calls
  summarize [--force]       fill in the AI summary cache for `content` worktrees
  delete <path> [...]        remove worktrees by path (refuses dirty ones)
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOME = Path.home()
DEFAULT_ROOTS = [HOME / "projects"]
CACHE_FILE = HOME / ".claude" / "state" / "worktree-summaries.json"

# Directories whose mtimes say nothing about when a human last worked here —
# installing dependencies or running a build would otherwise make an abandoned
# worktree look freshly edited.
SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache",
    "dist", "build", ".next", ".turbo", "target", ".mypy_cache", ".ruff_cache",
    "coverage", ".terraform", ".worktrees",
    # Tooling state, not human work: Claude drops settings.local.json here just
    # by being pointed at a directory, which would read as fresh activity.
    ".claude",
}

SUMMARY_MODEL = os.environ.get("WORKTREE_SUMMARY_MODEL", "sonnet")
SUMMARY_TIMEOUT = int(os.environ.get("WORKTREE_SUMMARY_TIMEOUT", "120"))

# Running out of tokens mid-sweep is normal, not exceptional: a sweep fans out
# dozens of model calls and may well be the thing that exhausts the quota. It
# must degrade to "no summaries" rather than erroring out or, worse, writing the
# limit message into the cache as though it were a summary.
#
# Matched against stdout AND stderr because `claude -p` exits 0 on several
# failures (an unrecognized model, for one), so the exit code alone cannot be
# trusted to mean success.
LIMIT_MARKERS = (
    "usage limit",
    "rate limit",
    "rate_limit",
    "too many requests",
    "429",
    "quota",
    "insufficient credit",
    "credit balance",
    "overloaded",
    "529",
    "upgrade to increase",
)


class UsageLimit(RuntimeError):
    """Quota or rate limit hit — stop the sweep, keep what was already done."""


def looks_like_limit(*texts: str) -> bool:
    blob = " ".join(t or "" for t in texts).lower()
    return any(marker in blob for marker in LIMIT_MARKERS)


# ─── git plumbing ─────────────────────────────────────────────────────────────

def git(repo: str, *args: str, timeout: int = 30) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def find_repos(roots: list[Path]) -> list[Path]:
    """Top-level git repos under each root. Not recursive: a repo inside a repo
    is either a submodule or a worktree, and both are found by other means."""
    repos = []
    for root in roots:
        if not root.is_dir():
            continue
        for entry in sorted(root.iterdir()):
            if entry.is_dir() and (entry / ".git").exists():
                repos.append(entry)
    return repos


def default_branch(repo: str) -> str:
    """The branch this repo's work merges into. These repos disagree (dev vs
    main), so ask the remote rather than assuming."""
    head = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if head:
        return head
    for candidate in ("origin/dev", "origin/main", "origin/master"):
        if git(repo, "rev-parse", "--verify", "--quiet", candidate):
            return candidate
    return ""


def list_worktrees(repo: str) -> list[dict]:
    """Parse `git worktree list --porcelain`, skipping the main checkout."""
    raw = git(repo, "worktree", "list", "--porcelain")
    entries, current = [], {}
    for line in raw.splitlines():
        if not line.strip():
            if current:
                entries.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        if key == "worktree":
            current = {"path": value}
        elif key == "branch":
            current["branch"] = value.replace("refs/heads/", "")
        elif key == "HEAD":
            current["head"] = value
        elif key in ("prunable", "detached", "bare", "locked"):
            current[key] = value or True
    if current:
        entries.append(current)
    # The first entry is always the main checkout — never a sweep candidate.
    return entries[1:]


def newest_mtime(path: Path) -> float:
    """Most recent human-meaningful edit under the worktree.

    Walks with SKIP_DIRS pruned so a `npm install` cannot pass for activity.
    """
    newest = 0.0
    for dirpath, dirnames, filenames in os.walk(path, topdown=True):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".git")]
        for name in filenames:
            try:
                mtime = os.lstat(os.path.join(dirpath, name)).st_mtime
            except OSError:
                continue
            if mtime > newest:
                newest = mtime
    return newest


def inspect(repo: str, entry: dict, base: str) -> dict:
    path = entry.get("path", "")
    record = {
        "path": path,
        "repo": os.path.basename(repo),
        "repo_path": repo,
        "branch": entry.get("branch") or "(detached)",
        "head": (entry.get("head") or "")[:8],
        "base": base,
    }
    # A worktree named for a task carries that task's state — a worktree whose
    # task is Completed or Deferred is a strong delete candidate regardless of
    # what git says about its commits.
    record.update(task_status(repo, task_id_from(path)))

    if entry.get("prunable") or not os.path.isdir(path):
        record.update(verdict="gone", reason="directory no longer exists",
                      ahead=0, dirty=0, untracked=0, last_activity=0.0)
        return record

    # Work that would actually be LOST by deleting. `git cherry` compares patch
    # content, not commit identity, so commits that reached the base branch via
    # squash-merge or rebase are correctly excluded — `rev-list base..HEAD`
    # counts those as unmerged and wildly overstates the risk. One real case
    # here: a branch reading 166 "unmerged" commits by rev-list has only 16 that
    # are not already in dev.
    ahead, ahead_raw_count = 0, 0
    if base:
        cherry = git(path, "cherry", base, "HEAD", timeout=60)
        if cherry:
            lines = [line for line in cherry.splitlines() if line.strip()]
            ahead = sum(1 for line in lines if line.startswith("+"))
            ahead_raw_count = len(lines)
        else:
            # No output means either fully integrated or cherry failed; fall
            # back so a cherry failure cannot silently read as "safe to delete".
            fallback = git(path, "rev-list", "--count", f"{base}..HEAD")
            ahead = ahead_raw_count = int(fallback) if fallback.isdigit() else 0

    status = git(path, "status", "--porcelain")
    lines = [line for line in status.splitlines() if line.strip()]
    untracked = sum(1 for line in lines if line.startswith("??"))
    dirty = len(lines) - untracked

    committed_at = git(path, "log", "-1", "--format=%ct")
    last_commit = float(committed_at) if committed_at.isdigit() else 0.0
    last_activity = max(last_commit, newest_mtime(Path(path)))

    if ahead == 0 and dirty == 0 and untracked == 0:
        already = ahead_raw_count - ahead
        verdict = "empty"
        reason = ("no unique commits, clean tree" if not already
                  else f"clean tree; all {already} commits already in {base.split('/')[-1]}")
    else:
        bits = []
        if ahead:
            merged_note = ""
            if ahead_raw_count > ahead:
                merged_note = f" ({ahead_raw_count - ahead} already merged)"
            bits.append(f"{ahead} unique commit{'s' if ahead != 1 else ''}{merged_note}")
        if dirty:
            bits.append(f"{dirty} uncommitted change{'s' if dirty != 1 else ''}")
        if untracked:
            bits.append(f"{untracked} untracked file{'s' if untracked != 1 else ''}")
        verdict, reason = "content", ", ".join(bits)

    record.update(verdict=verdict, reason=reason, ahead=ahead, dirty=dirty,
                  untracked=untracked, last_activity=last_activity,
                  last_commit=last_commit)
    return record


TASK_ID_RE = re.compile(r"^([0-9A-Za-z]{6})(?:\s-\s.*)?$")


def task_id_from(path: str) -> str:
    """A task worktree's directory name IS the task id (see /task-start)."""
    match = TASK_ID_RE.match(os.path.basename(path))
    return match.group(1).upper() if match else ""


def normalize_status(raw: str) -> str:
    """Collapse free-text Status lines into one of a few states.

    The field is prose, not an enum — real values include '✓ Completed',
    '⏸️ Deferred', 'Blocked (external dependency)', and
    'Completed — all functional, technical, and acceptance requirements...'.
    Substring matching is the only thing that survives that.
    """
    text = raw.lower()
    if "defer" in text:
        return "deferred"
    if "complete" in text:          # covers 'Completed', 'Complete', '✓ Completed'
        return "completed"
    if "hold" in text or "block" in text:
        return "on-hold"
    if "not started" in text or "backlog" in text:
        return "not-started"
    if "active" in text:
        return "active"
    return ""


def task_status(repo_path: str, task_id: str) -> dict:
    """Look up a task's state from its TSK doc.

    The containing directory outranks the Status line: 63 docs sitting in
    docs/completed/ still say '**Status**: Active' inside, because closing a
    task moves the file but does not always rewrite the field. Trusting the
    field alone would report most finished work as still active.

    The field still matters for one distinction the directory cannot make:
    completed vs deferred, since /task-close files both under completed/.
    """
    if not task_id:
        return {}

    candidates: list[tuple[Path, str]] = []
    for location in ("active", "completed"):
        base = Path(repo_path) / "docs" / location
        if base.is_dir():
            candidates += [(p, location) for p in base.glob(f"**/{task_id}-*.md")]
    if not candidates:
        return {"task_id": task_id, "task_status": "no-doc"}

    def rank(item: tuple[Path, str]) -> tuple[int, float]:
        path, _ = item
        # Prefer a TSK (it owns the Status field), then the most recently
        # touched doc — a task that moved active→completed, or was reopened by
        # /task-resume, can leave docs in both trees, and the latest write is
        # the one that reflects the current state.
        is_tsk = "-TSK-" in path.name
        try:
            mtime = path.stat().st_mtime
        except OSError:
            mtime = 0.0
        return (0 if is_tsk else 1, -mtime)

    candidates.sort(key=rank)
    doc, location = candidates[0]

    raw = ""
    try:
        for line in doc.read_text(errors="replace").splitlines()[:40]:
            if line.startswith("**Status**"):
                raw = line.split(":", 1)[1].strip() if ":" in line else ""
                break
    except OSError:
        pass

    status = normalize_status(raw)
    if not status or (location == "completed" and status not in ("completed", "deferred")):
        # No parseable field (a DSN or PLN carries none), or a stale one in
        # completed/. Fall back to the directory, which is the reliable signal.
        status = "completed" if location == "completed" else "active"
    return {"task_id": task_id, "task_status": status,
            "task_doc": str(doc), "task_status_raw": raw}


def resolve(path: Path) -> dict | None:
    """Classify a single worktree by path, without scanning every root.

    Deletion takes explicit paths, which may sit outside the default roots
    entirely, so resolving directly is both correct and far faster than
    rescanning every repo to find one entry.
    """
    target = str(path)
    common = git(target, "rev-parse", "--git-common-dir")
    if not common:
        return None
    if not os.path.isabs(common):
        common = os.path.join(target, common)
    repo = os.path.dirname(os.path.abspath(common))

    for entry in list_worktrees(repo):
        if os.path.realpath(entry.get("path", "")) == os.path.realpath(target):
            return inspect(repo, entry, default_branch(repo))
    return None


def scan(roots: list[Path]) -> list[dict]:
    records = []
    for repo in find_repos(roots):
        entries = list_worktrees(str(repo))
        if not entries:
            continue
        base = default_branch(str(repo))
        for entry in entries:
            records.append(inspect(str(repo), entry, base))
    # Oldest first: the top of the list is what you most likely want gone.
    records.sort(key=lambda r: (r["verdict"] != "gone", r["verdict"] != "empty",
                                r.get("last_activity") or 0))
    return records


# ─── summaries ────────────────────────────────────────────────────────────────

def load_cache() -> dict:
    try:
        return json.loads(CACHE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_cache(cache: dict) -> None:
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(cache, indent=2))
    tmp.replace(CACHE_FILE)


def cache_key(record: dict) -> str:
    # Keyed by HEAD so a summary is reused until the branch actually moves.
    return f"{record['path']}@{record['head']}"


def summary_prompt(record: dict) -> str:
    """Feed commit subjects and a diffstat, never full diffs.

    The question is "is this worth keeping", which subjects and touched files
    answer. Full diffs would multiply the token cost across dozens of worktrees
    for no better an answer.
    """
    path, base = record["path"], record.get("base") or ""
    subjects = git(path, "log", "--format=%s", "-15", f"{base}..HEAD" if base else "-15")
    stat = git(path, "diff", "--stat", f"{base}...HEAD") if base else ""
    dirty = git(path, "status", "--short")

    return (
        "Summarize this abandoned git worktree so I can decide whether to delete it.\n"
        "Reply with exactly two lines and nothing else:\n"
        "SUMMARY: <one sentence, max 20 words, what this work does>\n"
        "STATE: <one of: complete, in-progress, scratch, unclear> — <max 8 words why>\n\n"
        f"Branch: {record['branch']}\n"
        f"Base: {base or 'unknown'}\n\n"
        f"Commits not in base:\n{subjects or '(none)'}\n\n"
        f"Diffstat vs base:\n{stat[:2000] or '(none)'}\n\n"
        f"Uncommitted changes:\n{dirty[:1000] or '(none)'}\n"
    )


def summarize_one(record: dict) -> tuple[str, dict]:
    prompt = summary_prompt(record)
    # Deliberately NOT run with cwd inside the worktree. Claude writes a
    # .claude/settings.local.json into its working directory, which would touch
    # the tree and reset the "last activity" timestamp this tool exists to
    # report — inspecting a worktree would make every worktree look edited
    # moments ago. The prompt already carries the git context, so a neutral cwd
    # loses nothing.
    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--model", SUMMARY_MODEL],
            capture_output=True, text=True, timeout=SUMMARY_TIMEOUT,
            cwd=tempfile.gettempdir(),
        )
    except subprocess.TimeoutExpired:
        return cache_key(record), None
    except FileNotFoundError:
        raise UsageLimit("the `claude` CLI is not on PATH")
    except Exception:
        return cache_key(record), None

    # Check both streams before trusting the exit code — `claude -p` exits 0 on
    # failures it reports only as text.
    if looks_like_limit(result.stdout, result.stderr):
        raise UsageLimit(_limit_detail(result.stdout, result.stderr))

    if result.returncode != 0:
        return cache_key(record), None

    summary, state = "", ""
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.upper().startswith("SUMMARY:"):
            summary = line.split(":", 1)[1].strip()
        elif line.upper().startswith("STATE:"):
            state = line.split(":", 1)[1].strip()
    if not summary:
        # Never invent a summary from arbitrary output: an unparseable response
        # cached as a summary is indistinguishable from a real one later.
        return cache_key(record), None
    return cache_key(record), {"summary": summary, "state": state or "unclear",
                               "generated_at": time.time()}


def _limit_detail(stdout: str, stderr: str) -> str:
    for stream in (stderr, stdout):
        for line in (stream or "").splitlines():
            if looks_like_limit(line):
                return " ".join(line.split())[:200]
    return "usage limit reached"


def summarize(records: list[dict], force: bool = False,
              workers: int = 4) -> tuple[dict, int, str]:
    """Fill the cache for content-bearing worktrees, concurrently.

    Only `content` worktrees are summarized: an empty or gone worktree has
    nothing to describe, and paying a model call to say so would be the bulk of
    the runtime on a typical sweep.

    Returns (cache, done_count, limit_message). A non-empty limit_message means
    the run stopped early on a quota or rate limit — everything already
    summarized is saved, and the sweep continues without the rest. Running out
    of tokens is a normal outcome here, not a crash.
    """
    cache = load_cache()
    todo = [r for r in records
            if r["verdict"] == "content" and (force or cache_key(r) not in cache)]
    if not todo:
        return cache, 0, ""

    done, limit_message = 0, ""
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(summarize_one, record): record for record in todo}
        for future in concurrent.futures.as_completed(futures):
            if limit_message:
                future.cancel()
                continue
            try:
                key, value = future.result()
            except UsageLimit as limit:
                # Stop issuing work immediately: every further call would hit the
                # same wall, and hammering a rate limit only lengthens the
                # backoff. In-flight calls are allowed to land.
                limit_message = str(limit)
                for pending in futures:
                    pending.cancel()
                continue
            except Exception:
                continue
            # A failure is never cached — the cache is keyed by branch head and
            # would otherwise pin a "(failed)" entry until the branch moves,
            # so a transient outage would look permanent.
            if value is not None:
                cache[key] = value
                done += 1

    save_cache(cache)
    return cache, done, limit_message


def attach_summaries(records: list[dict], cache: dict) -> None:
    for record in records:
        entry = cache.get(cache_key(record)) or {}
        record["summary"] = entry.get("summary", "")
        record["state"] = entry.get("state", "")


# ─── deletion ─────────────────────────────────────────────────────────────────

def delete(record: dict, force: bool = False, drop_branch: bool = False) -> tuple[bool, str]:
    """Remove one worktree. Refuses to discard uncommitted work unless forced."""
    repo, path = record["repo_path"], record["path"]

    if record["verdict"] == "gone":
        git(repo, "worktree", "prune")
        return True, "pruned stale registration"

    if not force and (record.get("dirty") or record.get("untracked")):
        return False, "has uncommitted changes (use --force to discard)"

    args = ["worktree", "remove", path]
    if force:
        args.insert(2, "--force")
    result = subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, text=True, timeout=120
    )
    if result.returncode != 0:
        return False, (result.stderr or "").strip().splitlines()[-1:][0] if result.stderr else "git worktree remove failed"

    message = "removed"
    if drop_branch and record.get("branch") and record["branch"] != "(detached)":
        # -d only: refuses to drop a branch holding unmerged commits, which is
        # exactly the guard we want when deleting in bulk.
        branch_result = subprocess.run(
            ["git", "-C", repo, "branch", "-d", record["branch"]],
            capture_output=True, text=True, timeout=30,
        )
        message += " + branch deleted" if branch_result.returncode == 0 else " (branch kept: unmerged)"
    return True, message


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


def roots_from(args: list[str]) -> list[Path]:
    explicit = [Path(a).expanduser() for a in args if not a.startswith("-")]
    return explicit or DEFAULT_ROOTS


def cmd_scan(args: list[str]) -> int:
    records = scan(roots_from(args))
    attach_summaries(records, load_cache())

    if "--json" in args:
        print(json.dumps({"status": "ok", "count": len(records),
                          "worktrees": records}, indent=2))
        return 0

    if not records:
        print("No worktrees found.")
        return 0

    buckets = {"gone": [], "empty": [], "content": []}
    for record in records:
        buckets[record["verdict"]].append(record)

    for verdict, label in (("gone", "Stale registrations (directory missing)"),
                           ("empty", "Empty — safe to delete"),
                           ("content", "Has content")):
        group = buckets[verdict]
        if not group:
            continue
        print(f"\n{label} ({len(group)}):\n")
        for record in group:
            task = record.get("task_status") or ""
            tag = f"  <task: {task}>" if task and task != "no-doc" else ""
            print(f"  {record['repo']}/{os.path.basename(record['path'])}  "
                  f"[{record['branch']}]{tag}")
            print(f"      {record['reason']} · last activity {ago(record.get('last_activity') or 0)}")
            if record.get("summary"):
                print(f"      {record['summary']}")
    print()
    return 0


def cmd_summarize(args: list[str]) -> int:
    records = scan(roots_from(args))
    pending = [r for r in records if r["verdict"] == "content"]
    print(f"Summarizing {len(pending)} worktree(s) with content via claude -p...")
    _, done, limit = summarize(records, force="--force" in args)

    if limit:
        remaining = len(pending) - done
        print(f"\nStopped early — {limit}")
        print(f"{done} summarized, {remaining} still without a summary.")
        print("Everything summarized so far is cached; re-run later to finish.")
        print(f"Cache: {CACHE_FILE}")
        return 0  # not an error: the sweep still works, just with fewer summaries

    print(f"Summarized {done}. Cache written to {CACHE_FILE}")
    return 0


def cmd_delete(args: list[str]) -> int:
    force = "--force" in args
    drop_branch = "--delete-branch" in args
    paths = [a for a in args if not a.startswith("-")]
    if not paths:
        print("usage: worktree-sweep.sh delete <path> [...] [--force] [--delete-branch]")
        return 1

    failures = 0
    for path in paths:
        record = resolve(Path(path).expanduser())
        if record is None:
            print(f"  ✗ {path}: not a git worktree")
            failures += 1
            continue
        ok, message = delete(record, force=force, drop_branch=drop_branch)
        print(f"  {'✓' if ok else '✗'} {record['repo']}/{os.path.basename(path)}: {message}")
        failures += 0 if ok else 1
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    command = argv[0] if argv else "scan"
    args = argv[1:]
    if command == "scan":
        return cmd_scan(args)
    if command == "summarize":
        return cmd_summarize(args)
    if command == "delete":
        return cmd_delete(args)
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
