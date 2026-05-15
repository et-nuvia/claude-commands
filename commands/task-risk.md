---
name: task-risk
description: Analyze deployment risks and create V4 RSK document with comprehensive scoring
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-risk" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-risk" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a deployment risk analyst. Assess deployment risks and create a structured V4 RSK document.

**CRITICAL**: Use model: opus for all risk analysis.

## Execute

**Ask the user for the target environment using `AskUserQuestion` with a constrained choice list** (prevents typos — a bad env name would otherwise waste the analysis step):

```
AskUserQuestion(
  questions: [{
    header: "Env",
    question: "Which environment are you assessing risk for?",
    multiSelect: false,
    options: [
      { label: "staging", description: "Pre-prod deployment" },
      { label: "production", description: "Live production deployment" }
    ]
  }]
)
```

Then run:

```bash
~/.claude/scripts/task-risk.sh --validate --env <environment>
```

The `--validate` section runs FIRST (separately) and fails fast (< 1 second) if the environment is invalid, the working directory isn't a git repo, or the task ID can't be resolved. Only run `--full` after `--validate` passes:

```bash
~/.claude/scripts/task-risk.sh --full --env <environment>
```

Script automatically (after validation passes):
- Gathers git diff, commit log, previous RSK documents
- Identifies deployment window and version

## Response Handling

Based on `next_action`:

**`analyze_risk`** — LLM must perform risk analysis with Opus
- Use response fields: `git_diff`, `git_log`, `previous_analyses`, `deployment_window`
- Score 10 categories (0-10): Security (30%), Data Integrity (25%), Breaking Changes (15%), Database Migrations (10%), Rollback (10%), Code Changes (5%), Dependencies (2.5%), Configuration (2.5%), Performance (info), Testing (info)
- Overall = MAX(critical individual risks, weighted average)
- Create RSK document: `~/.claude/scripts/task-risk.sh --json --document --env $ENV`
- Response contains `template` (RSK template with placeholders replaced) and `document_path`. Fill the template with your risk analysis and write the completed document to `document_path` using the Write tool. Commit to git.

**`display_summary`** — Analysis complete
- Show risk score, recommendation (SAFE/READY/CAUTION/BLOCK)
- Show document path

**`fix_error`** — Analysis failed
- Common: not in git repo, environment not specified
- Debug: `~/.claude/scripts/task-risk.sh --raw --validate --env <environment>`

## Decision Matrix

- **0-3** SAFE: Deploy with confidence
- **4-6** READY: Deploy with monitoring
- **7-8** CAUTION: Deploy after mitigations
- **9-10** BLOCK: Do not deploy

## Debugging

```bash
~/.claude/scripts/task-risk.sh --raw --full --env <environment>
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-risk" --event complete \
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
