---
command: infra-plan
group: infra
backing_script: ~/.claude/scripts/infra-plan.sh
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

# /infra-plan

Runs `terraform plan` against your infrastructure repository and produces a
human-readable risk-annotated review document. You get a precise change
set — resources to create, update, and destroy — before anything touches live
infrastructure. The resulting plan file is passed directly to `/infra-apply`.

> **Config:** PROJECT.yaml **required** — reads `infrastructure.enabled`,
> `infrastructure.repo.url`, `infrastructure.repo.type`

---

## When to use it

- Before any `/infra-apply` run — always plan first to see what will change
- After editing Terraform code to confirm only the intended diff appears
- When onboarding to a project to audit what live state looks like vs code

## Usage

```bash
/infra-plan [options]
```

**Common invocations:**

```bash
/infra-plan                             # default workspace + environment
/infra-plan --env staging               # target a named environment
/infra-plan --workspace prod            # explicit Terraform workspace
/infra-plan --target aws_instance.web   # limit to a specific resource
/infra-plan --reinit                    # force re-init before plan (backend changes)
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--env ENV` | No | Environment name passed to the script (e.g., `staging`, `production`) |
| `--workspace WS` | No | Terraform workspace to select before planning |
| `--target RESOURCE` | No | Limit the plan to one resource; repeatable for multiple targets |
| `--reinit` | No | Force `terraform init` before planning — use after backend config changes |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `terraform` | Executes init, validate, and plan | `brew install terraform` / [tfenv](https://github.com/tfutils/tfenv) |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Discover repo root and branch state | preinstalled |
| `aws` *(optional)* | AWS provider authentication | `brew install awscli` |
| `gcloud` *(optional)* | GCP provider authentication | `brew install google-cloud-sdk` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `infrastructure.enabled`,
  `infrastructure.repo.url`, `infrastructure.repo.type`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.infrastructure/<name>/` — the cloned infra repo (managed by `/infra-verify`)
- `infrastructure/` symlink at project root — created by `/infra-verify`

## Backing script

**Script**: `~/.claude/scripts/infra-plan.sh`

**Inputs:** `--full` (main entry), plus optional `--env ENV`,
`--workspace WS`, `--reinit`, `--target RESOURCE` (repeatable).
Reads PROJECT.yaml for infra repo config.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `fix_error`}
- `environment`, `workspace`, `risk_level` (`LOW` | `MEDIUM` | `HIGH`)
- `add_count`, `change_count`, `destroy_count`
- `plan_file` — path to saved plan binary for use with `--plan-file` in `/infra-apply`
- `review_file` — path to human-readable review document

**Invocation surface:**

```bash
~/.claude/scripts/infra-plan.sh --full
~/.claude/scripts/infra-plan.sh --full --env staging --workspace prod
~/.claude/scripts/infra-plan.sh --full --target aws_instance.web
~/.claude/scripts/infra-plan.sh --validate          # phase: validate config only
~/.claude/scripts/infra-plan.sh --init              # phase: init only
~/.claude/scripts/infra-plan.sh --plan              # phase: plan only
~/.claude/scripts/infra-plan.sh --analyze           # phase: analyze plan output
~/.claude/scripts/infra-plan.sh --document          # phase: write review doc
~/.claude/scripts/infra-plan.sh --raw --full        # debug: unformatted output
```

## How it works

1. **Validate** — runs `terraform validate` to catch HCL syntax errors before
   touching the backend. Returns `fix_error` immediately if validation fails.
2. **Init** — runs `terraform init` (or skips if `.terraform/` is current).
   `--reinit` forces a fresh init regardless.
3. **Plan** — runs `terraform plan -out=<plan_file>` with any `--target` or
   `--workspace` flags applied. The plan binary is saved for apply.
4. **Analyze** — parses the plan output; counts add/change/destroy; sets
   `risk_level` to HIGH when destroys are present, MEDIUM for large change
   sets, LOW otherwise.
5. **Document** — writes a human-readable review file alongside the plan
   binary. Returns `display_summary` with paths and risk level for the LLM
   to present.

## Example workflows

### Scenario: Standard pre-apply review

```
/infra-verify           # confirm infra repo linked and tools available
/infra-plan             # preview changes
/infra-apply            # apply the saved plan
```

Run this sequence for any infrastructure change. `/infra-verify` ensures
the toolchain is ready before any Terraform commands run.

### Scenario: Targeted resource plan with output

```
/infra-plan --env staging --target aws_security_group.app
```

```
Terraform Plan Complete

Environment: staging    Workspace: default
Risk Level: LOW

Changes:
  + 0 to create
  ~ 1 to update
  - 0 to destroy

Plan file:    /tmp/tfplan-staging-20260516-143201.binary
Review doc:   /tmp/tfplan-staging-20260516-143201-review.md

Next steps:
  1. Review: read /tmp/tfplan-staging-20260516-143201-review.md
  2. Apply:  /infra-apply /tmp/tfplan-staging-20260516-143201.binary
  3. Discard: rm /tmp/tfplan-staging-20260516-143201.binary
```

## Notes & gotchas

- Plan files are time-stamped; they expire if the underlying state changes —
  always apply the plan file immediately after reviewing it.
- `risk_level: HIGH` (destroys present) triggers a prominent warning. Do not
  proceed to `/infra-apply` without carefully reading the review document.
- Infrastructure must be linked before planning. If the script returns
  `Infrastructure not linked`, run `/infra-verify` first.
- **If it fails:** `Terraform plan failed` — check the `details` field for
  Terraform error output. Debug with
  `~/.claude/scripts/infra-plan.sh --raw --full`. Backend errors typically
  need `--reinit`.
- Work (macOS) uses AWS IAM role auth; home (WSL) may use GCP service account
  credentials or Infisical-injected cloud keys.
