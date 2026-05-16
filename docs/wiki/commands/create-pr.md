---
command: create-pr
group: git
backing_script: ~/.claude/scripts/create-pr.sh
mutates: [git, github, gitlab]
runtime: ~15-45s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - git.platform
  - git.repo
requires_project_knowledge: none
project_knowledge_sections: []
---

# /create-pr

Pushes your current branch, drafts a conventional-commit PR title and
comprehensive description from the commit log and diff, runs a quick secrets
grep, then opens the PR on GitHub or GitLab. You review and approve the
description before it goes live.

> **Config:** PROJECT.yaml **optional** — reads `git.platform` and `git.repo`
> to select `gh` (GitHub) or `glab` (GitLab) and target the correct remote.
> Falls back to auto-detection from the git remote URL when the file is absent
> or the fields are missing.

---

## When to use it

- Your branch is ready for review and you want a well-structured PR without
  hand-writing the description
- You finished `/git-commit` and the next step is opening review
- You need the PR linked to a tracked issue (`Closes #N`) automatically

## Usage

```bash
/create-pr [free-form instructions]
```

**Common invocations:**

```bash
/create-pr                          # auto-detect everything, push and open
/create-pr --base develop           # override base branch
/create-pr "emphasize the DB migration in the description"
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form hint for description generation (emphasis, scope notes, tone). |
| `--base <branch>` | No | Override the base branch. Default: auto-detected from remote HEAD or PROJECT.yaml. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Diff analysis, push, remote detection | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `gh` | Create PR on GitHub | `brew install gh` — then `gh auth login` |
| `glab` | Create MR on GitLab | `brew install glab` / `apt install glab` — then `glab auth login` |

Only one of `gh` / `glab` is required depending on your platform.

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Reads `git.platform` (`github`/`gitlab`) and
  `git.repo` (`owner/repo` or `group/project`).
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `.github/pull_request_template.md` — if present, the LLM uses it as the
  description structure
- Repo `.git/` — required

## Backing script

**Script**: `~/.claude/scripts/create-pr.sh`

**Inputs:** `--full`, `--analyze`, `--push`, `--base <branch>`.

**Outputs:** structured JSON on stdout with:

- `next_action` ∈ {`generate_description`, `display_summary`, `fix_error`}
- `platform` (`github`/`gitlab`), `base_branch`, `current_branch`,
  `issue_number`, `commits` array, `files` array, `diff_stat`

**Invocation surface:**

```bash
~/.claude/scripts/create-pr.sh --full                   # analyze + push + return data
~/.claude/scripts/create-pr.sh --analyze                # inspect only, no push
~/.claude/scripts/create-pr.sh --push                   # push only
~/.claude/scripts/create-pr.sh --full --base develop    # custom base
~/.claude/scripts/create-pr.sh --raw --full             # debug
```

## How it works

1. **Analyze** — script reads commit log, diff stats, and file list; detects
   platform from PROJECT.yaml or git remote; extracts issue number from branch
   name if present.
2. **Push** — script pushes the branch with `-u` to set tracking. If pre-push
   hooks mutate tracked files (e.g., eslint `--fix`), the script auto-commits
   those as `chore: apply pre-push hook fixes` and re-pushes (up to 2 cycles).
3. **Generate description** — LLM reads `commits`, `files`, and `diff_stat`
   from the JSON; runs a secrets grep (`password|secret|api[_-]?key|token`)
   on the diff; writes a `type(scope): description` title (< 70 chars) plus a
   body with Summary, Changes, Testing, and Deployment Notes sections (empty
   sections omitted). Adds `Closes #N` when an issue number was detected.
4. **Create PR** — on GitHub: `gh pr create --title "…" --body "…"
   --base <base>`; on GitLab: `git push -o merge_request.create -o
   merge_request.title="…" -o merge_request.target=<base>`. Displays PR URL,
   commit count, files changed, and lines added/removed.

## Example workflows

### Scenario: End-of-task wrap-up

```
/task-continue       # implement, write tests, update plan
/git-commit          # clean commits
/create-pr           # open PR
```

Standard flow: commit then PR in one session.

### Scenario: PR opened with linked issue

```
/create-pr
```

```
Pushing feature/PROJ-42-add-search to origin… done

PR #87 opened: feat(search): add full-text search to products API
  Base   : main
  Commits: 3  |  Files: 7  |  +214/-18
  Closes #42

  https://github.com/org/repo/pull/87
```

## Notes & gotchas

- **No AI attribution** — "Co-Authored-By: Claude" and similar phrases are
  blocked from the PR body and commits, per project policy.
- **Secrets grep is advisory** — if the grep fires, the LLM flags it in the
  description and pauses for you to confirm before creating the PR.
- **GitLab MRs** are created via push options, not via API; the MR URL is
  printed by git after the push and captured from stdout.
- **Platform auto-detection** reads the git remote URL: `github.com` → `gh`,
  anything else → `glab`. Set `git.platform` in PROJECT.yaml to override.
- **If it fails (push rejected):** check whether the remote branch is
  protected or requires a signed commit, then rerun
  `~/.claude/scripts/create-pr.sh --push` after resolving.
- **If it fails (platform detection):** add `git.platform` and `git.repo` to
  PROJECT.yaml, then rerun. Debug with
  `~/.claude/scripts/create-pr.sh --raw --full`.
- Work (macOS) always uses `gh` against github.com; home (WSL) uses `glab`
  against the configured GitLab instance.
