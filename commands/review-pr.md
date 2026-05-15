---
name: review-pr
description: AI-powered code review for GitHub/GitLab PRs/MRs with security scanning
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "review-pr" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "review-pr" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a senior code reviewer. The script collects PR data and runs security scans; you analyze and generate the review document.

## Execute

```bash
~/.claude/scripts/review-pr.sh --full --pr NUMBER
```

If no PR number known, omit `--pr` to list open PRs first.

Script automatically:
- Detects platform (GitHub/GitLab) from PROJECT.yaml or git remote
- Fetches PR metadata, commits, files, and diff
- Runs security scans (Trivy vulns + secrets, Semgrep SAST, gitleaks)
- Manual secret grep on diff
- Returns structured JSON with all data for analysis

## Response Handling

Based on `next_action`:

**`choose_pr`** — No PR specified; script returned list of open PRs
- Display PR list from `prs` array: `number: title (author: source -> target)`
- Ask user which PR to review
- Re-run: `~/.claude/scripts/review-pr.sh --json --full --pr NUMBER`

**`analyze_pr`** — Data collected; generate comprehensive review
- Score 7 categories (0-10): Minimal Changes, Security, Best Practices, Code Quality, Testing, Documentation, Git Hygiene
- Calculate weighted overall: Minimal(0.20) + Security(0.25) + Practices(0.20) + Quality(0.15) + Testing(0.10) + Docs(0.05) + Git(0.05)
- Security auto-scoring: 0 if secrets found, 0-2 critical vulns, 3-5 high, 6-8 medium, 9-10 clean
- Categorize issues: Critical (security/breaking), Major (practices/quality), Minor (style/docs)
- Write review document: `docs/code-reviews/YYYY-MM-DD-pr-NNN-title.md`
- Required sections: Summary, Scores table, Critical/Major/Minor Issues, Positive Highlights, File-by-File Review, Recommendations
- Signature: "Friendly AI Agent Assistant"
- Display: overall score, issue counts, critical blockers, document path

**`display_summary`** — Section completed (fetch-only or security-only)
- Show returned data summary

**`fix_error`** — Operation failed
- Common: auth not configured, project not in PROJECT.yaml, PR not found
- Check `message` and `details` for specifics

## Section Resumption

Re-run individual sections if needed:

```bash
# List open PRs only
~/.claude/scripts/review-pr.sh --list

# Fetch PR data only
~/.claude/scripts/review-pr.sh --fetch --pr NUMBER

# Security scans only
~/.claude/scripts/review-pr.sh --security --pr NUMBER
```

## Debugging

```bash
~/.claude/scripts/review-pr.sh --raw --full --pr NUMBER
```

## Important Notes

- **Model selection for review analysis**: default to `model: sonnet` for standard PRs (< 500 lines, single service). Escalate to `model: opus` when: PR touches security-sensitive code (auth, crypto, secrets), crosses 3+ services, or includes architectural changes (new services, schema migrations, API contract changes). The cost difference matters — sonnet reviews are ~5x cheaper.
- Be constructive, not critical — highlight good practices too
- Include file paths and line numbers for specific issues
- Only report findings with **confidence >= 80** — suppress low-confidence noise that wastes reviewer attention
- Score 0 on security if any secrets detected (critical blocker)
- Security scans are mandatory — always review results

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "review-pr" --event complete \
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
