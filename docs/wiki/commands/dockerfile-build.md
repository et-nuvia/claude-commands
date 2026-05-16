---
command: dockerfile-build
group: generators
backing_script: ~/.claude/scripts/dockerfile-build.sh
mutates: [files]
runtime: ~15-30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /dockerfile-build

Detects your project type and generates a production-ready, multi-stage Dockerfile
following DHI base image standards, security hardening rules, and the project's
testing-stage pattern. At the end you have a `Dockerfile` at the project root that
passes the built-in validator and is ready for `docker build`.

---

## When to use it

- Starting a new service that has no Dockerfile yet
- Replacing a hand-written Dockerfile that doesn't meet DHI / hardening standards
- After running `/docker-audit` and finding the current Dockerfile needs a full rewrite

## Usage

```bash
/dockerfile-build
```

**Common invocations:**

```bash
/dockerfile-build                  # default: detect + generate + validate
```

## Arguments

None — invoke with no input. The script auto-detects the project type from
`pyproject.toml`, `package.json`, or `Cargo.toml`. If none is found it falls
back to a Generic template.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `docker` | Required for validating the generated image builds | Docker Desktop / Engine |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No. Detection is purely file-based.
- `pyproject.toml` / `package.json` / `Cargo.toml` — read to identify project type and select the right template
- `Dockerfile` — written here; overwritten without prompt if one already exists

## Backing script

**Script**: `~/.claude/scripts/dockerfile-build.sh`

**Inputs:** No CLI flags beyond stage selectors. Reads `pyproject.toml`,
`package.json`, or `Cargo.toml` from the working directory to determine project
type.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `fix_validation_issues`, `fix_error`}
- `data.dockerfile_path` — path to the written file
- `data.project_type` — detected type (`python`, `nodejs`, `nextjs`, `rust`, `generic`)
- `data.issues[]` — populated when `next_action` is `fix_validation_issues`; each entry has a description of the missing or invalid element

**Invocation surface:**

```bash
~/.claude/scripts/dockerfile-build.sh --full          # detect + generate + validate
~/.claude/scripts/dockerfile-build.sh --detect        # detection only
~/.claude/scripts/dockerfile-build.sh --generate      # generate only (skips detect)
~/.claude/scripts/dockerfile-build.sh --validate      # validate existing Dockerfile
~/.claude/scripts/dockerfile-build.sh --raw --detect  # debug: unformatted output
~/.claude/scripts/dockerfile-build.sh --raw --generate
~/.claude/scripts/dockerfile-build.sh --raw --validate
```

## How it works

1. **Detect** — script scans the working directory for `pyproject.toml`,
   `package.json` (checking for Next.js), or `Cargo.toml` and returns the
   detected project type.
2. **Generate** — selects the matching template; writes a multi-stage
   `Dockerfile` with a `build` stage using the DHI `-dev` image, a `testing`
   stage gated by `ARG RUN_TESTS=false`, and a `production` stage using the
   lean DHI runtime image with no shell and a non-root user.
3. **Validate** — script checks that required structural elements are present:
   multi-stage layout, `AS testing` stage, `ARG RUN_TESTS=false`, and a
   non-root `USER` directive. Returns `fix_validation_issues` with a list of
   failures if any check fails.
4. **Fix loop** — if validation fails, the LLM edits the generated file to
   address each issue in `data.issues[]` and re-runs `--validate` to confirm.
5. **Summarize** — reports the project type and file path, then instructs the
   user to review the `ENTRYPOINT`/`CMD` directives and run a test build.

## Example workflows

### Scenario: New Python service from scratch

```
/project-config init        # create PROJECT.yaml
/dockerfile-build           # generate Dockerfile
/docker-hardening           # layer on security policies
/docker-audit               # confirm score
```

Use this chain when standing up a brand-new service.

### Scenario: Generated Dockerfile output

```
/dockerfile-build
```

```
✓ Dockerfile generated: ./Dockerfile
  Project type: python
  Stages:       build → testing → production
  Base images:  dhi.io/python:3.14-debian13-dev (build)
                dhi.io/python:3.14-debian13 (production)
  Validation:   passed

Review ENTRYPOINT/CMD, then test:
  docker build --build-arg RUN_TESTS=true .
  docker build .
```

## Notes & gotchas

- The generated Dockerfile **overwrites** an existing one without prompting.
  Commit or stash your current Dockerfile before running if you want to keep it.
- DHI runtime images have no shell — `CMD-SHELL` healthchecks will fail.
  Use native TCP/HTTP healthchecks instead (the templates include examples).
- **If it fails (validation):** read `data.issues[]` from the JSON; each entry
  names the missing element. Debug with
  `~/.claude/scripts/dockerfile-build.sh --raw --validate`.
- **If it fails (build test):** the `ENTRYPOINT`/`CMD` almost always needs
  adjusting for the specific application entrypoint — the template uses a
  placeholder.
- Generated files use Node.js `.mjs` entrypoint scripts for Node projects
  because DHI runtime images have no shell for shell-script entrypoints.
