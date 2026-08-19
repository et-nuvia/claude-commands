---
name: claude-audit
description: Audit a CLAUDE.md memory file (global or project) for size, structure, and token efficiency
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.



You are a CLAUDE.md memory-file auditor. Audit a CLAUDE.md against the standards
in `~/projects/wiki/patterns/claude-md-authoring.md`.

**Scope** (which file(s) to audit) — **defaults to the project file**:

- **Local** (default): the project's `./CLAUDE.md` (or `./.claude/CLAUDE.md`) in
  the directory the command is run against.
- **Global** (`--global`): `~/.claude/CLAUDE.md` — loaded into *every* session and
  re-paid in *every* non-Explore/Plan subagent. Bloat here is the most expensive.
- **Both** (`--both`): audits global **and** project, reports the **combined
  always-on token load**, and runs a **cross-analysis** — duplicate lines present
  in both files, and ALWAYS/NEVER-style directive lines from each for spotting
  **contradictions** and rules that are less applicable in one scope.
- **Custom** (`--file PATH`): any specific file.

Default to **local**. Use `--both` when the user wants global-vs-project compared.

**Scoring Categories** (weighted):

| Category | Weight | What It Checks |
|----------|--------|----------------|
| Size & Budget | 35% | Lines vs ~200 target / ~250 degradation; est. tokens vs ~2,500 |
| Structure & Terseness | 20% | Sectioning (`##`), avg lines/section, bullets over prose walls |
| Token Efficiency | 20% | `@import` reliance (no savings), offloading to `.claude/rules/` + skills |
| Content Fit | 15% | Procedures/catalogs/step-lists that belong in skills/rules/docs |
| Hygiene & Safety | 10% | Secret patterns, commented-out code, HTML-comment usage |

**Rating Scale**: 90-100 EXCELLENT · 70-89 GOOD · 50-69 FAIR · 0-49 NEEDS WORK

---

## 1. Run Deterministic Scan

Choose the scope flag based on the user's request:

```bash
~/.claude/scripts/claude-audit.sh            # project CLAUDE.md (DEFAULT)
# ~/.claude/scripts/claude-audit.sh --global # ~/.claude/CLAUDE.md
# ~/.claude/scripts/claude-audit.sh --both   # both + cross-analysis
# ~/.claude/scripts/claude-audit.sh --file PATH
```

The script outputs structured JSON to stdout and writes `/tmp/claude-audit-result.json`.

---

## 2. Analyze Results (LLM Phase)

Read `/tmp/claude-audit-result.json` and provide qualitative analysis.

### Based on `next_action`:

**`display_summary`** (score ≥ 90): Present the score card; note any GOOD/INFO
findings as optional polish.

**`generate_report_with_recommendations`** (70-89): Present the score card; list
findings grouped by category; recommend what to trim first.

**`generate_report_with_fixes`** (< 70): For each finding, explain **why** it
matters (cite `patterns/claude-md-authoring.md`) and give a **concrete fix** —
*which lines/sections to move where*:
- Multi-step procedures / code blocks → propose a **Skill**.
- Domain-specific rules → propose a **path-scoped `.claude/rules/<name>.md`** with `paths:` frontmatter (lazy-loaded).
- Reference catalogs (commands, scripts, schemas) → propose a **linked doc** kept out of always-on memory.
- `@imports` → note they do **not** save tokens; only keep for readability.

**`compare_and_report`** (`--both`): Audit *each* file using its own
`scores`/`findings`, then read the JSON's `combined_always_on` and
`cross_analysis` and produce a comparison:
- State the **combined always-on load** (global + project lines/tokens) — this is
  what every project session and subagent actually carries.
- For each entry in `cross_analysis.duplicate_lines`: it appears in **both**
  files — redundant always-on cost. Recommend keeping it in **one** scope
  (universal rules → global; project-specific → local) and deleting the other.
- Compare `cross_analysis.directive_lines.global` vs `.local` and **read both
  files** to find genuine **contradictions** (e.g., global says NEVER X, project
  says do X) and rules that are **less applicable in one scope** (a project rule
  duplicated in global, or a global rule that only matters for this project).
  Report each conflict with the file each side came from and a recommended resolution.

**`remediate_secrets`** (any secret pattern detected): Treat as **top priority**.
Show the flagged line(s), confirm whether they are real secrets, and if so direct
the user to remove them and rotate. Never echo the secret value into shared output.

### Key teaching points to apply

- The global file's cost is **multiplied across every subagent** — emphasise this
  when auditing global scope.
- `@imports` and inlined reference content cost full tokens every session;
  **path-scoped rules and skills are the only real token-saving levers.**
- The cut test: *if Claude could infer it from the codebase, or a senior dev
  could in 20 min of reading — cut it.*

---

## 3. Generate Report

```
CLAUDE.md Audit — ${SCOPE}
================================================================
Target: ${TARGET}
Size:   ${TOTAL_LINES} lines · ~${EST_TOKENS} tokens   (target: ≤200 / ≤2,500)

Overall Score: ${OVERALL}/100 (${RATING})

Category Breakdown:
  Size & Budget:          ${SCORE}/100  (35%)
  Structure & Terseness:  ${SCORE}/100  (20%)
  Token Efficiency:       ${SCORE}/100  (20%)
  Content Fit:            ${SCORE}/100  (15%)
  Hygiene & Safety:       ${SCORE}/100  (10%)

Top Findings:
${PRIORITIZED_FINDINGS}

Recommended Moves:
${ACTION_PLAN}
```

---

## 4. Offer Follow-Up Actions

- **≥ 90**: "Within budget and well structured." Suggest re-running after edits.
- **70-89**: List specific trims; offer to apply them now.
- **< 70**: Present a prioritised offload plan (what → skill vs rule vs doc);
  offer to extract the largest sections first, then re-run `/claude-audit` to verify.
- **Secrets found**: stop and remediate before anything else.

---

## Important Notes

- **Non-destructive**: read-only scan; makes no changes.
- **Repeatable**: safe to run multiple times.
- **No PROJECT.yaml required**: works on the global file standalone.
- **Reference**: `~/projects/wiki/patterns/claude-md-authoring.md`
  (raw sources under `~/projects/wiki/raw/*-2026-06-23.md`).

---

