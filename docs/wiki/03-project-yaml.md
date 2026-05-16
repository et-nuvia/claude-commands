# PROJECT.yaml

Every project that uses these commands has a `PROJECT.yaml` at its root.
Scripts auto-read it to learn the project's identity, tech stack, testing
config, deployment targets, task management backend, and secrets layout. If
a command's wiki page says `requires_project_yaml: required`, the script
will not run without these fields present.

- **Schema (source of truth)**: [`schemas/project.schema.json`](../../schemas/project.schema.json)
- **Fully-populated example**: [`templates/PROJECT.yaml.example`](../../templates/PROJECT.yaml.example)
- **Bootstrap a new file**: `/project-config` ([wiki](commands/project-config.md))

> **Tip.** Each command wiki page declares the exact `project_yaml_fields`
> it reads. When a script errors with "field missing," cross-reference the
> command's page rather than guessing at the schema.

---

## Required fields

Only three keys are required at the top level:

| Field | Purpose |
|---|---|
| `name` | Project identifier — used in container names, CI job names, secret paths |
| `testing` | Test command + coverage requirements (see below) |
| `secrets` | Secrets backend selection (`aws` or `infisical`) |

Everything else is optional. Add sections as the commands that need them
come into play.

## Top-level sections

| Section | Required? | Used by |
|---|---|---|
| `name` | ✅ | All commands |
| `description` | optional | Catalog metadata only |
| `version_source` / `version_file` | optional | `get-version.sh`, deploy commands |
| `languages` | optional | `dockerfile-build`, `add-dependency`, `format` |
| `components` | optional | `makefile-init`, monorepo-aware commands |
| `testing` | ✅ | All test runners, audits, `task-continue` |
| `quality` | optional | `format`, `ci-lint-local` |
| `docker` | optional | `dockerfile-build`, `docker-audit`, `task-start` (boots services) |
| `git` | optional | `create-pr`, `review-pr`, platform detection |
| `ci` | optional | `pipeline-audit`, `pipeline-create`, deploy commands |
| `secrets` | ✅ | `setup-secrets`, `rotate-secret`, all runtime secret fetches |
| `databases` | optional | `db-*` commands, secret bucket layout |
| `deployment` | optional | `deploy-to-stage`, `deploy-to-prod`, `deployment-config` |
| `smoke_tests` | optional | Deploy commands (post-deploy verification) |
| `task_management` | optional | `task-capture`, `task-start`, `task-close`, etc. |
| `notifications` | optional | Deploy and incident commands |
| `infrastructure` | optional | `infra-*` commands |
| `commands` | optional | Custom command tuning |
| `docs_dir` | optional (default: `docs`) | All document-producing commands (TSK, PLN, RCA, …) |
| `schema_sync` | optional | `db-schema-sync` |

## Minimal example

```yaml
name: "my-service"
testing:
  command: "make test"
  min_coverage: 80
secrets:
  backend: "infisical"
```

That's a valid `PROJECT.yaml`. Commands that need more (deploys, task
management, infra) will tell you exactly which fields to add — see each
command's wiki page.

## Field-by-field reference

The schema in [`schemas/project.schema.json`](../../schemas/project.schema.json)
is authoritative — every field has a `description` and constraint there.
Skim the schema once; don't try to memorize it. The wiki pages for the
commands you actually run are the practical lookup.

### `testing` (required)

```yaml
testing:
  command: "make test"
  coverage_command: "make test-coverage"   # optional
  e2e_command: "make test-e2e"             # optional
  min_coverage: 80
```

### `secrets` (required)

```yaml
secrets:
  backend: "aws"        # or "infisical"
  required:
    - database
    - redis
    - api-keys
```

`required` lists the secret buckets the project depends on. `/setup-secrets`
creates and populates them; `/rotate-secret` rotates within them.

### `task_management` (when using `/task-*`)

```yaml
# Work (macOS): Asana
task_management:
  backend: "asana"
  asana:
    workspace_id: "1234567890123456"
    project: "Engineering"
    section: "To Do"

# Home (Linux): GitLab
task_management:
  backend: "gitlab"
  gitlab:
    project_id: "group/my-service"
    default_labels: ["backend", "task"]
```

### `ci` + `git` (when using deploy and PR commands)

```yaml
git:
  platform: "github"
  instance: "github.com"
  repo: "owner/my-service"

ci:
  platform: "github"
  branches:
    staging: "dev"
    production: "main"
```

### `deployment` (when using `/deploy-*`)

```yaml
deployment:
  method: "ssh"           # script | ssh | ssm | pipeline
  health_check_path: "/health"
  staging:
    url: "https://staging.example.com"
    host: "staging.example.com"
    user: "deploy"
    path: "/opt/app"
  production:
    url: "https://example.com"
    host: "prod.example.com"
    user: "deploy"
    path: "/opt/app"
```

Conditional rules in the schema enforce that `method: ssh` requires
`host`/`user`/`path`, `method: ssm` requires AWS specifics, etc. The
validator catches missing fields before a deploy starts.

### `databases` (when using `/db-*`)

Each entry declares users (DDL `migration` user + DML `app` user), the
secret bucket that holds their credentials, and migration tooling. See the
[example template](../../templates/PROJECT.yaml.example) for a full entry.

### `infrastructure` (when using `/infra-*`)

```yaml
infrastructure:
  enabled: true
  repo:
    type: "git"
    url: "https://github.com/owner/infrastructure.git"
    branch: "main"
  link:
    target: "infrastructure"
    source: "terraform/app"
  tools:
    - name: "terraform"
      enabled: true
      version: "1.6.0"
      backend: "s3"
      workspaces:
        development: "dev"
        staging: "staging"
        production: "prod"
```

## Validating the file

`/project-config` validates the file against the schema:

```
/project-config show       # display current config + validation status
/project-config validate   # explicit validation pass
```

Schema validation runs automatically inside many scripts; an error message
will point you at the offending field path.

## Cross-references

- Per-command field requirements: each [command wiki page](commands/) lists
  its `project_yaml_fields` in the frontmatter
- Catalog of commands by group: [04-command-catalog.md](04-command-catalog.md)
- Schema source: [`schemas/project.schema.json`](../../schemas/project.schema.json)
- Template: [`templates/PROJECT.yaml.example`](../../templates/PROJECT.yaml.example)
