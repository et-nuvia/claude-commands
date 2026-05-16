---
command: infra-destroy
group: infra
backing_script: ~/.claude/scripts/infra-destroy.sh
mutates: [infra]
runtime: ~2-20m
destructive: true
requires_project_yaml: required
project_yaml_fields:
  - infrastructure.enabled
  - infrastructure.repo.url
  - infrastructure.repo.type
requires_project_knowledge: none
project_knowledge_sections: []
---

# /infra-destroy

Tears down Terraform-managed infrastructure for a given environment, with
mandatory interactive confirmation at every stage. Targeted destruction
(specific resources) is strongly preferred over full-environment destruction.
The command creates a destruction plan for review before any resources are
touched.

> **Config:** PROJECT.yaml **required** — reads `infrastructure.enabled`,
> `infrastructure.repo.url`, `infrastructure.repo.type`

> ⚠️ **Destructive — confirm twice.** Permanently destroys cloud
> infrastructure. Deleted resources cannot be recovered. Production
> environments require typing `"DESTROY PRODUCTION"` interactively; the LLM
> cannot bypass this gate. Prefer `--target` to limit blast radius.

---

## When to use it

- Decommissioning a staging or ephemeral environment after testing is complete
- Removing specific temporary resources (test instances, scratch databases)
- Cleaning up after a failed deployment left orphaned infrastructure

## Usage

```bash
/infra-destroy --env ENV [--target RESOURCE]
```

**Common invocations:**

```bash
/infra-destroy --env staging                                    # full env (use with caution)
/infra-destroy --env staging --target aws_instance.temp_test    # single resource
/infra-destroy --env staging --target aws_instance.a --target aws_instance.b  # multiple
/infra-destroy --env staging --force-full                       # explicitly allow full env
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--env ENV` | Yes (in JSON/AI mode) | Target environment name (`staging`, `production`, etc.) |
| `--target RESOURCE` | No | Limit destruction to one resource; repeatable. Strongly recommended. |
| `--force-full` | No | Explicitly permit full-environment destruction — dangerous; requires additional confirmation |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `terraform` | Executes the destroy plan and apply | `brew install terraform` / [tfenv](https://github.com/tfutils/tfenv) |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Repo root discovery | preinstalled |
| `aws` *(optional)* | AWS provider authentication | `brew install awscli` |
| `gcloud` *(optional)* | GCP provider authentication | `brew install google-cloud-sdk` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `infrastructure.enabled`,
  `infrastructure.repo.url`, `infrastructure.repo.type`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `infrastructure/` symlink at project root — managed by `/infra-verify`
- Review document — written to `/tmp/` before user confirmation

## Backing script

**Script**: `~/.claude/scripts/infra-destroy.sh`

**Inputs:** `--env ENV` (required in non-interactive mode), optional
`--target RESOURCE` (repeatable), `--force-full`.
Reads PROJECT.yaml for infra repo config.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`confirm_with_user`, `display_summary`,
  `block_production`, `fix_error`}
- `environment`, `destroy_count`, `risk_level`
- `review_file` — path to human-readable destruction plan document
- `status` ∈ {`ready_for_confirmation`, `success`, `blocked`, `error`}

**Invocation surface:**

```bash
~/.claude/scripts/infra-destroy.sh --env staging --target aws_instance.test
~/.claude/scripts/infra-destroy.sh --env staging --force-full
~/.claude/scripts/infra-destroy.sh --env staging --target aws_instance.test  # interactive: type DESTROY
~/.claude/scripts/infra-destroy.sh --raw --env staging --target aws_instance.test  # debug
```

## How it works

1. **Plan destruction** — runs `terraform plan -destroy` (with `--target`
   flags if provided) to produce a destruction plan and review document.
   Returns `fix_error` if the plan fails.
2. **Risk assessment** — counts resources to be destroyed; sets `risk_level`.
   Full-environment plans without `--force-full` return `fix_error` asking
   for an explicit flag.
3. **Production gate** — if `--env production` is detected in JSON/AI mode,
   returns `block_production`. The user must run the script interactively and
   type `DESTROY PRODUCTION`.
4. **Confirmation** — for non-production environments, returns
   `confirm_with_user` with the review document path and counts. The LLM
   presents the plan and instructs the user to run the script interactively,
   typing `DESTROY` when prompted.
5. **Destroy** — once the user confirms interactively, `terraform destroy`
   executes. Returns `display_summary` with destroyed resource count.
6. **Post-destroy** — recommends verifying in the cloud console, removing
   from monitoring systems, and updating documentation.

## Example workflows

### Scenario: Decommission a staging environment

```
/infra-drift --env staging              # confirm current state
/infra-destroy --env staging            # create plan, get confirmation prompt
# user runs script interactively, types DESTROY
/infra-verify                           # confirm toolchain still intact
```

### Scenario: Remove a single test resource

```
/infra-destroy --env staging --target aws_instance.load_test_runner
```

```
Destruction plan created

Environment:       staging
Resources:         1 will be destroyed
Risk level:        LOW
Review document:   /tmp/tfdestroy-staging-20260516-150312-review.md

To execute: run ~/.claude/scripts/infra-destroy.sh interactively
            (type DESTROY when prompted)
```

## Notes & gotchas

- Always use `--target` when possible — full environment destruction is
  nearly impossible to undo and should be a last resort.
- Production destruction requires typing `DESTROY PRODUCTION` interactively.
  There is no flag or argument that bypasses this. The LLM explicitly cannot
  complete this step on behalf of the user.
- If destroy partially succeeds and then errors, inspect remaining state with
  `cd infrastructure/terraform && terraform state list`, then re-run with
  `--target` on the remaining resources.
- **If it fails:** review Terraform error output in the review document.
  Check remaining state with `terraform state list`. Debug with
  `~/.claude/scripts/infra-destroy.sh --raw --env <env> --target <resource>`.
- Work (macOS) uses AWS IAM role auth; home (WSL) may use
  Infisical-injected cloud credentials.
