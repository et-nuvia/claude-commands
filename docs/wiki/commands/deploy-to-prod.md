---
command: deploy-to-prod
group: deploy
backing_script: ~/.claude/scripts/deploy-to-prod.sh
mutates: [git, github, gitlab, aws]
runtime: ~10-20min
destructive: true
requires_project_yaml: required
project_yaml_fields:
  - ci.platform
  - ci.branches.staging
  - ci.branches.production
  - deployment.method
  - deployment.health_check_path
  - deployment.production.url
  - deployment.staging.url
requires_project_knowledge: none
project_knowledge_sections: []
---

# /deploy-to-prod

Promotes a validated staging deployment to production: merges staging into the
production branch, monitors CI/CD to completion, verifies health and version,
creates a versioned git tag, and syncs the tag back to staging and dev.
Stricter thresholds than `/deploy-to-stage`; score ≥ 9 blocks automatically.

> **Config:** PROJECT.yaml **required** — reads `ci.platform`,
> `ci.branches.staging`, `ci.branches.production`, `deployment.method`,
> `deployment.health_check_path`, `deployment.production.url`

> ⚠️ **Destructive — confirm twice.** Merges to the production branch and
> triggers a live production deployment. The CI pipeline owns rollback on smoke
> test failure; do NOT manually revert master on health warnings.

---

## When to use it

- Staging has been validated (`/deploy-to-stage` passed, E2E green)
- The team has signed off and risk has been assessed
- You want automated merge + pipeline watch + version tagging instead of a
  manual production push

## Usage

```bash
/deploy-to-prod
```

**Common invocations:**

```bash
/deploy-to-prod                       # default: full pipeline
/deploy-to-prod --deploy              # resume after resolving merge conflicts
/deploy-to-prod --validate            # re-run staging readiness check only
/deploy-to-prod --risk-analysis       # re-run risk scoring only
/deploy-to-prod --tag                 # sync tags to staging/dev only
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| *(none)* | — | Invoke with no arguments for the full production pipeline |
| `--validate` | No | Re-run staging readiness check only |
| `--risk-analysis` | No | Re-run risk scoring only |
| `--merge` | No | Retry the merge step |
| `--deploy` | No | Resume from deploy step after conflict resolution |
| `--tag` | No | Re-run tag creation and branch sync only |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` (≥ 2.30) | Branch validation, merge, and tagging | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `gh` or `glab` | CI pipeline monitoring | `brew install gh` / install `glab` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `ci.platform`, `ci.branches.staging`,
  `ci.branches.production`, `deployment.method`. Optional:
  `deployment.health_check_path`, `deployment.production.url` (enables health
  + version checks).
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.claude/docs/reference/ux/task-completion.md` — output formatting reference
- `~/.claude/docs/reference/ux/error-blocker.md` — error output formatting reference

## Backing script

**Script**: `~/.claude/scripts/deploy-to-prod.sh`

**Inputs:** `--full` (main entry), section flags for resumption. Reads
`PROJECT.yaml` for branch names, CI platform, and deployment targets.

**Outputs (structured JSON):** `next_action` ∈ {`display_summary`,
`resolve_conflicts`, `confirm_action`, `fix_error`}, plus `status`
(`success` | `warning`), `version`, `tag`, `health_status`, `version_status`,
`conflict_files[]`, `risk_score`, `rollback_performed`.

**Invocation surface:**

```bash
~/.claude/scripts/deploy-to-prod.sh --full             # main entry
~/.claude/scripts/deploy-to-prod.sh --validate         # staging readiness only
~/.claude/scripts/deploy-to-prod.sh --risk-analysis    # risk scoring only
~/.claude/scripts/deploy-to-prod.sh --merge            # merge step only
~/.claude/scripts/deploy-to-prod.sh --deploy           # post-conflict resume
~/.claude/scripts/deploy-to-prod.sh --tag              # tag + branch sync only
~/.claude/scripts/deploy-to-prod.sh --raw --<section>  # debug: bypass formatting
```

## How it works

1. **Validate** — confirms staging branch is clean, CI passed on staging, and
   staging is ahead of production. Blocks if staging itself has uncommitted
   changes or an outstanding pipeline failure.
2. **Risk analysis** — 10-category weighted risk score with **production
   thresholds**: score ≥ 7 returns `confirm_action` (caution, mitigate first);
   score ≥ 9 blocks entirely. The LLM displays the scorecard and waits for
   explicit user approval before continuing.
3. **Merge** — regular merge (staging → production branch). No squash:
   preserving commit SHAs is required for clean tag ancestry. Conflicts return
   `resolve_conflicts`; after the LLM resolves and stages them, `--deploy`
   resumes.
4. **Pipeline monitor** — polls the production CI/CD pipeline to completion
   (GitHub Actions or GitLab CI, auto-detected from PROJECT.yaml).
5. **Health + version check** — verifies the live service is responding and
   the deployed version matches. Results are informational: warnings surface in
   `display_summary` but do NOT trigger script-level rollback. The CI pipeline
   owns smoke tests and automatic rollback; this script does not revert master.
6. **Tag + sync** — creates `v{VERSION}` git tag on the production commit, then
   syncs the tag and any changelog entries back to staging and dev branches.
7. **Summary** — `display_summary` triggers production-level AI code review
   (destructive migrations → BLOCK, removed API endpoints → BLOCK, hardcoded
   secrets → BLOCK) followed by a deployment report with version and tag.

## Example workflows

### Scenario: Standard release pipeline

```
/deploy-to-stage        # staging validation + E2E
/deploy-risk            # optional: standalone risk doc
/deploy-to-prod         # production promotion + tag
```

The canonical flow after a feature is validated in staging.

### Scenario: Conflict mid-production merge

```
/deploy-to-prod
# → resolve_conflicts returned
# (resolve conflict markers, git add)
/deploy-to-prod --deploy
```

Production merges rarely conflict; if they do it usually signals hotfix drift
on the production branch. Investigate before resolving.

### Scenario: Successful deployment output

```
/deploy-to-prod
```

```
Production Deployment Complete
─────────────────────────────────────────
Branch:    staging → main
Pipeline:  #1042 — passed (6m 17s)
Health:    https://prod.example.com — 200 OK
Version:   1.5.0 ✓
Tag:       v1.5.0 (synced to staging, dev)

Code review: 1 non-destructive migration (ADD COLUMN nullable), no breaking
API changes, no security findings.
```

## Notes & gotchas

- **Production thresholds are stricter than staging.** Score ≥ 7 requires
  explicit confirmation; score ≥ 9 is a hard block. Do not attempt to work
  around the block — resolve the underlying risk first.
- The CI pipeline owns smoke tests and automatic rollback. If `rollback_performed`
  is `true` in `fix_error`, the pipeline already reverted — do NOT manually
  revert the production branch.
- If `health_status` or `version_status` is a warning after a successful
  pipeline, surface it to the user but do not revert. The pipeline validated
  the deploy; a transient health check miss is not a deployment failure.
- Regular merge (not squash) preserves commit SHAs needed for clean tag ancestry
  and future hotfix cherry-picks.
- Tag sync (`--tag`) is safe to rerun if the tag step failed and the deploy itself
  succeeded.
- **If it fails (merge):** resolve conflicts, `git add`, then
  `~/.claude/scripts/deploy-to-prod.sh --deploy`.
- **If it fails (pipeline):** do NOT push a revert to master. Check CI logs,
  confirm whether the pipeline auto-rolled back (`rollback_performed`), fix
  root cause, then rerun from `--deploy`.
- **If it fails (tag):** the deploy is live. Rerun
  `~/.claude/scripts/deploy-to-prod.sh --tag` to retry tag creation and sync
  only.
- **Work (macOS):** GitHub Actions + AWS. **Home (WSL):** GitLab CI + Unraid/GCP.
  Platform auto-detected from `ci.platform` in PROJECT.yaml.
