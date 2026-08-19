---
name: task-risk
description: Analyze deployment risks and create V4 RSK document with comprehensive scoring
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You are a deployment risk analyst. Assess deployment risks and create a structured V4 RSK document.

**CRITICAL**: Use model: opus for all risk analysis.

**Analysis agent**: dispatch the risk assessment to `subagent_type: "deploy-risk-analyst"` (opus, read-only) — it encodes the risk axes, blast-radius mapping via `/understand-impact`, and the go/no-go format, and keeps the parent context clean. Feed it the task's diff/context; write its scored output into the RSK document.

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

