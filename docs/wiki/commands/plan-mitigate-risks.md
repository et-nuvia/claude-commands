---
command: plan-mitigate-risks
group: outlier
backing_script: ~/.claude/scripts/plan-mitigate-risks.sh
mutates: [git, files]
runtime: ~10–30m
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /plan-mitigate-risks

Takes an existing RSK (deployment risk) document, guides you through selecting
which risks to address, builds an ordered implementation plan with per-risk
mitigation choices, then executes the changes atomically — one commit per
mitigation — on a dedicated branch. After all changes land, the command
re-runs `deploy-risk` to confirm the overall risk score has actually dropped.

---

## When to use it

- You have an RSK document from `/deploy-risk` and want to act on it before a deploy
- You want an interactive triage session that lets you pick which risks to fix and how
- A deployment was blocked or flagged and you need a structured remediation branch

## Usage

```bash
/plan-mitigate-risks [--file <path-to-rsk.md>]
```

**Common invocations:**

```bash
/plan-mitigate-risks                                                    # auto-discover the latest RSK doc
/plan-mitigate-risks --file docs/deployment-risks/2026-03-20-staging-1.2.3.md  # target a specific file
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--file <path>` | No | Path to the RSK document to process. When omitted the script searches `docs/deployment-risks/` and prompts you to pick if more than one is found. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Creates the mitigation branch and commits each change | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- RSK document (e.g., `docs/deployment-risks/<date>-<env>-<version>.md`) — required; created by `/deploy-risk`

## Backing script

**Script**: `~/.claude/scripts/plan-mitigate-risks.sh`

**Inputs:** Optional `--file <path>` to target a specific RSK document. Without it the script scans `docs/deployment-risks/` for RSK files.

**Outputs:** Structured JSON on stdout with:

- `next_action` ∈ {`select_risks`, `plan_mitigations`, `fix_error`}
- On `select_risks`: `available_docs[]` — list of found RSK files with dates and filenames
- On `plan_mitigations`: `doc_content` — full parsed RSK document text for the LLM to extract risks from
- On `fix_error`: error description and suggested recovery steps

**Invocation surface:**

```bash
~/.claude/scripts/plan-mitigate-risks.sh --full                         # main entry; auto-selects or prompts
~/.claude/scripts/plan-mitigate-risks.sh --full --file path/to/rsk.md  # target a specific document
~/.claude/scripts/plan-mitigate-risks.sh --identify                     # find RSK documents only
~/.claude/scripts/plan-mitigate-risks.sh --parse --file path/to/rsk.md # parse document only
~/.claude/scripts/plan-mitigate-risks.sh --raw --full                   # debug: bypass output formatting
```

## How it works

1. **Discover RSK document** — the script scans for RSK files. If exactly one is found it is used automatically. If multiple are found the LLM presents `available_docs` and asks the user to pick; the script is re-run with `--file` pointing to the chosen path.

2. **Parse and present risks** — the LLM reads `doc_content` and extracts every risk: ID, title, category, severity (Critical 9–10, High 7–8, Medium 4–6, Low 1–3), score, description, and available mitigation options. Risks are grouped by severity and displayed in a summary table.

3. **User selects scope** — the LLM offers three presets: (a) Critical + High only (recommended), (b) Critical + High + Medium (safest), or (c) custom selection. The user picks a preset or names specific risk IDs.

4. **Choose mitigation approach** — for each selected risk the LLM presents the options from the RSK doc (approach name, effort, effectiveness, trade-offs) and lets the user choose or describe a custom approach.

5. **Build implementation plan** — the LLM assembles an ordered plan: specific file changes per mitigation, tests to add, estimated effort, and recalculated risk scores (eliminates → 0–1; reduces → 30–50% of original; monitors → 70–90%). A before/after comparison is shown. Quick wins come first; higher-effort items follow.

6. **User confirms** — the plan is presented for approval before any code changes begin.

7. **Execute on a dedicated branch** — the LLM checks out `mitigate/deployment-risks-YYYY-MM-DD` and implements each mitigation in order: make the change, run tests, commit with `fix(risk-RID): <description>`. Each mitigation is an atomic, independently revertable commit.

8. **Verify score reduction** — after all mitigations are applied the LLM re-runs `~/.claude/scripts/deploy-risk.sh --json --gather --environment <env>` to produce a fresh risk score. The before/after delta is shown to confirm the work had the intended effect.

9. **Push for review** — the branch is pushed and the user is prompted to open a PR.

## Example workflows

### Scenario: Full deploy-risk → mitigate chain

```
/deploy-risk             # analyze and score; writes the RSK document
/plan-mitigate-risks     # immediately act on the RSK document just produced
/create-pr               # open PR for the mitigation branch
/deploy-to-stage         # re-deploy once mitigations are merged
```

Use this chain when a staging deploy is blocked by risk score or when you
want to reduce risk before opening a production promotion PR.

### Scenario: Mitigation session with output

```
/plan-mitigate-risks
```

```
Found 1 RSK document: docs/deployment-risks/2026-05-14-staging-1.4.0.md

Risks by severity:
  [Critical 9.2]  RID-01  No database migration rollback path
  [High 7.5]      RID-02  Missing circuit breaker on payment API
  [Medium 4.1]    RID-03  Healthcheck timeout too aggressive

Scope: mitigate Critical + High (recommended)? [Y/n] Y

RID-01 — mitigation options:
  A. Add explicit DOWN migration  (effort: 30 min, eliminates risk)
  B. Add manual rollback runbook  (effort: 10 min, monitors risk)
Choose approach: A

RID-02 — mitigation options:
  A. Add resilience4j circuit breaker  (effort: 2h, eliminates risk)
  B. Add retry with exponential backoff (effort: 45 min, reduces risk)
Choose approach: B

Plan confirmed. Creating branch: mitigate/deployment-risks-2026-05-16
  [1/2] fix(risk-RID-01): add DOWN migration for schema change … ✓
  [2/2] fix(risk-RID-02): add retry with backoff on payment API … ✓

Re-scoring … Overall risk: 9.2 → 3.1  ✓
Branch pushed. Open PR to merge mitigations before deploy.
```

## Notes & gotchas

- This command uses **opus** for planning — expect longer response times during the plan-building phase. The investment is intentional: opus produces more accurate effort estimates and catches inter-mitigation dependencies.
- Each mitigation lands as its own commit (`fix(risk-RID): …`). This is by design — if one mitigation causes a regression it can be reverted without rolling back the others.
- If a risk genuinely cannot be mitigated, the command documents the reason inline and produces a monitoring or runbook recommendation instead of skipping the risk silently.
- If a new mitigation would itself introduce a risk, the LLM surfaces the trade-off and asks for confirmation before proceeding.
- The mitigation branch is named `mitigate/deployment-risks-YYYY-MM-DD`. If that branch already exists (same-day re-run) the command will error — delete or rename the existing branch first.
- **If it fails:** `fix_error` with "no risk documents found" means `/deploy-risk` has not been run yet or the RSK file is in a non-standard location. Run `/deploy-risk` first, or pass `--file` explicitly. To debug script failures: `~/.claude/scripts/plan-mitigate-risks.sh --raw --full`
