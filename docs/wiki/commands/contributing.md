---
command: contributing
group: outlier
backing_script: ~/.claude/scripts/contributing.sh
mutates: [git, github, gitlab]
runtime: ~30-90s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /contributing

Analyzes the current project context, auto-detects the git platform (GitHub or
GitLab) and project standards, determines the best contribution strategy, then
executes it: running pre-flight checks, staging and committing changes with
conventional commit messages, searching for related issues, and opening a
pull or merge request. Designed for contributing to open-source or shared
projects where you may not own the workflow setup.

---

## When to use it

- You have changes ready in a third-party or open-source repo and want a clean commit + PR without hand-writing everything
- You want Claude to read the project's CONTRIBUTING.md and apply its conventions automatically
- You're in an unfamiliar repo and want the right contribution strategy surfaced before acting

## Usage

```bash
/contributing
```

**Common invocations:**

```bash
/contributing                      # full run: analyze + commit + PR
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form hint (e.g., "squash into one commit"). Passed to the planning phase. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Inspect working tree, push branch | preinstalled |
| `gh` *(GitHub)* | Create PR, search related issues | `brew install gh` (then `gh auth login`) |
| `glab` *(GitLab)* | Create MR, search related issues | install per platform |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No (strategy is inferred from the repo, not from PROJECT.yaml)
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `CONTRIBUTING.md` in the repo root — optional; read when the platform is GitHub and a contribution strategy is being determined
- `~/.config/gh/` or `~/.gitlab-token` — auth credentials for the detected platform

## Backing script

**Script**: `~/.claude/scripts/contributing.sh`

**Inputs:** `--full` (default), `--context`, `--standards`, or `--strategy`.
No other flags required.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`execute_contribution_strategy`, `fix_error`}
- `data.strategy.recommended_strategy` ∈ {`commit_changes`, `create_pr`, `up_to_date`}
- `data.platform` — detected `github` or `gitlab`
- `data.git_state` — current branch, ahead/behind counts, staged/unstaged files
- `data.standards` — detected commit style, PR title format, required checks

**Invocation surface:**

```bash
~/.claude/scripts/contributing.sh --full                        # main entry
~/.claude/scripts/contributing.sh --context                     # git state only
~/.claude/scripts/contributing.sh --standards                   # project standards only
~/.claude/scripts/contributing.sh --strategy                    # strategy generation only
~/.claude/scripts/contributing.sh --raw --context               # debug
~/.claude/scripts/contributing.sh --raw --standards             # debug
~/.claude/scripts/contributing.sh --raw --full                  # debug
```

## How it works

1. **Context** — script reads the current git state: branch, remote URL (to
   detect platform), ahead/behind counts, staged and unstaged file list.
2. **Standards** — script reads `CONTRIBUTING.md` (if present) and infers
   commit style, PR title format, required labels, and branch naming
   conventions from the repo history.
3. **Strategy** — based on context + standards, the script returns one of three
   recommended strategies: `commit_changes` (local commits needed first),
   `create_pr` (branch is pushed, PR not yet open), or `up_to_date` (nothing
   to do).
4. **Pre-flight** — before any commit or push, the LLM runs tests, lint, and
   typecheck via `make test` / `make lint`. If any check fails, execution stops
   and the user is asked to fix it.
5. **Commit** — staged and unstaged changes are committed using the conventions
   detected in step 2. AI attribution is hard-blocked.
6. **PR / MR creation** — the LLM pushes the branch, searches for related open
   issues (`gh search issues` or `glab issue list`), and opens the PR/MR with
   a concise professional description that links the found issues. No emojis.
7. **Result** — the PR/MR URL is returned for the user to share or submit for
   review.

## Example workflows

### Scenario: Contributing to an open-source project

```
# manual: clone repo, make changes
/contributing                       # reads CONTRIBUTING.md, commits, opens PR
```

Single command handles the full contribution lifecycle in an unfamiliar codebase.

### Scenario: Strategy output

```
/contributing
```

```
Context
  Platform: github
  Branch:   fix/null-session-crash  (1 commit ahead of origin/main)
  Changes:  2 files staged, 0 unstaged

Standards (from CONTRIBUTING.md)
  Commit style:  Conventional Commits
  PR title:      fix(scope): description
  Required checks: tests, eslint

Strategy: create_pr

Pre-flight: tests ✓  lint ✓  typecheck ✓

Related issues found:
  #312 — Null session causes 500 in auth middleware

Opening PR...
  PR #401: fix(auth): handle null session in middleware
  Linked: Closes #312
  URL: https://github.com/org/repo/pull/401
```

## Notes & gotchas

- Platform detection is based on the git remote URL. If the remote is not
  set, the command returns `fix_error`.
- Pre-flight checks are not skippable. If tests fail, fix them before
  contributing — the command will not open a PR on a broken branch.
- "Co-Authored-By: Claude" is hard-blocked in all commits and PR bodies.
- **If it fails:** `fix_error` with a platform detection error — check
  `git remote -v`. Auth failure → re-authenticate (`gh auth login` or update
  `~/.gitlab-token`). Debug with `~/.claude/scripts/contributing.sh --raw --full`.
- This command infers standards from the target repo, not from PROJECT.yaml.
  If you're contributing to your own project, `/git-commit` + `/create-pr` is
  the preferred workflow.
