---
command: format
group: code-quality
backing_script: ~/.claude/scripts/format.sh
mutates: [files]
runtime: ~5-15s
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /format

Detects the project's configured formatter (Ruff, Prettier, Black, gofmt, rustfmt), runs it against the codebase, and reports which files changed. Leaves the working tree clean and consistently styled so every commit starts from a formatted baseline.

---

## When to use it

- Before committing to ensure the diff contains only meaningful changes
- After editing multiple files across a session where formatting drifted
- As a one-shot fix when a linter reports style violations

## Usage

```bash
/format
```

**Common invocations:**

```bash
/format                  # default: detect formatter and run --full
```

## Arguments

None — invoke with no input.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `ruff` | Python formatter/linter | `uv pip install ruff` inside container |
| `prettier` | JS/TS/CSS/JSON formatter | `npm install -g prettier` inside container |
| `black` | Python formatter (fallback) | `uv pip install black` inside container |
| `gofmt` | Go formatter | ships with Go toolchain |
| `rustfmt` | Rust formatter | ships with Rust toolchain |

Only the formatter present in the project is required. The script auto-detects which one to use.

**Project files consumed:**

- `PROJECT.yaml` (PY) — No (formatter is auto-detected from config files)
- `pyproject.toml` / `.prettierrc` / `rustfmt.toml` — optional; formatter reads its own config

## Backing script

**Script**: `~/.claude/scripts/format.sh`

**Inputs:** `--full`, `--detect`, `--format`, `--verify`. No env vars or PROJECT.yaml fields required.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`display_summary`, `fix_error`}
- `formatter` — name of the detected formatter
- `changes_detected` — boolean; true when files were modified
- `message` / `details` — populated on `fix_error`

**Invocation surface:**

```bash
~/.claude/scripts/format.sh --full        # detect + format + verify
~/.claude/scripts/format.sh --detect      # detect formatter only
~/.claude/scripts/format.sh --format      # run formatter only
~/.claude/scripts/format.sh --verify      # check for uncommitted changes only
~/.claude/scripts/format.sh --raw --full  # debug: bypass formatting
```

## How it works

1. **Detect** — script inspects config files (`pyproject.toml`, `.prettierrc`, `go.mod`, etc.) to identify the active formatter.
2. **Format** — runs the formatter against the project. Files are modified in place.
3. **Verify** — checks for uncommitted changes; reports which files were touched. Returns `display_summary` on success or `fix_error` if no formatter was found or a syntax error blocked formatting.

## Example workflows

### Scenario: Pre-commit cleanup

```
/format
/git-commit
```

Run formatting first so the commit diff contains only intentional changes.

### Scenario: Formatter detected and run

```
/format
```

```
Formatter: ruff
Changes detected: yes
  src/auth/session.py  reformatted
  src/api/users.py     reformatted
  2 files reformatted, 14 files unchanged
```

## Notes & gotchas

- Formatters must be installed inside the Docker container, not on the host.
- If the formatter is not configured, add `ruff format` to `pyproject.toml` (Python) or `.prettierrc` (JS/TS) first.
- **If it fails:** run `~/.claude/scripts/format.sh --raw --full` to see unformatted script output. If the formatter is missing from `PATH`, install it inside the running container.
