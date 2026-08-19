---
name: migration-timestamps
description: How to generate database migration timestamps with ~/.claude/scripts/migration-timestamp.sh, and why hand-picked round numbers break ordering across branches. Load when creating, renaming, or auditing a database migration file.
---

# Migration Timestamps

**NEVER hand-pick a migration timestamp.** Round numbers (`1756800000000`) put concurrent branches out of order: whichever merges second carries a timestamp *below* an already-applied migration, so a fresh database and an existing one apply them in different relative orders. Two branches can also pick the same value — one project in this fleet accumulated **10 duplicate timestamps** from exactly this.

Always generate a real epoch-ms value:

```bash
~/.claude/scripts/migration-timestamp.sh --now                     # 1785359302000
~/.claude/scripts/migration-timestamp.sh --name AddUserPreferences # filename + class name
~/.claude/scripts/migration-timestamp.sh --rename <file>           # re-stamp an UNAPPLIED migration
~/.claude/scripts/migration-timestamp.sh --verify                  # audit a migrations dir
```

## Why the script instead of `date`

- **`date +%s%3N` is a GNU-ism and silently breaks on macOS** — BSD `date` has no `%N`, so it emits `17853592873N` (a literal trailing `N`), producing a garbage timestamp that looks plausible. The script probes `gdate`/`date`/`python3`/`perl`/`node` and never emits a value it hasn't validated as all-digits, so it behaves identically on macOS and WSL/Debian.

## `--rename` safety

`--rename` renames the file, its `.spec.ts` sibling, the exported class, the `name` property, and all internal references, preferring `git mv`. **Only ever re-stamp a migration that has NOT been applied anywhere** — renaming changes the class name, so an applied migration would re-run.

## `--verify` output classes

`--verify` distinguishes **issues** (duplicates, future, pre-2020, unparseable → exit 3) from **advisories** (historical hand-picked timestamps → reported as an aggregate count, never fails). Rewriting applied migrations is unsafe, so legacy round numbers are informational only.

**See**: [Wiki: migration-timestamps](~/projects/wiki/patterns/migration-timestamps.md)
