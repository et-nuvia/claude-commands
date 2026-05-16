---
command: infra-apply
group: infra
backing_script: ~/.claude/scripts/infra-apply.sh
mutates: [infra]
runtime: ~1-10m
destructive: true
requires_project_yaml: required
project_yaml_fields:
  - infrastructure.enabled
  - infrastructure.repo.url
  - infrastructure.repo.type
requires_project_knowledge: none
project_knowledge_sections: []
---

# /infra-apply

Applies a saved Terraform plan to provision or modify live infrastructure.
Takes the plan file produced by `/infra-plan`, shows a confirmation summary,
and executes — turning the previewed diff into real cloud resources. Always
run `/infra-plan` first; `/infra-apply` refuses to auto-apply without a plan
file.

> **Config:** PROJECT.yaml **required** — reads `infrastructure.enabled`,
> `infrastructure.repo.url`, `infrastructure.repo.type`

> ⚠️ **Destructive — confirm twice.** Applies Terraform changes to live
> infrastructure. Resources marked for destruction are permanently deleted.
> Production environments require interactive confirmation; the script will
> not auto-apply without explicit user approval.

---

## When to use it

- After `/infra-plan` has been reviewed and the change set is understood
- Provisioning new resources for a service or environment
- Applying a reviewed security group, IAM, or networking change

## Usage

```bash
/infra-apply [PLAN_FILE]
```

**Common invocations:**

```bash
/infra-apply                                        # list recent plans to choose from
/infra-apply /tmp/tfplan-staging-20260516.binary    # apply a specific plan
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `PLAN_FILE` | No | Path to the `.binary` plan file from `/infra-plan`. Omit to list recent plans. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `terraform` | Executes the apply | `brew install terraform` / [tfenv](https://github.com/tfutils/tfenv) |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Commit state files post-apply | preinstalled |
| `aws` *(optional)* | AWS provider authentication | `brew install awscli` |
| `gcloud` *(optional)* | GCP provider authentication | `brew install google-cloud-sdk` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `infrastructure.enabled`,
  `infrastructure.repo.url`, `infrastructure.repo.type`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Plan file (`.binary`) — produced by `/infra-plan`; path passed as argument
- `infrastructure/` symlink at project root — managed by `/infra-verify`

## Backing script

**Script**: `~/.claude/scripts/infra-apply.sh`

**Inputs:** `--plan-file <PATH>` (plan binary from `/infra-plan`),
`--auto-confirm` (skip interactive prompt — omit for production).
Reads PROJECT.yaml for infra repo config.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `confirm_with_user`, `fix_error`}
- `plan_file`, `apply_log`
- `add_count`, `change_count`, `destroy_count`
- `status` ∈ {`success`, `needs_confirm`, `needs_input`, `error`}

**Invocation surface:**

```bash
~/.claude/scripts/infra-apply.sh --plan-file /tmp/tfplan-staging.binary --auto-confirm
~/.claude/scripts/infra-apply.sh --plan-file /tmp/tfplan-prod.binary     # interactive confirm
~/.claude/scripts/infra-apply.sh                                          # list recent plans
~/.claude/scripts/infra-apply.sh --raw --plan-file /tmp/tfplan.binary --auto-confirm  # debug
```

## How it works

1. **Plan lookup** — if no `--plan-file` is given, script lists recent plan
   binaries for the user to choose from and returns `confirm_with_user`.
2. **Pre-flight check** — verifies the plan file exists and has not expired
   (state changed since the plan was generated). Returns `fix_error` if stale.
3. **Confirmation gate** — without `--auto-confirm`, the script requires
   interactive input. The LLM returns `confirm_with_user`, instructing the
   user to run the script interactively or re-run with `--auto-confirm` if
   the change set is safe.
4. **Apply** — runs `terraform apply <plan_file>`. Streams output to the
   apply log file. Returns `display_summary` on success.
5. **Post-apply** — reports resource counts (created / updated / destroyed)
   and log path. Recommends committing Terraform state files and running
   `/test-smoke`.

## Example workflows

### Scenario: Full plan-then-apply cycle

```
/infra-verify                                       # confirm toolchain
/infra-plan --env staging                           # preview changes
/infra-apply /tmp/tfplan-staging-20260516.binary    # apply after review
/test-smoke                                         # verify deployed services
```

### Scenario: Apply output

```
/infra-apply /tmp/tfplan-staging-20260516-143201.binary
```

```
Infrastructure Apply Complete

Plan file:       /tmp/tfplan-staging-20260516-143201.binary
Changes applied: +2 created  ~1 updated  -0 destroyed
Apply log:       /tmp/tfapply-staging-20260516-143415.log

Next steps:
  1. Verify changes in cloud console
  2. Run smoke tests: /test-smoke
  3. Commit state: git add infrastructure/ && git commit
```

## Notes & gotchas

- Always use the plan file from the most recent `/infra-plan` run. Applying
  a stale plan against a state that has since changed will be blocked.
- Omit `--auto-confirm` for production — interactive confirmation is the
  safety net. The LLM cannot type "yes" for the user.
- If apply partially succeeds and then errors, run `/infra-plan` again to
  see what remains and retry only the delta — do not re-apply the original plan.
- **If it fails:** review Terraform error output in the apply log, then run
  `/infra-plan` to generate a fresh plan before retrying. Debug the script
  with `~/.claude/scripts/infra-apply.sh --raw --plan-file <path> --auto-confirm`.
- Work (macOS) authenticates via AWS IAM role; home (WSL) may use
  Infisical-injected cloud credentials.
