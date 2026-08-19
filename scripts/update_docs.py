#!/usr/bin/env python3
"""
update_docs.py — fast replacement for the bash docs indexer (scripts/update-docs.sh).

Pipeline design: COLLECT -> FILTER-TO-UNIQUE -> PROCESS -> RENDER/VERIFY.

* COLLECT          — gather a flat list of candidate document paths from every
                     source (each local branch via one ``git ls-tree`` call, plus
                     the working tree) doing NO parsing beyond a cheap basename
                     prefilter.
* FILTER-TO-UNIQUE — collapse candidates to one entry per basename BEFORE any
                     per-document parsing, since the same filename appears on many
                     branches/worktrees.
* PROCESS          — parse each unique doc once and group by task ID.
* RENDER           — fill the SEQUENCE-TRACKER and DOCUMENT-INDEX templates.
* VERIFY           — confirm every work item/doc is present in the rendered
                     output; on failure, restore the previous outputs from backup.

``main()`` wires the stages: it feeds the real ``git_branch_refs``/``git_ls_tree``
wrappers into the pipeline (scanning every local branch), then writes and verifies
the two index files under ``--docs-dir`` (default resolved via ``find_docs_dir``).

The subprocess-touching code is isolated in thin wrappers (``git_branch_refs``,
``git_ls_tree``) so the collect/filter/parse/render logic stays pure and
unit-testable without a real multi-branch git repository.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# A candidate document basename: <TASKID>-<DATETIME>-<TYPE>-<...>.md
#   TASKID   = 6 uppercase hex chars (capture group "seq")
#   DATETIME = 10 or 12 digits      (capture group "datetime")
#   TYPE     = 3 uppercase letters  (capture group "type")
#   TITLE    = remainder before .md (capture group "title")
_DOC_NAME_RE = re.compile(
    r"^(?P<seq>[A-F0-9]{6})-(?P<datetime>[0-9]{10,12})-(?P<type>[A-Z]{3})-(?P<title>.+)\.md$"
)

# Type alias: a callable that returns the doc paths tracked under docs/ for a ref.
LsTree = Callable[[str], "list[str]"]

# Type alias: a callable that reads a file's text (injectable for tests).
ReadText = Callable[[str], str]


def is_candidate(path: str) -> bool:
    """Return True if ``path``'s basename matches the doc-filename shape.

    Cheap prefilter applied at collect time — NOT full parsing.
    """
    return bool(_DOC_NAME_RE.match(Path(path).name))


def git_branch_refs() -> list[str]:
    """Return local branch refs (``refs/heads/...``); empty list if not a repo."""
    try:
        result = subprocess.run(
            ["git", "for-each-ref", "--format=%(refname)", "refs/heads"],
            capture_output=True,
            text=True,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def git_ls_tree(ref: str) -> list[str]:
    """Return paths under ``docs/`` tracked at ``ref`` (one subprocess per ref)."""
    try:
        result = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", ref, "--", "docs/"],
            capture_output=True,
            text=True,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def walk_worktree(docs_dir: Path) -> list[str]:
    """Walk the working tree under ``docs_dir`` for ``.md`` files.

    Pure collector — returns every ``.md`` file found, WITHOUT applying the
    candidate prefilter; ``collect_candidates`` owns the single prefilter pass so
    both the git and worktree sources are filtered identically. Tolerates a
    missing or empty directory (returns an empty list).
    """
    docs_dir = Path(docs_dir)
    if not docs_dir.is_dir():
        return []
    return [str(p) for p in sorted(docs_dir.rglob("*.md")) if p.is_file()]


def filter_to_unique(candidates: Iterable[str]) -> list[str]:
    """Collapse candidate paths to one entry per basename.

    Preserves the first occurrence of each basename and its order. This is its
    own stage, deliberately separate from any later per-document parsing.
    """
    seen: set[str] = set()
    unique: list[str] = []
    for path in candidates:
        name = Path(path).name
        if name in seen:
            continue
        seen.add(name)
        unique.append(path)
    return unique


def collect_candidates(
    docs_dir: Path,
    branch_refs: list[str],
    ls_tree: LsTree,
) -> list[str]:
    """Run COLLECT then FILTER-TO-UNIQUE, returning unique candidate paths.

    ``branch_refs`` and ``ls_tree`` are injected so callers (and tests) control
    the git surface. One ``ls_tree`` call is made per branch ref; working-tree
    docs are appended; non-candidate paths are dropped before dedup.
    """
    candidates: list[str] = []
    for ref in branch_refs:
        candidates.extend(ls_tree(ref))
    candidates.extend(walk_worktree(docs_dir))
    return filter_to_unique(p for p in candidates if is_candidate(p))


def _title_case(text: str) -> str:
    """Title-case ``text``: first letter of each word upper, rest lower.

    Mirrors the bash ``title_case`` awk routine (update-docs.sh:70-72), which
    splits on whitespace and rebuilds ``toupper(first)+tolower(rest)`` per word.
    """
    return " ".join(word[:1].upper() + word[1:].lower() for word in text.split())


def _format_display_date(date: str) -> str:
    """Format a >=10-digit timestamp as ``YYYY-MM-DD HH:MM`` (YYYY = 20 + first 2).

    Mirrors update-docs.sh:116-126; shorter strings yield ``[invalid date]``.
    """
    if len(date) >= 10:
        return f"20{date[0:2]}-{date[2:4]}-{date[4:6]} {date[6:8]}:{date[8:10]}"
    return "[invalid date]"


@dataclass(frozen=True)
class DocRecord:
    """One parsed document (per-doc data the DOCUMENT-INDEX renders)."""

    seq: str
    doc_type: str
    date: str  # first 10 digits, for comparison/grouping
    display_date: str
    status: str  # active | on-hold | completed (derived)
    location: str  # "<derived_status>/<range>" — not the physical path
    range: str  # YYYY-MM parent folder
    filename: str
    title: str


@dataclass
class WorkItem:
    """Per-task-ID rollup the SEQUENCE-TRACKER renders (mirrors bash seq_* maps)."""

    seq: str
    types: str = ""  # distinct doc types, "/"-joined in encounter order
    title: str = ""  # first title encountered wins
    status: str = ""  # completed always wins; else first active/on-hold set
    date: str = ""  # earliest (lexicographic min) 10-digit string


@dataclass
class GroupedDocs:
    """PROCESS output: per-work-item rollups plus the flat per-doc list."""

    work_items: dict[str, WorkItem] = field(default_factory=dict)
    documents: list[DocRecord] = field(default_factory=list)


def parse_document(path: str, has_on_hold_marker: bool) -> DocRecord:
    """Parse a single doc path into a :class:`DocRecord` (pure).

    ``has_on_hold_marker`` reports whether the file body contains a line matching
    ``^## Task On Hold`` — injected so parsing stays pure and file-free for tests.
    Mirrors the status derivation in update-docs.sh:99-113.
    """
    name = Path(path).name
    match = _DOC_NAME_RE.match(name)
    if match is None:
        raise ValueError(f"not a candidate document name: {name}")

    seq = match.group("seq")
    doc_type = match.group("type")
    date = match.group("datetime")[:10]
    title = _title_case(match.group("title").replace("-", " "))

    if "/active/" in path:
        status = "on-hold" if has_on_hold_marker else "active"
    elif "/on-hold/" in path:
        status = "on-hold"
    else:
        status = "completed"

    doc_range = Path(path).parent.name
    return DocRecord(
        seq=seq,
        doc_type=doc_type,
        date=date,
        display_date=_format_display_date(date),
        status=status,
        location=f"{status}/{doc_range}",
        range=doc_range,
        filename=name,
        title=title,
    )


def group_documents(records: Iterable[DocRecord]) -> GroupedDocs:
    """Group per-doc records into per-task-ID work items (pure).

    Mirrors the seq_* accumulation in update-docs.sh:128-154: accumulate distinct
    types in encounter order, keep the first title, let ``completed`` always win
    the status (else first-set), and keep the earliest date.
    """
    grouped = GroupedDocs()
    for rec in records:
        grouped.documents.append(rec)
        item = grouped.work_items.get(rec.seq)
        if item is None:
            item = WorkItem(seq=rec.seq)
            grouped.work_items[rec.seq] = item

        types = item.types.split("/") if item.types else []
        if rec.doc_type not in types:
            item.types = f"{item.types}/{rec.doc_type}" if item.types else rec.doc_type

        if not item.title:
            item.title = rec.title

        if rec.status == "completed" or not item.status:
            item.status = rec.status

        if not item.date or rec.date < item.date:
            item.date = rec.date

    return grouped


def process_documents(
    paths: Iterable[str],
    read_text: ReadText | None = None,
) -> GroupedDocs:
    """Run PROCESS: parse every path in ``paths``, then group by task ID.

    PRECONDITION: ``paths`` must already be deduplicated by basename — it is the
    output of :func:`collect_candidates`, whose FILTER-TO-UNIQUE stage owns that
    collapse. PROCESS deliberately does NOT dedup again: dedup is a distinct
    earlier stage, never folded into per-document parsing (the coupling the bash
    indexer had at update-docs.sh:79-81). Passing duplicate basenames here would
    double-count types/title/date for a task ID — that is the caller's contract
    to uphold, not this function's to defend.

    ``read_text`` is injected for the on-hold-marker check; it defaults to reading
    the real file (tolerating read errors as "no marker").
    """
    if read_text is None:
        read_text = _default_read_text

    records: list[DocRecord] = []
    for path in paths:
        has_marker = _has_on_hold_marker(read_text(path))
        records.append(parse_document(path, has_on_hold_marker=has_marker))
    return group_documents(records)


def _default_read_text(path: str) -> str:
    """Read a file's text, returning "" on any read error (bash uses 2>/dev/null)."""
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        return ""


def _has_on_hold_marker(text: str) -> bool:
    """True if any line matches ``^## Task On Hold`` (update-docs.sh:104)."""
    return any(line.startswith("## Task On Hold") for line in text.splitlines())


_STATUS_ICON = {"completed": "✅", "on-hold": "⏸️", "active": "🔄"}
_STATUS_WORD = {"completed": "Completed", "on-hold": "On Hold", "active": "Active"}


def _doc_status_display(status: str) -> str:
    """Render a per-doc status cell, e.g. ``🔄 Active`` (update-docs.sh:330-332)."""
    return f"{_STATUS_ICON[status]} {_STATUS_WORD[status]}"


def render_sequence_tracker(
    grouped: GroupedDocs,
    template_text: str,
    last_updated: str,
) -> str:
    """Render SEQUENCE-TRACKER.md text (pure; mirrors update-docs.sh:238-281).

    Work items are emitted in ascending task-ID order (bash ``sorted_seqs``).
    A work item lands in the completed table iff its status is ``completed``;
    otherwise (active or on-hold) it lands in the active table. Empty tables
    collapse to the ``| (none) | - | - |`` placeholder row. The trailing newline
    on each table mirrors the bash ``echo -e`` of strings ending in ``\\n``.
    """
    active_rows: list[str] = []
    completed_rows: list[str] = []
    for seq in sorted(grouped.work_items):
        item = grouped.work_items[seq]
        row = f"| {seq} | {item.types} | {item.title} |"
        if item.status == "completed":
            completed_rows.append(row)
        else:
            active_rows.append(row)

    active_table = _join_table(active_rows)
    completed_table = _join_table(completed_rows)

    output = template_text
    output = output.replace("{{ACTIVE_SEQUENCES}}", active_table)
    output = output.replace("{{COMPLETED_SEQUENCES}}", completed_table)
    output = output.replace("{{LAST_UPDATED}}", last_updated)
    return output


def _join_table(rows: list[str]) -> str:
    """Join table rows the way the bash accumulator did (each row + ``\\n``).

    Empty input yields the single ``(none)`` placeholder row. The result always
    ends in a trailing newline, reproducing bash's ``table+="...\\n"`` followed by
    ``echo -e``.
    """
    if not rows:
        rows = ["| (none) | - | - |"]
    return "".join(f"{row}\n" for row in rows)


def render_document_index(
    grouped: GroupedDocs,
    template_text: str,
    last_updated: str,
    timestamp: str,
) -> str:
    """Render DOCUMENT-INDEX.md text (pure; mirrors update-docs.sh:287-367).

    Work items are emitted in DESCENDING task-ID order (bash ``sort -rn`` at
    line 291, which on these non-numeric hex IDs is a reverse string sort). Each
    section lists that work item's documents in encounter order. All count and
    range placeholders are substituted; ``{{NEXT_SEQ}}`` is intentionally left
    untouched, matching the bash (it never substitutes it).
    """
    docs_by_seq: dict[str, list[DocRecord]] = {}
    for rec in grouped.documents:
        docs_by_seq.setdefault(rec.seq, []).append(rec)

    sections: list[str] = []
    for seq in sorted(grouped.work_items, reverse=True):
        item = grouped.work_items[seq]
        item_docs = docs_by_seq.get(seq, [])
        icon = _STATUS_ICON[item.status]
        word = _STATUS_WORD[item.status]

        section = (
            f"\n### Work Item {seq}: {item.title} "
            f"({len(item_docs)} documents) {icon}\n\n"
        )
        section += "| Type | Date | Status | Location | Filename |\n"
        section += "|------|------|--------|----------|----------|\n"
        for rec in item_docs:
            section += (
                f"| {rec.doc_type} | {rec.display_date} | "
                f"{_doc_status_display(rec.status)} | {rec.location}/ | "
                f"{rec.filename} |\n"
            )
        section += f"\n**Theme**: {item.title}\n"
        section += f"**Types**: {item.types}\n"
        section += f"**Status**: {icon} {word}\n"
        sections.append(section)

    work_items_section = "".join(sections)

    sorted_seqs = sorted(grouped.work_items)
    first_seq = sorted_seqs[0] if sorted_seqs else "000000"
    last_seq = sorted_seqs[-1] if sorted_seqs else "000000"

    total_docs = len(grouped.documents)
    active_docs = sum(1 for d in grouped.documents if d.status == "active")
    on_hold_docs = sum(1 for d in grouped.documents if d.status == "on-hold")
    completed_docs = sum(1 for d in grouped.documents if d.status == "completed")

    items = grouped.work_items.values()
    active_work_items = sum(1 for i in items if i.status == "active")
    on_hold_work_items = sum(1 for i in items if i.status == "on-hold")
    completed_work_items = sum(1 for i in items if i.status == "completed")
    total_work_items = len(grouped.work_items)

    replacements = {
        "{{LAST_UPDATED}}": last_updated,
        "{{TOTAL_DOCS}}": str(total_docs),
        "{{TOTAL_WORK_ITEMS}}": str(total_work_items),
        "{{FIRST_SEQ}}": first_seq,
        "{{LAST_SEQ}}": last_seq,
        "{{ACTIVE_DOCS}}": str(active_docs),
        "{{ACTIVE_WORK_ITEMS}}": str(active_work_items),
        "{{ON_HOLD_DOCS}}": str(on_hold_docs),
        "{{ON_HOLD_WORK_ITEMS}}": str(on_hold_work_items),
        "{{COMPLETED_DOCS}}": str(completed_docs),
        "{{COMPLETED_WORK_ITEMS}}": str(completed_work_items),
        "{{TIMESTAMP}}": timestamp,
        # {{WORK_ITEMS}} MUST be substituted LAST: its value embeds doc/work-item
        # titles and is the only large free-text injection. Replacing it last means
        # no later placeholder pass can re-scan text that came from a title — this
        # mirrors the bash single-pass substitution (update-docs.sh:363) where a
        # replacement value is never itself re-scanned.
        "{{WORK_ITEMS}}": work_items_section,
    }
    output = template_text
    for placeholder, value in replacements.items():
        output = output.replace(placeholder, value)
    return output


# Type alias: the VERIFY callable (injectable so tests force a failure).
VerifyFn = Callable[[str, str, "GroupedDocs"], "tuple[list[str], list[str]]"]


def verify_outputs(
    sequence_text: str,
    index_text: str,
    grouped: GroupedDocs,
) -> tuple[list[str], list[str]]:
    """VERIFY (pure): return (missing_seqs, missing_filenames).

    Mirrors update-docs.sh:374-388: every work-item seq must appear as a
    ``| <seq> |`` row in the SEQUENCE-TRACKER text, and every document filename
    must appear somewhere in the DOCUMENT-INDEX text. Empty lists mean all good.
    """
    missing_seqs = [
        seq for seq in sorted(grouped.work_items) if f"| {seq} |" not in sequence_text
    ]
    missing_files = [
        rec.filename for rec in grouped.documents if rec.filename not in index_text
    ]
    return missing_seqs, missing_files


def find_docs_dir(start: Path | None = None) -> str:
    """Resolve the default docs directory, mirroring doc-utils.sh:find_docs_dir.

    Priority: PROJECT.yaml ``docs_dir`` under the project root, then
    ``<root>/docs``, then a walk up from ``start`` for any ``docs/`` directory.
    Falls back to ``"docs"`` (matching the bash ``|| echo "docs"``).
    """
    start = Path(start) if start is not None else Path.cwd()
    project_root = _project_root(start)

    pyaml = project_root / "PROJECT.yaml"
    if pyaml.is_file():
        configured = _read_docs_dir_from_yaml(pyaml)
        if configured and (project_root / configured).is_dir():
            return str(project_root / configured)

    if (project_root / "docs").is_dir():
        return str(project_root / "docs")

    search = start
    for _ in range(5):
        if (search / "docs").is_dir():
            return str(search / "docs")
        if search.parent == search:
            break
        search = search.parent

    return "docs"


def _project_root(start: Path) -> Path:
    """Find the project root: git toplevel, else nearest dir with .git/PROJECT.yaml."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
            cwd=start,
        )
        if result.returncode == 0 and result.stdout.strip():
            return Path(result.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass

    search = start
    for _ in range(5):
        if (search / "PROJECT.yaml").is_file() or (search / ".git").exists():
            return search
        if search.parent == search:
            break
        search = search.parent
    return start


def _read_docs_dir_from_yaml(pyaml: Path) -> str:
    """Extract a top-level ``docs_dir:`` value from PROJECT.yaml (stdlib-only)."""
    try:
        for line in pyaml.read_text(encoding="utf-8").splitlines():
            if line.startswith("docs_dir:"):
                value = line[len("docs_dir:"):]
                value = value.split("#", 1)[0].strip().strip("\"'")
                return value
    except OSError:
        return ""
    return ""


def run_pipeline(
    docs_dir: Path,
    branch_refs: list[str],
    ls_tree: LsTree,
    sequence_template: str,
    index_template: str,
    last_updated: str,
    timestamp: str,
    verify: VerifyFn | None = None,
) -> int:
    """Run RENDER + write + VERIFY with the backup/restore safety net.

    Mirrors update-docs.sh:34-55 and 369-396: clean stale backups, back up any
    existing outputs, write the freshly rendered files, then VERIFY. If VERIFY
    reports any missing work item or doc, restore both outputs from backup and
    report — but, like the bash, still exit 0. On success, remove the backups.
    """
    if verify is None:
        verify = verify_outputs

    docs_dir = Path(docs_dir)
    sequence_output = docs_dir / "SEQUENCE-TRACKER.md"
    index_output = docs_dir / "DOCUMENT-INDEX.md"

    # Clean up stale backups from previously failed runs (bash:35). Glob covers
    # both the current-run names (".SEQUENCE-TRACKER.md.backup") and any legacy
    # ".<name>.backup.<suffix>" form — the trailing ``*`` matches "" or a suffix.
    for stale in docs_dir.glob(".*.backup*"):
        if stale.is_file():
            stale.unlink()

    # Back up existing outputs for fast revert (bash:40-47).
    sequence_backup = docs_dir / ".SEQUENCE-TRACKER.md.backup"
    index_backup = docs_dir / ".DOCUMENT-INDEX.md.backup"
    has_sequence_backup = sequence_output.is_file()
    has_index_backup = index_output.is_file()
    if has_sequence_backup:
        sequence_backup.write_bytes(sequence_output.read_bytes())
    if has_index_backup:
        index_backup.write_bytes(index_output.read_bytes())

    grouped = process_documents(
        collect_candidates(docs_dir, branch_refs, ls_tree)
    )

    print(f"  Found: {len(grouped.work_items)} work items")
    active = sum(1 for i in grouped.work_items.values() if i.status == "active")
    on_hold = sum(1 for i in grouped.work_items.values() if i.status == "on-hold")
    completed = sum(1 for i in grouped.work_items.values() if i.status == "completed")
    active_docs = sum(1 for d in grouped.documents if d.status == "active")
    on_hold_docs = sum(1 for d in grouped.documents if d.status == "on-hold")
    completed_docs = sum(1 for d in grouped.documents if d.status == "completed")
    print(f"  Active: {active} work items ({active_docs} docs)")
    print(f"  On Hold: {on_hold} work items ({on_hold_docs} docs)")
    print(f"  Completed: {completed} work items ({completed_docs} docs)")

    sequence_text = render_sequence_tracker(grouped, sequence_template, last_updated)
    index_text = render_document_index(grouped, index_template, last_updated, timestamp)

    sequence_output.write_text(sequence_text, encoding="utf-8")
    index_output.write_text(index_text, encoding="utf-8")

    print("Verifying all work items are tracked...")
    missing_seqs, missing_files = verify(sequence_text, index_text, grouped)
    missing = len(missing_seqs) + len(missing_files)

    if missing == 0:
        print("✓ All documents verified")
    else:
        for seq in missing_seqs:
            print(f"  ⚠️  Missing from SEQUENCE-TRACKER: {seq}")
        for filename in missing_files:
            print(f"  ⚠️  Missing from DOCUMENT-INDEX: {filename}")
        print(f"⚠️  {missing} items could not be verified — restoring from backup")
        # Revert each output: restore prior content if we backed it up, else
        # remove the freshly-written (unverified) file so a failed first run
        # never leaves a corrupt output behind (mirrors bash restore/delete).
        if has_sequence_backup and sequence_backup.is_file():
            sequence_output.write_bytes(sequence_backup.read_bytes())
        elif sequence_output.is_file():
            sequence_output.unlink()
        if has_index_backup and index_backup.is_file():
            index_output.write_bytes(index_backup.read_bytes())
        elif index_output.is_file():
            index_output.unlink()

    # Remove backups on both paths (bash trap removes them when the run ends).
    if sequence_backup.is_file():
        sequence_backup.unlink()
    if index_backup.is_file():
        index_backup.unlink()

    if missing == 0:
        print("✓ SEQUENCE-TRACKER.md regenerated")
        print("✓ DOCUMENT-INDEX.md regenerated")
    else:
        print("Previous outputs restored — regeneration aborted.")
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the CLI surface, mirroring update-docs.sh:14-22 (``--docs-dir``)."""
    parser = argparse.ArgumentParser(
        description="Regenerate SEQUENCE-TRACKER.md and DOCUMENT-INDEX.md from a filesystem scan.",
    )
    parser.add_argument("--docs-dir", dest="docs_dir", default=None)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint — wire the real git surface into the full pipeline."""
    args = parse_args(argv)
    docs_dir = args.docs_dir or find_docs_dir()

    home = Path(os.path.expanduser("~"))
    sequence_template = (home / ".claude" / "templates" / "SEQUENCE-TRACKER.template.md").read_text(
        encoding="utf-8"
    )
    index_template = (home / ".claude" / "templates" / "DOCUMENT-INDEX.template.md").read_text(
        encoding="utf-8"
    )

    last_updated = datetime.now().strftime("%Y-%m-%d")
    timestamp = datetime.now().astimezone().isoformat(timespec="seconds")

    print("Regenerating documentation from filesystem scan...")
    return run_pipeline(
        docs_dir=Path(docs_dir),
        branch_refs=git_branch_refs(),
        ls_tree=git_ls_tree,
        sequence_template=sequence_template,
        index_template=index_template,
        last_updated=last_updated,
        timestamp=timestamp,
    )


if __name__ == "__main__":
    raise SystemExit(main())
