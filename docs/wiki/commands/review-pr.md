---
command: review-pr
group: git
backing_script: ~/.claude/scripts/review-pr.sh
mutates: [files]
runtime: ~30-120s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - git.platform
  - git.repo
requires_project_knowledge: none
project_knowledge_sections: []
---

# /review-pr

Fetches a PR or MR, runs Trivy, Semgrep, and gitleaks security scans on the
diff, then scores the change across seven categories and writes a structured
review document to `docs/code-reviews/`. Covers security, quality, testing,
minimal changes, and git hygiene in one pass.

> **Config:** PROJECT.yaml **optional** — reads `git.platform` and `git.repo`
> to select `gh` (GitHub) or `glab` (GitLab) and locate the correct remote.
> Falls back to auto-detection from the git remote URL when absent.

---

## When to use it

- You need a thorough review of a PR before merging — especially one touching
  auth, payments, or other sensitive paths
- You want a scored, written record of code quality for a task closeout
- A teammate asks for a second opinion and you want structured findings rather
  than inline comments

## Usage

```bash
/review-pr [PR-number]
```

**Common invocations:**

```bash
/review-pr           # list open PRs, then prompt for number
/review-pr 87        # review PR #87 directly
/review-pr 42        # any open PR by number
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `PR-number` | No | PR or MR number to review. If omitted, the script lists open PRs for selection. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Fetch diff and commits | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `gh` | Fetch PR data on GitHub | `brew install gh` — then `gh auth login` |
| `glab` | Fetch MR data on GitLab | `brew install glab` / `apt install glab` — then `glab auth login` |
| `trivy` | Vulnerability + secrets scan | `brew install trivy` / [trivy install docs](https://aquasecurity.github.io/trivy/) |
| `semgrep` | SAST scan | `pip install semgrep` |
| `gitleaks` | Secret detection in diff | `brew install gitleaks` |

Security tools (`trivy`, `semgrep`, `gitleaks`) are strongly recommended but
the script degrades gracefully if any are absent, reporting which scans were
skipped.

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Reads `git.platform` and `git.repo`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `docs/code-reviews/` — output directory; created if absent

## Backing script

**Script**: `~/.claude/scripts/review-pr.sh`

**Inputs:** `--full`, `--list`, `--fetch`, `--security`, `--pr <number>`.

**Outputs:** structured JSON on stdout with:

- `next_action` ∈ {`choose_pr`, `analyze_pr`, `display_summary`, `fix_error`}
- `prs` array (for `choose_pr`), `platform`, `pr_number`, `title`, `author`,
  `base_branch`, `source_branch`, `commits`, `files`, `diff`, security scan
  results (`trivy_vulns`, `secrets_found`, `semgrep_findings`,
  `gitleaks_findings`)

**Invocation surface:**

```bash
~/.claude/scripts/review-pr.sh --full --pr NUMBER      # fetch + scan + return data
~/.claude/scripts/review-pr.sh --list                  # list open PRs only
~/.claude/scripts/review-pr.sh --fetch --pr NUMBER     # fetch metadata only
~/.claude/scripts/review-pr.sh --security --pr NUMBER  # security scans only
~/.claude/scripts/review-pr.sh --raw --full --pr NUMBER  # debug
```

## How it works

1. **List / select** — if no PR number given, script returns the open PR list
   (`choose_pr`) and the LLM presents it for selection before re-running with
   `--pr NUMBER`.
2. **Fetch** — script pulls PR metadata, commit list, file list, and full diff
   from the platform API.
3. **Security scan** — Trivy scans for CVEs and leaked secrets; Semgrep runs
   SAST rules; gitleaks scans the diff for credentials; a manual grep checks
   for `password|secret|api[_-]?key|token` patterns. Results are bundled into
   the JSON.
4. **Analyze** — LLM scores seven categories (0–10): Minimal Changes (0.20
   weight), Security (0.25), Best Practices (0.20), Code Quality (0.15),
   Testing (0.10), Documentation (0.05), Git Hygiene (0.05). Security is
   auto-scored 0 if any secrets are detected. Issues are bucketed Critical /
   Major / Minor (only findings with ≥ 80% confidence are reported).
5. **Write document** — LLM writes
   `docs/code-reviews/YYYY-MM-DD-pr-NNN-<title>.md` with sections: Summary,
   Scores table, Critical / Major / Minor Issues, Positive Highlights,
   File-by-File Review, Recommendations. Signed "Friendly AI Agent Assistant".
6. **Display** — overall score, issue counts, critical blockers, and document
   path are printed to the terminal.

## Example workflows

### Scenario: Pre-merge security review

```
/review-pr 87        # review the PR
/git-merge feature/search main   # merge after review passes
```

Run before merging any PR that touches authentication or data access paths.

### Scenario: Review with output summary

```
/review-pr 42
```

```
Fetching PR #42: fix(auth): validate JWT expiry on refresh…
Running security scans… Trivy: 0 vulns | Semgrep: 2 findings | gitleaks: clean

Overall Score: 7.4 / 10
  Minimal Changes : 9  |  Security   : 8  |  Best Practices : 7
  Code Quality    : 7  |  Testing    : 6  |  Docs : 8  |  Git Hygiene : 9

Issues: 0 Critical  |  1 Major  |  3 Minor
Review written: docs/code-reviews/2026-05-16-pr-42-fix-auth-jwt-expiry.md
```

## Notes & gotchas

- **Model selection** — default to Sonnet for standard PRs (< 500 lines,
  single service). Escalate to Opus when the PR touches auth, crypto, or
  secrets; crosses 3+ services; or includes schema migrations or API contract
  changes. The cost difference is ~5x per review.
- **Security score is binary for secrets** — if any secret is detected by any
  scanner or the manual grep, the Security score is forced to 0 regardless of
  other findings. This is intentional and non-negotiable.
- **Only findings with ≥ 80% confidence are reported** — low-confidence noise
  is suppressed to keep the review actionable.
- **Output document is always written** — even if the overall score is high,
  the file is created. Move it to `docs/code-reviews/completed/` after the PR
  is merged.
- **If it fails (auth):** verify `gh auth status` (GitHub) or `glab auth
  status` (GitLab) and re-authenticate if needed.
- **If it fails (PR not found):** confirm the PR number and that PROJECT.yaml
  `git.repo` points to the correct repository.
- **If scans are skipped:** install missing tools (`trivy`, `semgrep`,
  `gitleaks`) — the script lists which were absent in the `fix_error` message.
- **Debug:** `~/.claude/scripts/review-pr.sh --raw --full --pr NUMBER` shows
  unformatted output for each stage.
- Work (macOS) uses `gh` against github.com; home (WSL) uses `glab` against
  the configured GitLab instance.
