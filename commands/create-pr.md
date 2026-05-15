---
name: create-pr
description: Create well-formatted Pull Request with comprehensive description
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "create-pr" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "create-pr" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a PR creation assistant. The script handles git operations; you generate the PR description and create the PR.

## Execute

```bash
~/.claude/scripts/create-pr.sh --full
```

Script automatically:
- Detects platform (GitHub/GitLab) from PROJECT.yaml or git remote
- Identifies current branch, base branch, and issue number
- Analyzes commits, diff stats, and file changes
- Pushes branch to remote with `-u` flag
- If pre-push hooks mutate tracked files (eslint --fix, prettier, etc.),
  auto-commits those changes as `chore: apply pre-push hook fixes` and
  re-pushes so the PR includes them (max 2 retry cycles)
- Returns structured JSON with all data for description generation

## Response Handling

Based on `next_action`:

**`generate_description`** — Script returned commit data; generate PR and create it
- Analyze `commits`, `files`, `diff_stat` from response to understand changes
- Generate conventional commit title (< 70 chars): `type(scope): description`
- Generate comprehensive PR body with: Summary, Changes (Added/Changed/Fixed/Removed), Testing, Deployment Notes
- Only include sections relevant to actual changes
- Run security grep on diff: `git diff origin/<base>...HEAD | grep -iE "(password|secret|api[_-]?key|token)" | grep -v test`
- Create PR using platform from response:
  - GitHub: `gh pr create --title "..." --body "$(cat <<'EOF' ... EOF)" --base <base_branch>`
  - GitLab: `git push -o merge_request.create -o merge_request.title="..." -o merge_request.target=<base>`
- Display: PR URL, stats (commits, files, lines), linked issues

**`display_summary`** — Section completed (analyze-only or push-only)
- Show returned data summary
- Suggest next step if partial run

**`fix_error`** — Operation failed
- Common: not on branch, push failed, platform detection failed
- Check `message` and `details` for specifics

## Section Resumption

Re-run individual sections if needed:

```bash
# Analyze only (no push)
~/.claude/scripts/create-pr.sh --analyze

# Push only
~/.claude/scripts/create-pr.sh --push

# Custom base branch
~/.claude/scripts/create-pr.sh --full --base develop
```

## Debugging

```bash
~/.claude/scripts/create-pr.sh --raw --full
```

## Important Notes

- No AI attribution in PR body or commits (per CLAUDE.md)
- Keep title in imperative mood: "add" not "adds" or "added"
- Include `Closes #N` in body if issue detected
- Adapt description sections to actual changes (skip empty sections)
- If project has PR template (`.github/pull_request_template.md`), use it

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "create-pr" --event complete \
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
