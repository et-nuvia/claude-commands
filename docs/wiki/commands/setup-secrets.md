---
command: setup-secrets
group: project-config
backing_script: ~/.claude/scripts/setup-secrets.sh
mutates: [infisical, files]
runtime: ~30-90s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - name
  - secrets.backend
  - secrets.required
  - secrets.infisical.project_id
requires_project_knowledge: none
project_knowledge_sections: []
---

# /setup-secrets

Provisions the complete secrets infrastructure for a project: creates the
Infisical project and folder structure, populates initial secret values,
configures machine identity access, creates the local `.secrets/` bootstrap
directory, and validates that `docker-compose.yml` matches the standard
pattern. Run once when bootstrapping a new service; re-run `--validate` at any
time to confirm nothing has drifted.

> **Config:** PROJECT.yaml **required** — reads `name` (used as Infisical project name), `secrets.backend`, `secrets.required` (bucket names), and optionally `secrets.infisical.project_id`.

> **Note:** This command writes secrets to Infisical and creates files in `.secrets/`. While not destructive in the "data loss" sense, running `--populate` against an existing project will overwrite secret values. Confirm the target project ID before populating a production environment.

---

## When to use it

- Bootstrapping a new project that has PROJECT.yaml but no secrets backend yet
- Validating that an existing project's Infisical setup matches the standard
- Fixing a docker-compose.yml that uses env vars instead of secret files

## Usage

```bash
/setup-secrets [operation]
```

**Common invocations:**

```bash
/setup-secrets                  # default: --full (all sections)
/setup-secrets validate         # check existing setup without changes
/setup-secrets create-project   # create the Infisical project only
/setup-secrets populate         # populate secret values (after folders exist)
/setup-secrets local-setup      # create local .secrets/ directory
/setup-secrets verify           # verify docker-compose + connectivity
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `operation` | No | One of `full`, `validate`, `create-project`, `create-folders`, `populate`, `local-setup`, `verify`. Defaults to `full`. |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `infisical` CLI | Authenticate and manage Infisical projects/secrets | [infisical.com/docs/cli](https://infisical.com/docs/cli/overview) |
| `jq` | Build and consume the result JSON | `brew install jq` / `apt install jq` |
| `yq` | Parse and validate docker-compose.yml | `brew install yq` |
| `curl` | Infisical API calls during project creation | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `name`, `secrets.backend`, `secrets.required`. Optional: `secrets.infisical.project_id`.
- `~/.infisical/` — machine identity credentials directory (required for auth)
- `docker-compose.yml` — read and validated during `--verify`; may be edited to fix issues
- `.secrets/` — created by `--local-setup`; gitignored; holds bootstrap credential files

## Backing script

**Script**: `~/.claude/scripts/setup-secrets.sh`

**Inputs:** stage flag (parsed from `$ARGUMENTS`). Reads PROJECT.yaml for
project config; reads `~/.infisical/` for machine identity credentials.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `gather_secret_values`, `confirm_action`, `fix_config`, `fix_error`, `fix_compose`}
- `message` — human-readable status
- `missing_secrets[]` — on `gather_secret_values`: `{folder, key}` pairs
- `issues[]` — on `fix_compose`: docker-compose problems to correct

**Invocation surface:**

```bash
~/.claude/scripts/setup-secrets.sh --full
~/.claude/scripts/setup-secrets.sh --validate
~/.claude/scripts/setup-secrets.sh --create-project
~/.claude/scripts/setup-secrets.sh --create-folders
~/.claude/scripts/setup-secrets.sh --populate
~/.claude/scripts/setup-secrets.sh --local-setup
~/.claude/scripts/setup-secrets.sh --verify
~/.claude/scripts/setup-secrets.sh --raw --full       # debug: bypass formatting
```

## How it works

1. **Config check** — script reads PROJECT.yaml; if `secrets.backend` or
   `secrets.required` are missing, returns `fix_config` and halts. LLM directs
   the user to `/project-config` first.
2. **Authenticate** — script uses machine identity credentials from
   `~/.infisical/` to authenticate with the Infisical API.
3. **Create project** — if the Infisical project doesn't exist, returns
   `confirm_action` with what will be created. LLM asks for confirmation; after
   approval, re-runs with `--create-project`.
4. **Create folders** — provisions one Infisical folder per bucket in
   `secrets.required` (e.g., `/database`, `/redis`, `/api-keys`).
5. **Gather secrets** — if folders are empty, returns `gather_secret_values`
   with the list of missing keys. LLM presents them to the user, collects
   values (generating random ones for session/JWT secrets), then re-runs
   `--populate` with the values.
6. **Local setup** — creates the `.secrets/` directory with the four Infisical
   bootstrap files (`infisical_url`, `infisical_client_id`,
   `infisical_client_secret`, `infisical_project_id`).
7. **Verify** — reads `docker-compose.yml` and checks it follows the standard
   secrets pattern (secret files, not env vars; correct `SECRETS_PATH` default).
   Returns `fix_compose` with a `issues[]` list if anything is wrong; LLM
   applies fixes with the Edit tool.

## Example workflows

### Scenario: Full bootstrap of a new project

```
/project-config init        # PROJECT.yaml must exist first
/setup-secrets              # provision Infisical + local .secrets/
/task-start 1               # env now boots with secrets
```

### Scenario: Validate after config changes

```
/setup-secrets validate
```

Safe to run any time — validate makes no changes.

### Scenario: Full run output

```
/setup-secrets
```

```
Secrets setup complete:
  Infisical project: nuvia-api (id: abc123)
  Folders created:   /database, /redis, /api-keys
  Secrets populated: 8 keys across 3 folders
  .secrets/ status:  4 bootstrap files written
  docker-compose:    valid (secret file pattern confirmed)

Next: docker compose up — services will fetch secrets from Infisical at startup.
```

## Notes & gotchas

- **Blast radius on `--populate`:** running populate against an already-configured project overwrites existing secret values in Infisical. Double-check the project ID shown in `confirm_action` before proceeding — a wrong project ID could overwrite a production environment.
- `secrets.backend` must be `"infisical"` in PROJECT.yaml for this command. For AWS Secrets Manager projects (work/macOS), use the AWS-specific setup workflow instead.
- `.secrets/` is gitignored globally. Never commit bootstrap credentials.
- Machine identity credentials in `~/.infisical/` must be provisioned manually before first use — the command cannot self-bootstrap these.
- **If it fails (`fix_error`):** missing credentials → ensure `~/.infisical/` directory contains valid client ID and secret. Infisical unreachable → check VPN or Infisical instance URL. Debug with `~/.claude/scripts/setup-secrets.sh --raw --full`.
