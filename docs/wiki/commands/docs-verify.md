---
command: docs-verify
group: code-quality
backing_script: ~/.claude/scripts/docs-verify.sh
mutates: []
runtime: ~30-90s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /docs-verify

Compares recent code changes against documentation, identifies discrepancies, and updates docs to match current behavior. Also verifies that code examples in docs actually run. Use Opus for code-to-documentation analysis requiring deeper reasoning.

---

## When to use it

- After merging a feature that changed API behavior or function signatures
- Before releasing, to catch docs that describe old behavior
- When code examples in README or API docs have gone stale

## Usage

```bash
/docs-verify [path]
```

**Common invocations:**

```bash
/docs-verify                    # full project scan
/docs-verify src/auth.py        # scope to a specific file
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Optional file or directory path to limit the scope of analysis. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Determine which files changed recently | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `docs/*.md`, `README.md` — scanned for documentation to verify
- Inline docstrings — checked for presence on public APIs

## Backing script

**Script**: `~/.claude/scripts/docs-verify.sh`

**Inputs:** `--full [path]`, `--analyze`, `--verify`, `--test-examples`. Optional scope argument.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`analyze_and_update_docs`, `display_summary`, `fix_error`}
- `sections` — array of changed code files and their corresponding doc files
- `section` / error fields on `fix_error`

**Invocation surface:**

```bash
~/.claude/scripts/docs-verify.sh --full [path]          # full pipeline
~/.claude/scripts/docs-verify.sh --json --analyze       # identify changed files
~/.claude/scripts/docs-verify.sh --json --verify        # accuracy check
~/.claude/scripts/docs-verify.sh --json --test-examples # code example inventory
~/.claude/scripts/docs-verify.sh --raw --analyze        # debug
~/.claude/scripts/docs-verify.sh --raw --verify         # debug
```

## How it works

1. **Analyze** — script uses `git diff` to identify recently changed source files and maps them to candidate documentation files.
2. **Update** — LLM reads each changed source file and its paired docs. Identifies outdated descriptions, missing features, incorrect examples. Edits documentation using the Edit tool.
3. **Verify examples** — code examples in docs are exercised where possible (Python in Docker, TypeScript type-check, cURL against running service).
4. **Report** — summary of what was updated and any public APIs still missing docstrings.

## Example workflows

### Scenario: Post-merge doc sync

```
/git-merge feature/payment-retry main
/docs-verify
/git-commit "docs: sync payment retry documentation"
```

Run after a feature lands to keep docs in sync before the next release.

### Scenario: Discrepancy found and fixed

```
/docs-verify
```

```
Analyzing 3 changed files against 2 doc files…
  src/api/payments.py  ←→  docs/api/payments.md
    [outdated] retry_count parameter renamed to max_retries
    [missing]  new RateLimitError exception not documented
  Updating docs/api/payments.md…  done
  No stale examples found.
```

## Notes & gotchas

- The command reads git history to find recently changed files; it will find nothing meaningful in a brand-new repo with one commit.
- Examples are only executed where the runtime is available inside Docker — the command will note which examples were skipped.
- **If it fails during analyze:** run `~/.claude/scripts/docs-verify.sh --raw --analyze` to inspect the file-mapping output.
- **If it fails during verify:** run `~/.claude/scripts/docs-verify.sh --raw --verify` to see what the accuracy check returned.
