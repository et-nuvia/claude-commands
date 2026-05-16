---
command: deploy-to-stage
group: deploy
backing_script: ~/.claude/scripts/deploy-to-stage.sh
mutates: [git, github, gitlab, aws]
runtime: ~5-15min
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - ci.platform
  - ci.branches.staging
  - ci.branches.production
  - deployment.method
  - deployment.health_check_path
  - deployment.staging.url
  - deployment.production.url
requires_project_knowledge: none
project_knowledge_sections: []
---

# /deploy-to-stage

Merges your development branch into staging, monitors the CI/CD pipeline to
completion, verifies service health and deployed version, and runs E2E tests.
At the end you have a validated staging deployment and a clear path to
`/deploy-to-prod`.

> **Config:** PROJECT.yaml **required** — reads `ci.platform`, `ci.branches.staging`,
> `ci.branches.production`, `deployment.method`, `deployment.health_check_path`,
> `deployment.staging.url`

---

## When to use it

- A feature branch is merged to dev and ready for staging validation
- You want an automated merge + pipeline watch instead of manually pushing branches
- CI/CD or health checks need to be confirmed before promoting to production

## Usage

```bash
/deploy-to-stage
```

**Common invocations:**

```bash
/deploy-to-stage                      # default: full pipeline (lint → merge → CI → health → E2E)
/deploy-to-stage --deploy             # resume after resolving merge conflicts
/deploy-to-stage --validate           # re-run pre-flight validation only
/deploy-to-stage --risk-analysis      # re-run risk analysis only
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| *(none)* | — | Invoke with no arguments for the full pipeline |
| `--validate` | No | Re-run the pre-flight / git-state check only |
| `--risk-analysis` | No | Re-run risk scoring only |
| `--merge` | No | Retry the merge step after a prior conflict resolution |
| `--deploy` | No | Resume from the deploy step (after manually resolving conflicts) |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` (≥ 2.30) | Branch validation and merge | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `gh` or `glab` | CI pipeline monitoring | `brew install gh` / install `glab` |
| `docker compose` (V2) | E2E test execution | Docker Desktop / Engine |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `ci.platform`, `ci.branches.staging`,
  `deployment.method`. Optional: `deployment.health_check_path`,
  `deployment.staging.url` (enables health + version checks).
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.claude/docs/reference/ux/task-completion.md` — output formatting reference
- `~/.claude/docs/reference/ux/error-blocker.md` — error output formatting reference

## Backing script

**Script**: `~/.claude/scripts/deploy-to-stage.sh`

**Inputs:** `--full` (main entry), section flags for resumption. Reads
`PROJECT.yaml` for branch names, CI platform, and deployment targets.
Pre-flight runs `ci-lint-local.sh --full` before the main script.

**Outputs (structured JSON):** `next_action` ∈ {`display_summary`,
`resolve_conflicts`, `confirm_action`, `ask_rebase_strategy`, `fix_error`},
plus `status` (`success` | `warning`), `issues[]`, `conflict_files[]`,
`risk_score`, `target_ahead_count`, `source_ahead_count`, `options[]`.

**Invocation surface:**

```bash
~/.claude/scripts/ci-lint-local.sh --full              # pre-flight (always runs first)
~/.claude/scripts/deploy-to-stage.sh --full            # main entry
~/.claude/scripts/deploy-to-stage.sh --validate        # git state only
~/.claude/scripts/deploy-to-stage.sh --risk-analysis   # risk scoring only
~/.claude/scripts/deploy-to-stage.sh --merge           # merge step only
~/.claude/scripts/deploy-to-stage.sh --deploy          # post-conflict resume
~/.claude/scripts/deploy-to-stage.sh --raw --<section> # debug: bypass formatting
```

## How it works

1. **Pre-flight** — `ci-lint-local.sh --full` runs lint and type checks
   locally. If `fix_before_push` is set, all issues must be resolved before
   continuing. This catches pipeline failures before they consume CI minutes.
2. **Validate** — script checks the git state: clean working tree, staging
   branch exists, no uncommitted changes. Returns `ask_rebase_strategy` if
   dev and staging have diverged; the LLM presents options and waits for user
   input.
3. **Risk analysis** — automated 10-category risk score computed against the
   staged diff. Score ≥ 9 returns `confirm_action` and halts; the LLM displays
   concerns and mitigations and waits for explicit user approval.
4. **Merge** — regular `--no-ff` merge (dev → staging). No squash: preserving
   commit SHAs lets production promotion re-tag cleanly without phantom
   conflicts. Merge conflicts return `resolve_conflicts` with the file list;
   after the LLM resolves and stages them, the `--deploy` flag resumes.
5. **Pipeline monitor** — script polls the CI/CD pipeline (GitHub Actions or
   GitLab CI, auto-detected from PROJECT.yaml) to completion.
6. **Health + version check** — when `deployment.staging.url` is configured,
   checks that the service is responding and the deployed version matches.
7. **E2E tests** — runs the project's E2E suite against staging.
8. **Summary** — `display_summary` triggers an AI code review of the
   dev→staging diff (migrations, breaking changes, security, performance,
   dependencies) followed by a formatted deployment report. If all green,
   suggests `/deploy-to-prod`.

## Example workflows

### Scenario: Standard feature promotion

```
/task-close            # task complete, dev branch merged
/deploy-to-stage       # merge + pipeline + E2E
/deploy-to-prod        # promote to production
```

Run immediately after closing a task whose branch has been merged to dev.

### Scenario: Conflict resolution mid-deploy

```
/deploy-to-stage
# → resolve_conflicts returned
# (resolve conflict markers in editor)
/deploy-to-stage --deploy
```

After manually resolving conflicts and staging the files, resume with `--deploy`.

### Scenario: Successful deployment output

```
/deploy-to-stage
```

```
Staging Deployment Complete
─────────────────────────────────────────
Branch:    dev → staging
Pipeline:  #4821 — passed (3m 42s)
Health:    https://staging.example.com — 200 OK
Version:   1.4.2 ✓
E2E:       47/47 passed

Code review: no migrations, no breaking changes, 2 dependency updates (patch).

Next: /deploy-to-prod
```

## Notes & gotchas

- Regular merge (not squash) is intentional — squashing would create phantom
  conflicts when staging SHAs are later promoted to production.
- If dev and staging have diverged (staging has commits not in dev — common
  after hotfixes), the `ask_rebase_strategy` prompt explains the options.
  Investigate *why* staging diverged before choosing `merge_anyway`.
- `deploy-to-stage` mutates shared staging state that other developers share.
  Co-ordinate with the team before merging if staging is actively used for QA.
- **If it fails (merge):** resolve conflicts, `git add` the files, then
  `~/.claude/scripts/deploy-to-stage.sh --deploy`.
- **If it fails (pipeline):** check CI logs via `gh run view` / `glab ci view`,
  fix the root cause, re-push, then rerun `~/.claude/scripts/deploy-to-stage.sh --deploy`.
- **If it fails (E2E):** fix tests or the deployed code; rerun
  `~/.claude/scripts/deploy-to-stage.sh --raw --deploy` to see full output.
- **Work (macOS):** GitHub Actions + AWS. **Home (WSL):** GitLab CI + Unraid.
  Platform is auto-detected from `ci.platform` in PROJECT.yaml.
