---
command: deployment-config
group: deploy
backing_script: ~/.claude/scripts/deployment-config.sh
mutates: []
runtime: ~5s
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

# /deployment-config

> Part of the [Deployment workflow](../08-workflows.md#deployment).

Reads `PROJECT.yaml`, validates the deployment section, and displays the
resolved configuration: environment type, branch names, CI platform,
deployment method, URLs, and current version. Read-only — makes no changes.
Use it to confirm settings before running a deploy or to diagnose a
misconfigured project.

> **Config:** PROJECT.yaml **required** — reads `ci.platform`,
> `ci.branches.staging`, `ci.branches.production`, `deployment.method`,
> `deployment.health_check_path`, `deployment.staging.url`,
> `deployment.production.url`

---

## When to use it

- You want to confirm what branches, URLs, and CI platform a deploy command
  will use before pulling the trigger
- A deploy failed with a configuration error and you need to inspect the
  resolved values
- Setting up a new project and verifying PROJECT.yaml is complete

## Usage

```bash
/deployment-config
```

**Common invocations:**

```bash
/deployment-config           # display full resolved config
/deployment-config --validate  # validate only (no display of values)
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| *(none)* | — | Display full resolved deployment configuration |
| `--validate` | No | Validate PROJECT.yaml structure only; does not print values |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `yq` | Read and validate PROJECT.yaml | `brew install yq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. All fields listed in the frontmatter above.
  Missing required fields are reported in the `warnings` array.
- `PROJECT-KNOWLEDGE.md` (PK) — No

## Backing script

**Script**: `~/.claude/scripts/deployment-config.sh`

**Inputs:** `--full` (main entry), or `--validate` for validation-only mode.
Reads `PROJECT.yaml` from the current directory.

**Outputs (structured JSON):** `next_action` ∈ {`display_summary`,
`fix_error`}, plus `environment_type` (`work` | `home`), `branches.staging`,
`branches.production`, `ci.platform`, `deployment.method`,
`deployment.health_check_path`, `deployment.staging.url`,
`deployment.production.url`, `version`, `warnings[]`.

**Invocation surface:**

```bash
~/.claude/scripts/deployment-config.sh --full        # load + display
~/.claude/scripts/deployment-config.sh --validate    # validate only
~/.claude/scripts/deployment-config.sh --raw --full  # debug: bypass formatting
```

## How it works

1. **Load** — script reads `PROJECT.yaml` and resolves all `deployment.*` and
   `ci.*` keys. Returns `fix_error` immediately if the file is absent or
   unparseable.
2. **Validate** — checks that required fields are present and values are
   internally consistent (e.g., staging URL hostname matches staging branch
   name conventions). Missing optional fields (health path, URLs) are collected
   as `warnings`, not errors.
3. **Environment detection** — auto-detects `environment_type` from the OS:
   macOS → `work` (GitHub Actions, AWS); Linux/WSL → `home` (GitLab CI,
   Unraid/GCP).
4. **Summary** — `display_summary` triggers the LLM to format the resolved
   config in a human-readable table and surface any `warnings` prominently.

## Example workflows

### Scenario: Pre-deploy config check

```
/deployment-config      # confirm branches and URLs
/deploy-risk            # assess risk
/deploy-to-stage        # deploy
```

A quick sanity check before any deployment — confirms the script will target
the right branches and endpoints.

### Scenario: Diagnosing a misconfigured project

```
/deployment-config
```

```
Deployment Configuration
─────────────────────────────────────────
Environment:   work (macOS → GitHub Actions / AWS)
CI Platform:   github
Staging:       staging branch → https://staging.example.com
Production:    main branch    → https://prod.example.com
Method:        pipeline
Health path:   /health
Version:       1.4.2

⚠ Warnings:
  • deployment.production.url not set — version check will be skipped
```

### Scenario: Validate only (CI gate)

```
/deployment-config --validate
```

```
PROJECT.yaml deployment config: valid
  ci.platform: github ✓
  ci.branches.staging: staging ✓
  ci.branches.production: main ✓
  deployment.method: pipeline ✓
```

## Notes & gotchas

- `deployment-config` is read-only. Running it repeatedly is safe and has no
  side effects.
- The `warnings` array distinguishes missing-optional (non-blocking) from
  missing-required (blocking). A warning about `deployment.production.url`
  means version verification will be skipped at deploy time — not that the
  deploy will fail.
- Environment type is detected from the OS, not from PROJECT.yaml. On macOS
  you always get `work`; on Linux/WSL you always get `home`. This mirrors how
  `/deploy-to-stage` and `/deploy-to-prod` auto-select platform and registry.
- If PROJECT.yaml is missing entirely, the script returns `fix_error` with a
  suggestion to run `/project-config init`.
- **If it fails:** run `~/.claude/scripts/deployment-config.sh --raw --full`
  to see the unformatted output and identify which field is causing the parse
  error. Most failures are YAML syntax issues (unquoted colons, missing
  indentation) that `yq` will flag directly.
