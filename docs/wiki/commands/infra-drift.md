---
command: infra-drift
group: infra
backing_script: ~/.claude/scripts/infra-drift.sh
mutates: []
runtime: ~30-120s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - infrastructure.enabled
  - infrastructure.repo.url
  - infrastructure.repo.type
requires_project_knowledge: none
project_knowledge_sections: []
---

# /infra-drift

Runs `terraform plan` across one or more environments and reports any
resources whose actual cloud state has diverged from what the Terraform code
describes. Produces per-environment drift reports and a remediation menu.
Makes no changes — safe to run anytime, including in CI on a schedule.

> **Config:** PROJECT.yaml **required** — reads `infrastructure.enabled`,
> `infrastructure.repo.url`, `infrastructure.repo.type`

---

## When to use it

- Routine audit to catch manual cloud console changes that bypassed Terraform
- Before a planned apply, to confirm the baseline matches what the code expects
- Investigating an incident where live behaviour differs from the configured state

## Usage

```bash
/infra-drift [--env ENV]
```

**Common invocations:**

```bash
/infra-drift                          # check all configured environments
/infra-drift --env staging            # check one environment
/infra-drift --env staging --env prod # check two environments
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--env ENV` | No | Environment name to check; repeatable. Defaults to all configured environments. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `terraform` | Runs plan to detect state divergence | `brew install terraform` / [tfenv](https://github.com/tfutils/tfenv) |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Repo root discovery | preinstalled |
| `aws` *(optional)* | AWS provider authentication | `brew install awscli` |
| `gcloud` *(optional)* | GCP provider authentication | `brew install google-cloud-sdk` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `infrastructure.enabled`,
  `infrastructure.repo.url`, `infrastructure.repo.type`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `infrastructure/` symlink at project root — managed by `/infra-verify`
- Drift report files — written to `/tmp/` for each affected environment

## Backing script

**Script**: `~/.claude/scripts/infra-drift.sh`

**Inputs:** `--full` (main entry), optional `--env=ENV` (repeatable).
Reads PROJECT.yaml for repo and environment config.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `remediate_drift`, `fix_error`}
- `drift_summary[]` — per environment: `environment`, `status`
  (`ok` | `drift`), `total`, `add`, `update`, `replace`, `destroy`, `report`
- `status` ∈ {`success`, `drift_detected`, `error`}

**Invocation surface:**

```bash
~/.claude/scripts/infra-drift.sh --full
~/.claude/scripts/infra-drift.sh --full --env=staging
~/.claude/scripts/infra-drift.sh --validate          # phase: validate config only
~/.claude/scripts/infra-drift.sh --check             # phase: run plan checks only
~/.claude/scripts/infra-drift.sh --analyze           # phase: analyze plan output only
~/.claude/scripts/infra-drift.sh --raw --full        # debug: unformatted output
```

## How it works

1. **Validate** — confirms the infra repo is linked and Terraform config is
   valid. Returns `fix_error` if the symlink is missing (run `/infra-verify`).
2. **Check** — runs `terraform plan -detailed-exitcode` per environment.
   Exit code 2 means drift detected; 0 means clean.
3. **Analyze** — parses each plan output; counts adds/updates/replaces/
   destroys per environment; writes per-environment drift report files.
4. **Summarize** — returns `display_summary` if all environments are clean;
   `remediate_drift` with `drift_summary` if any show divergence, guiding
   the user to review the report and choose between restoring code state
   (via `/infra-plan` + `/infra-apply`) or updating Terraform to match.

## Example workflows

### Scenario: Scheduled drift audit

```
/infra-drift                  # check all environments
# if drift found: review report, decide: restore vs accept
/infra-plan --env staging     # restore to code state
/infra-apply                  # apply the corrective plan
```

### Scenario: Drift detected output

```
/infra-drift --env staging
```

```
Drift detected in 1 of 1 environments checked.

Drift in staging: 3 resources affected
  + 0 to create   ~ 2 to update
  r 1 to replace   - 0 to destroy
  Report: /tmp/drift-staging-20260516-144502.md

Options:
  1. Restore code state:  /infra-plan --env staging  then  /infra-apply
  2. Accept drift:        update Terraform code to match actual infrastructure
```

## Notes & gotchas

- Drift detection uses `terraform plan` internally — it contacts the cloud
  provider and may count against API rate limits.
- A drift report file is only created when drift is detected; clean
  environments produce no report file.
- Manual cloud console changes are the most common source of drift. Check
  the report to confirm the change was intentional before deciding to
  restore or accept.
- **If it fails:** check the `message` and `details` fields. If the error
  mentions a missing symlink, run `/infra-verify` first. Debug with
  `~/.claude/scripts/infra-drift.sh --raw --full`.
- Work (macOS) uses AWS IAM role auth; home (WSL) may use
  Infisical-injected cloud credentials.
