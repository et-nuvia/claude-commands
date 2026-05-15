---
name: plan-mitigate-risks
description: Plan and implement deployment risk mitigations
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "plan-mitigate-risks" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "plan-mitigate-risks" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Take a deployment risk analysis document and implement mitigations to reduce deployment risk. Use model: opus for planning.

## Execute

```bash
~/.claude/scripts/plan-mitigate-risks.sh --full
```

Or with a specific file:

```bash
~/.claude/scripts/plan-mitigate-risks.sh --full --file docs/deployment-risks/2026-03-20-staging-1.2.3.md
```

## Response Handling

Based on `next_action`:

**`select_risks`** — Multiple risk documents found
- Present `available_docs` list to user with dates and filenames
- Ask which document to use
- Re-run: `~/.claude/scripts/plan-mitigate-risks.sh --json --full --file <selected_path>`

**`plan_mitigations`** — Risk document parsed, ready for Opus planning
- Read `doc_content` from the response — contains the full RSK document
- Extract each risk with: ID, title, category, severity, score, description, mitigation options
- Present risks grouped by severity (Critical 9-10, High 7-8, Medium 4-6, Low 1-3)
- Ask user which risks to mitigate:
  1. All Critical + High (recommended)
  2. All Critical + High + Medium (safest)
  3. Custom selection
- For each selected risk, present mitigation options from the document:
  - Approach name, effort estimate, effectiveness (eliminates/reduces/monitors), trade-offs
  - Let user choose or describe custom approach
- Build implementation plan:
  - Steps with specific file changes per mitigation
  - Tests to add
  - Effort estimate
  - New risk score (eliminates → 0-1, reduces → 30-50% of original, monitors → 70-90%)
- Show before/after comparison and recalculated overall score
- Order by dependency and effort (quick wins first)
- Confirm with user before starting

**Execute mitigations:**
```bash
git checkout -b mitigate/deployment-risks-YYYY-MM-DD
```

For each mitigation in order:
1. Implement changes
2. Run tests
3. Commit atomically: `fix(risk-RID): [mitigation description]`

After all mitigations:
- Re-run: `~/.claude/scripts/deploy-risk.sh --json --gather --environment <env>` to verify score reduction
- Push branch for review

**`fix_error`** — Script error
- Common: no risk documents found (run `/deploy-risk` first)
- Debug: `~/.claude/scripts/plan-mitigate-risks.sh --raw --full`
- Report per [Error Format](docs/reference/ux/error-blocker.md)

## Section Flags

```bash
~/.claude/scripts/plan-mitigate-risks.sh --identify                    # Find RSK documents
~/.claude/scripts/plan-mitigate-risks.sh --parse --file path/to/rsk.md # Parse specific document
```

## Rules

- One commit per mitigation (atomic, revertable)
- Don't skip critical or high risks without explicit user confirmation
- If a mitigation introduces a new risk, compare old vs new and document the trade-off
- If a risk cannot be mitigated, document why and create a monitoring/runbook plan instead
- Re-analyze after implementation to confirm actual score reduction

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "plan-mitigate-risks" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
