---
name: git-history-scrub
description: Remove leaked secrets from git history (gitleaks scan, classify, filter-repo rewrite, gated force-push)
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You orchestrate a git history scrub: gitleaks finds secrets in history, you classify
them (real leak vs placeholder), git-filter-repo rewrites history in an isolated
mirror clone, and the force-push only happens after explicit user approval and
confirmed secret rotation.

## Execute

```bash
RESULT=$(~/.claude/scripts/git-history-scrub.sh --json --scan)
```

Script automatically:
- Verifies gitleaks, git-filter-repo, and jq are installed
- Scans the FULL git history (all branches) with the repo's `.gitleaks.toml` if present
- Dedupes findings into distinct secrets and checks whether each is still live in HEAD
- Stores all state in `<git-dir>/history-scrub/` (never committed, secrets chmod 600)

## Response Handling

Based on `next_action`:

**`parse_content`** — Findings need classification
- Review each entry in `distinct_secrets`: the secret value, rule, files, and `live_in_head`
- Classify each as `scrub` (real credential) or `allowlist` (placeholder/example like `YOUR_API_KEY`)
- When ambiguous (e.g., a client-side Google Maps key that is public by design), use AskUserQuestion — never guess on a real credential
- Write the decisions file at `decisions_path`: `[{"id": N, "action": "scrub", "rotated": false, "note": "..."}, {"id": M, "action": "allowlist", "note": "..."}]`
- For every `allowlist` decision, add a tightly scoped entry (path + secret regex) to the repo's `.gitleaks.toml`
- Then run `--plan`

**`fix_error` with live secrets** — Scrub-marked secrets still exist in current code
- Remediate first: move them to the secrets manager per project standards, commit, push
- Re-run `--scan` then `--plan`

**`confirm_action` after `--plan`** — Rewrite is prepared
- Show the user: scrub count, allowlist entries, and which secrets still need rotation
- Walk the user through rotating each scrubbed secret (suggest /rotate-secret), then set `"rotated": true` in decisions.json
- Run `--rewrite` (safe: works in a temp mirror clone, creates a backup bundle, verifies the result is gitleaks-clean; pushes nothing)

**`confirm_action` after `--rewrite`** — Verified clean, awaiting push approval
- Present to the user: refs to push, backup bundle path, any unpushed local branches (these will NOT be rewritten)
- This is the manual gate. Only after the user explicitly approves, run `--push --confirm`
- The push is blocked if any scrubbed secret has `rotated != true`

**`display_summary` after `--push`** — Done
- Relay the post-push checklist verbatim: hard-reset/re-clone all local copies and worktrees, rebase unpushed branches via the commit map, contact GitHub Support to purge cached views, add gitleaks to CI (see `pipeline-security.sh --scanners gitleaks`) to prevent recurrence

## Section Flags

```bash
~/.claude/scripts/git-history-scrub.sh --json --scan      # Scan history, dedupe secrets
~/.claude/scripts/git-history-scrub.sh --json --plan      # Validate decisions, build replacements
~/.claude/scripts/git-history-scrub.sh --json --rewrite   # Mirror clone + filter-repo + verify (no push)
~/.claude/scripts/git-history-scrub.sh --json --push --confirm  # Force-push (rotation-gated)
~/.claude/scripts/git-history-scrub.sh --json --status    # Where am I in the workflow?
```

## Debugging

```bash
~/.claude/scripts/git-history-scrub.sh --raw --scan
```
