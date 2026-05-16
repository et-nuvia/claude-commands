---
command: infra-verify
group: infra
backing_script: ~/.claude/scripts/infra-verify.sh
mutates: []
runtime: ~10s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - infrastructure.enabled
  - infrastructure.repo.url
  - infrastructure.repo.type
requires_project_knowledge: none
project_knowledge_sections: []
---

# /infra-verify

Checks that the infrastructure repository is cloned, symlinked, and on the
correct branch, and that all required CLI tools (`terraform`, cloud CLIs) are
available on `PATH`. Run this once before any other infra command when
setting up a new machine or cloning a project for the first time. Makes no
changes to infrastructure — safe to run anytime.

> **Config:** PROJECT.yaml **required** — reads `infrastructure.enabled`,
> `infrastructure.repo.url`, `infrastructure.repo.type`

---

## When to use it

- First time working with infrastructure on a new machine or clone
- Before running `/infra-plan` and getting an unexpected "not linked" error
- After changing `infrastructure.*` fields in PROJECT.yaml

## Usage

```bash
/infra-verify
```

**Common invocations:**

```bash
/infra-verify              # full verification (all phases)
```

## Arguments

None — invoke with no input.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `terraform` | Verified as available for plan/apply | `brew install terraform` / [tfenv](https://github.com/tfutils/tfenv) |
| `git` | Clone check, branch check | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `aws` *(optional)* | AWS provider — checked if infra type is AWS | `brew install awscli` |
| `gcloud` *(optional)* | GCP provider — checked if infra type is GCP | `brew install google-cloud-sdk` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `infrastructure.enabled`,
  `infrastructure.repo.url`, `infrastructure.repo.type`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.infrastructure/<name>/` — the cloned infra repo (created by the user
  when `clone_repo` action is returned)
- `infrastructure/` symlink at project root — checked and recreated if wrong

## Backing script

**Script**: `~/.claude/scripts/infra-verify.sh`

**Inputs:** `--full` (all phases). Reads PROJECT.yaml for repo config.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `enable_infra`, `clone_repo`,
  `switch_branch`, `fix_symlink`, `fix_error`}
- `repo_type`, `link_path`, `terraform_available`, `section`, `message`, `details`

**Invocation surface:**

```bash
~/.claude/scripts/infra-verify.sh --full
~/.claude/scripts/infra-verify.sh --config       # phase: read PROJECT.yaml only
~/.claude/scripts/infra-verify.sh --link         # phase: check symlink only
~/.claude/scripts/infra-verify.sh --tools        # phase: check CLI tools only
~/.claude/scripts/infra-verify.sh --validate     # phase: validate terraform config
~/.claude/scripts/infra-verify.sh --raw --full   # debug: unformatted output
```

## How it works

1. **Config** — reads PROJECT.yaml; confirms `infrastructure.enabled: true`
   and required fields are present. Returns `enable_infra` if infra is
   disabled or config is missing.
2. **Link** — checks that `~/.infrastructure/<name>/` exists (cloned), is on
   the expected branch, and that `infrastructure/` at the project root
   symlinks correctly to it. Returns `clone_repo`, `switch_branch`, or
   `fix_symlink` with specific remediation instructions in `details`.
3. **Tools** — verifies `terraform` and relevant cloud CLIs are on `PATH`.
   Returns `fix_error` listing missing tools.
4. **Validate** — runs `terraform validate` inside the infra repo to catch
   stale HCL before the first plan. Returns `fix_error` with validator output
   on failure.
5. **Summary** — all checks pass; returns `display_summary` confirming repo
   type, link path, and Terraform availability.

## Example workflows

### Scenario: New machine setup

```
/infra-verify              # discover what's missing
# follow remediation steps (clone repo, fix symlink)
/infra-verify              # confirm all green
/infra-plan                # ready to plan
```

### Scenario: Verification output

```
/infra-verify
```

```
Infrastructure Verification: PASSED

Repo type:        terraform/aws
Link path:        infrastructure/ -> ~/.infrastructure/nuvia-infra
Branch:           main (up to date)
Terraform:        v1.9.2 available
AWS CLI:          v2.17.4 available

Ready for /infra-plan
```

## Notes & gotchas

- `infrastructure.enabled` must be `true` in PROJECT.yaml before this command
  does anything useful. Set it, then re-run.
- The symlink at `infrastructure/` is gitignored — each developer creates
  their own after cloning.
- **If it fails (`clone_repo`):** the `details` field in the JSON contains
  the exact repo URL and target path. Clone manually:
  `git clone <url> ~/.infrastructure/<name>`, then re-run
  `~/.claude/scripts/infra-verify.sh --json --link` to confirm.
- **If it fails (`fix_symlink`):** extract paths from `details` and run
  `rm -f <link_target> && ln -s <expected_path> <link_target>`.
- Debug any phase individually:
  `~/.claude/scripts/infra-verify.sh --raw --<phase>`.
