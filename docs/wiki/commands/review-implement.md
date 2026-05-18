---
command: review-implement
group: generators
backing_script: ~/.claude/scripts/review-implement.sh
mutates: [files]
runtime: ~30-120s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /review-implement

> Part of the [Auditing workflow](../08-workflows.md#auditing-scorecards).

Parses a structured document — code review (CRV), implementation plan (PLN),
implementation guide (IMP), or task (TSK) — extracts every actionable item,
presents an implementation plan for your approval, then applies the approved
changes to source files. At the end the identified issues or tasks are
addressed, tests pass, and changes are committed.

---

## When to use it

- You received a code review (CRV doc) and want to work through all the
  findings without manually hunting each one
- A PLN or IMP document defines the implementation steps and you want
  automated execution rather than manual coordination
- After `/task-code-review` produces a CRV and you're ready to action it

## Usage

```bash
/review-implement [path/to/document.md]
```

**Common invocations:**

```bash
/review-implement                                          # search for recent CRV/PLN/IMP/TSK docs
/review-implement docs/active/TSK-001-CRV-review.md       # explicit document path
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Path to the document to implement. When omitted the command searches `~/.claude/docs/active/` for recent CRV, PLN, IMP, and TSK files and asks you to select one. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `find` | Locate recent documents when no path is provided | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `make` | Run tests after each change group (`make test`) | `brew install make` / `apt install make` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No. Document path and content are the only inputs.
- The document file (`CRV`, `PLN`, `IMP`, or `TSK`) — read and parsed by the script
- Source files referenced in the document — edited by the LLM using Edit/Write tools

## Backing script

**Script**: `~/.claude/scripts/review-implement.sh`

**Inputs:** `--full --document <path>`, or stage flags with `--document <path>`.
Reads only the document file; no PROJECT.yaml dependency.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`implement_changes`, `display_summary`, `fix_error`}
- `parsed_data.items[]` — structured list of actionable items extracted from the
  document, each with `id`, `description`, `priority`, `file_hint` (when present)
- `parsed_data.document_type` — detected type (`CRV`, `PLN`, `IMP`, `TSK`)
- `parsed_data.context` — summary of the document's stated goal / scope

**Invocation surface:**

```bash
~/.claude/scripts/review-implement.sh --full --document path/to/doc.md      # parse + implement
~/.claude/scripts/review-implement.sh --validate --document path/to/doc.md  # check file readable
~/.claude/scripts/review-implement.sh --parse --document path/to/doc.md     # parse only
~/.claude/scripts/review-implement.sh --raw --full --document path/to/doc.md  # debug
~/.claude/scripts/review-implement.sh --raw --parse --document path/to/doc.md
```

## How it works

1. **Find document** — if no path is provided, LLM runs `find` against
   `~/.claude/docs/active/` for recent CRV/PLN/IMP/TSK files, presents the
   list, and asks the user to select one.
2. **Parse** — script validates the file is readable and extracts structured
   items: each finding or task becomes an entry in `parsed_data.items[]` with
   an id, description, priority, and optional file hint.
3. **Plan presentation** — LLM reads the full document for context, then
   presents an implementation plan table showing every item and asks the user
   to choose: implement all, select specific items, or cancel.
4. **Implement** — for each approved item, LLM applies changes using Edit/Write
   tools. After each logical group (e.g., all security findings, or one PLN
   phase), runs `make test` to confirm nothing broke.
5. **Commit** — changes are committed in conventional commit format referencing
   the document ID (e.g., `fix(auth): address CRV-001 null session finding`).
   Uses **Opus** for the planning step to ensure accurate extraction from
   complex documents.
6. **Report** — summarizes items implemented, items skipped (with reasons),
   and test results.

## Example workflows

### Scenario: Acting on a code review

```
/task-code-review           # produces CRV document
/review-implement           # find CRV, implement findings
/git-commit                 # split into per-finding commits
/create-pr                  # open PR referencing the review
```

Standard post-review workflow. The CRV doc stays in `docs/active/` and serves
as the implementation checklist.

### Scenario: Implementation plan execution with output

```
/review-implement docs/active/TSK-042-PLN-auth-refactor.md
```

```
Document: TSK-042-PLN-auth-refactor.md (PLN)
Scope: Refactor JWT session handling across auth and API layers

Implementation Plan
  ┌────┬────────────────────────────────────────┬──────────┬──────────────────────┐
  │ #  │ Task                                   │ Priority │ Files                │
  ├────┼────────────────────────────────────────┼──────────┼──────────────────────┤
  │  1 │ Extract token validation to middleware │ P0       │ auth/middleware.py    │
  │  2 │ Remove inline JWT decode in /me route  │ P0       │ api/routes/users.py  │
  │  3 │ Add expiry check to refresh endpoint   │ P1       │ api/routes/auth.py   │
  │  4 │ Update tests for new middleware shape  │ P1       │ tests/test_auth.py   │
  └────┴────────────────────────────────────────┴──────────┴──────────────────────┘

Implement all 4 items? [All / Select / Cancel]
```

## Notes & gotchas

- Uses **Opus** for the planning step — the cost is intentional. Extraction
  accuracy from complex CRV/PLN documents degrades noticeably with Sonnet for
  multi-section documents with cross-references.
- Items are presented for approval before any file is touched. If you cancel
  after seeing the plan, no changes have been made.
- Test runs happen after each logical group, not after every individual edit.
  If a group of changes is large, a single failing test will block the
  remainder of that group until fixed.
- **If it fails (document not found):** verify the path with `ls` — the command
  does not search recursively outside `~/.claude/docs/active/` when auto-searching.
- **If it fails (parse error):** document may lack standard V4 structure.
  Debug with `~/.claude/scripts/review-implement.sh --raw --parse --document
  path/to/doc.md` to see what the parser extracted.
- **If tests fail mid-implementation:** the LLM will attempt one fix pass per
  failing group. After 3 failed retries, it reports the blocker and asks for
  user input rather than continuing blindly.
