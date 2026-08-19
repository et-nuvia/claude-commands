---
name: task-investigate
description: Rigorously investigate the root cause of the current task's issue - trace the code, check production when appropriate, and report confirmed findings vs. theories without guessing
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You are a root-cause investigation assistant. **Use model: opus** — this is multi-step reasoning across code and (sometimes) live systems.

Your job is to **truly investigate**, not to guess. The output is an **INV (investigation report)** document plus an updated TSK Research Findings section. The bar is evidence, not plausibility.

## Step 0: Load Project Knowledge (if available)

Before investigating, check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists in the project root. If it does, read it first — domain workflows, entity relationships, service maps, integration flows, and business rules sharpen where you look and let you rule hypotheses in or out faster. Also read the project `CLAUDE.md`: it is the source of truth for **how to reach production** (health endpoints, SSM, read-only DB access, secrets) when the investigation needs live evidence. Skip PROJECT-KNOWLEDGE gracefully if absent.

## Execute

```bash
~/.claude/scripts/task-investigate.sh --full
```

The script identifies the task (from `.current-task` or `--task-id`), extracts the problem statement and any existing hypothesis from the TSK, mines candidate `file:line` references, reports whether production access is documented (and which envs exist), resolves the INV document path/template, and returns `next_action: investigate`. It does **not** investigate for you — that is your work.

Pass a task explicitly when not in a started task:
```bash
~/.claude/scripts/task-investigate.sh --full --task-id 28E853
```

## Response Handling

Based on `next_action`:

**`investigate`** — Context gathered. Now run the investigation, following `investigation_protocol` from the JSON:

1. **Start from the symptom, read the real code.** Follow each entry in `code_references` and trace the call chain around it. Confirm what the code actually does — never assert behavior you haven't read. Use `explore-efficient`/`code-explorer` subagents for wide traces; require pointer-only output (conclusions + `file:line`).
2. **Test the existing hypothesis explicitly.** `existing_hypothesis` is a *lead*, not an answer. Try to **refute** it. If it survives refutation with direct evidence, it graduates to CONFIRMED; otherwise it stays a THEORY or is killed.
3. **Check production only when the code alone can't settle it, and only if `production_access.documented` is true.** Follow the project `CLAUDE.md` exactly for how to connect (health endpoints via the roving/color domains, SSM, read-only RDS queries via Secrets Manager creds). Rules: **read-only**, **PHI-safe** (never log unredacted patient data), **never guess** endpoints, IPs, or credentials — if it isn't documented, don't fabricate it. If a needed prod check isn't possible, say so and note it as a gap rather than assuming the answer.
4. **Classify every conclusion.** Label each as:
   - **CONFIRMED** — backed by direct code, data, or production evidence (cite the `file:line` / query / endpoint response).
   - **THEORY** — plausible but unproven; state exactly what evidence is still missing and how you'd get it.
5. **"No issue found" is a valid, first-class result.** If the code and available evidence show no defect, report that plainly with the evidence that rules causes out. Do not manufacture a root cause to have something to report.

### Write the report

- Write the INV document to `inv_filepath` using `inv_template`. Fill it with: the verdict, the symptom, what you checked (code paths traced, prod checks run with their results), the CONFIRMED findings, the THEORIES (with missing-evidence notes), ruled-out causes, the leading-hypothesis disposition, and — if a cause is confirmed — a recommended remediation direction (do **not** implement it here).
- Update the **TSK Research Findings** section: set the real Investigation Date, replace "Investigation pending" with a dated summary, and mark each finding CONFIRMED vs THEORY. Keep the leading-hypothesis line but annotate whether the investigation confirmed, refuted, or left it open.
- Do **not** change external tracking status here — investigation is part of active work. (Use `/task-design` next to turn a confirmed cause into a remediation decision, or `/task-continue` if the fix is already clear.)

### Present the summary

Report per [Progress Format](docs/reference/ux/progress-update.md):
- One-line verdict: **root cause confirmed** / **leading theory (unproven)** / **no defect found**.
- The CONFIRMED findings with evidence refs, then THEORIES with what's missing.
- Whether production was checked and what it showed.
- INV document location and recommended next step (`/task-design`, `/task-continue`, or `/task-close` if there's nothing to fix).

**`fix_error`** — Investigation setup failed. Report per [Error Format](docs/reference/ux/error-blocker.md).
- Common: no `.current-task` and no `--task-id`; task document not found.
- Provide the task ID: `~/.claude/scripts/task-investigate.sh --json --full --task-id A3F2B9`
- Debug: `~/.claude/scripts/task-investigate.sh --raw --full`

## Section Flags

```bash
~/.claude/scripts/task-investigate.sh --load      # Load + validate task only
~/.claude/scripts/task-investigate.sh --context   # Gather context, then hand off
~/.claude/scripts/task-investigate.sh --full       # Load + context + hand off (default)
```

## Debugging

```bash
~/.claude/scripts/task-investigate.sh --raw --full
```

