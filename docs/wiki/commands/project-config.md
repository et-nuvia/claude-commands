---
command: project-config
group: project-config
backing_script: ~/.claude/scripts/project-config.sh
mutates: [files]
runtime: ~5-15s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - name
  - stack.languages
  - stack.frameworks
  - stack.components
  - task_management.backend
  - ci.platform
  - ci.branches.staging
  - ci.branches.production
  - git.platform
  - git.instance
  - git.repo
  - secrets.backend
  - secrets.required
requires_project_knowledge: none
project_knowledge_sections: []
---

# /project-config

Creates, displays, validates, and updates the PROJECT.yaml file that every
other skill reads for project identity, stack, deployment targets, and secrets
configuration. This is the meta-command: run it first on new projects and
whenever a field needs correcting. After `init`, all other skills can locate
registries, branches, and backends without asking again.

> **Config:** PROJECT.yaml **optional** — `init` creates it from scratch; `show`, `validate`, and `update` require it to already exist. When present, reads all top-level fields listed above.

---

## When to use it

- Starting a new project and no PROJECT.yaml exists yet
- A skill fails because a required field (`ci.platform`, `task_management.backend`, etc.) is missing or wrong
- You need to change a single field without hand-editing the YAML

## Usage

```bash
/project-config [operation] [field] [value]
```

**Common invocations:**

```bash
/project-config                             # default: show current config
/project-config init                        # create PROJECT.yaml from template
/project-config show                        # display current config (same as default)
/project-config validate                    # check schema and required fields
/project-config update testing.command "pytest -x"  # update one field
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `operation` | No | One of `init`, `show`, `validate`, `update`. Defaults to `show`. |
| `field` | With `update` | Dot-path to the field to update (e.g., `ci.platform`) |
| `value` | With `update` | New value to write |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `yq` | Read and write YAML fields | `brew install yq` |
| `jq` | Build and consume the result JSON | `brew install jq` |
| `git` | Auto-detect repo, platform, remote | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `init` creates it; all other operations require it.
- `~/.claude/templates/PROJECT.yaml` — template used by `init`

## Backing script

**Script**: `~/.claude/scripts/project-config.sh`

**Inputs:** free-form `$ARGUMENTS` (parsed to operation + optional field/value).
Reads the current working directory for git remote detection during `init`.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `fix_validation_errors`, `fix_error`}
- `message` — human-readable result
- `details` — on `init`: `{name, languages, services, platform, backend}`; on `show`: full `config` object; on `validate`: `{errors[], warnings[]}`

**Invocation surface:**

```bash
~/.claude/scripts/project-config.sh init
~/.claude/scripts/project-config.sh show
~/.claude/scripts/project-config.sh validate
~/.claude/scripts/project-config.sh update <field> <value>
~/.claude/scripts/project-config.sh --raw show        # debug: bypass formatting
~/.claude/scripts/project-config.sh --raw validate    # debug
```

## How it works

1. **Parse operation** — the LLM extracts `init | show | validate | update` from `$ARGUMENTS`; defaults to `show` when empty.
2. **Execute script** — script runs the chosen operation and returns structured JSON.
3. **init path** — script auto-detects `name` (from directory), `git.platform` and `git.repo` (from remote), and `ci.platform` (from remote). Returns `display_summary` with detected values. LLM presents them to the user for confirmation, asks follow-up questions (databases? notification channels?), then writes corrections with the Edit tool and re-runs `validate`.
4. **show path** — script reads the existing file and returns the full `config` object. LLM formats it for display.
5. **validate path** — script checks every required field against schema. Returns `fix_validation_errors` with `errors[]` and `warnings[]` when issues are found. LLM determines which are auto-fixable and which need user input, applies fixes, then re-runs.
6. **update path** — script writes the new value to the dot-path field using `yq`. Returns `display_summary` confirming the change.

## Example workflows

### Scenario: New project setup

```
/project-config init        # create PROJECT.yaml with auto-detected values
/project-config validate    # confirm no schema errors
/setup-secrets              # now that secrets.backend is set
/task-start 1               # task management backend is ready
```

### Scenario: Fix a missing field mid-task

```
/deploy-to-stage            # fails: ci.platform not set
/project-config update ci.platform github
/deploy-to-stage            # retried successfully
```

### Scenario: Init output

```
/project-config init
```

```
Detected configuration:
  name:        nuvia-api
  languages:   [python]
  services:    [api, db, redis]
  platform:    github
  backend:     asana

Is this correct? Any fields to change?
(Also: does this project use a database with migrations? Notification channels?)
```

## Notes & gotchas

- `init` is safe to re-run on a project that already has PROJECT.yaml — the script will not silently overwrite fields, but the LLM will merge detected values with existing ones.
- `requires_project_yaml: optional` because `init` is the primary use case on net-new repos.
- All other skills treat PROJECT.yaml as **required**; a missing or invalid file will surface as `fix_config` or `fix_error` in downstream commands — run `/project-config init` first.
- **If it fails:** `fix_error` usually means the template is missing or `yq` is not on PATH. Debug with `~/.claude/scripts/project-config.sh --raw validate`.
