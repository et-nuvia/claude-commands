---
command: task-risk
group: task-lifecycle
backing_script: ~/.claude/scripts/task-risk.sh
mutates: [files, git]
runtime: ~10s script, 5-15min of LLM analysis
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - deployment.environments
  - task_management.backend
requires_project_knowledge: none
project_knowledge_sections: []
---

# /task-risk

Scores the deployment risk of one task's change across ten weighted
categories and writes a V4 **RSK** document with a go/no-go
recommendation. Distinct from [`/deploy-risk`](deploy-risk.md), which
scores a whole release — this scores the blast radius of a single task.

> **Config:** PROJECT.yaml optional — `deployment.environments` populates
> the target-environment choice.

---

## When to use it

- A task is done and you want its risk on record before it joins a release
- The change touches auth, migrations, or a public contract
- A reviewer asked "how risky is this, actually?" and you want a number
  with reasoning behind it

## Usage

```bash
/task-risk
```

The command **asks for the target environment through a constrained choice
list** rather than accepting free text — a typo'd environment name would
otherwise waste the entire analysis step.

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | A Task ID. Falls back to `.current-task`. |

## Backing script

**Script**: `~/.claude/scripts/task-risk.sh`

**Invocation surface:**

```bash
~/.claude/scripts/task-risk.sh --validate --env <environment>   # < 1s, fails fast
~/.claude/scripts/task-risk.sh --full     --env <environment>   # gather evidence
~/.claude/scripts/task-risk.sh --json --document --env <env>    # emit RSK template
~/.claude/scripts/task-risk.sh --raw --full --env <env>         # debug
```

**Run `--validate` first, separately.** It returns in under a second and
catches an invalid environment, a non-git working directory, or an
unresolvable task ID — all of which would otherwise surface only after the
expensive gathering step.

**Outputs:** `git_diff`, `git_log`, `previous_analyses`,
`deployment_window`, the resolved version, and a `next_action`.

## How it works

1. **Validate** the environment, repo, and task.
2. **Gather** the diff, commit log, prior RSK documents, deployment window,
   and version.
3. **Score ten categories** 0–10, weighted:

   | Category | Weight |
   |---|---|
   | Security | 30% |
   | Data Integrity | 25% |
   | Breaking Changes | 15% |
   | Database Migrations | 10% |
   | Rollback | 10% |
   | Code Changes | 5% |
   | Dependencies | 2.5% |
   | Configuration | 2.5% |
   | Performance | informational |
   | Testing | informational |

   **Overall = MAX(critical individual risks, weighted average).** The max
   term is deliberate: a 10/10 security risk cannot be averaged away by
   nine comfortable scores.
4. **Write and commit the RSK** from the returned template.

## Decision matrix

| Score | Verdict | Meaning |
|---|---|---|
| 0–3 | **SAFE** | Deploy with confidence |
| 4–6 | **READY** | Deploy with monitoring |
| 7–8 | **CAUTION** | Deploy after mitigations |
| 9–10 | **BLOCK** | Do not deploy |

## Example workflows

### Scenario: risk on record before close

```
/task-post-work
/task-risk              # RSK for staging
/task-close
```

### Scenario: a blocking score

```
/task-risk
```

```
RSK-… env=production   overall: 9 (BLOCK)
  security         9   token refresh accepts an unverified issuer
  data-integrity   4
  migrations       6   one non-reversible column drop
recommendation: BLOCK — mitigate security finding, then re-run
```

Follow with [`/plan-mitigate-risks`](plan-mitigate-risks.md) rather than
deploying and watching.

## Notes & gotchas

- Prior RSK documents are fed back in, so scores across a task's history
  stay comparable instead of drifting each run.
- **If it fails:** almost always "not in a git repo" or a missing `--env`.
  Debug with `--raw --validate --env <environment>`.
