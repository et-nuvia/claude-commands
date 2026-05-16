---
command: ci-lint-local
group: code-quality
backing_script: ~/.claude/scripts/ci-lint-local.sh
mutates: []
runtime: ~15-30s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - ci.platform
requires_project_knowledge: none
project_knowledge_sections: []
---

# /ci-lint-local

Validates CI pipeline config, Dockerfiles, and Compose files locally before pushing. Catches syntax errors, policy violations, and misconfigurations that would otherwise burn a pipeline run. Run this before every push that touches CI or Docker files.

> **Config:** PROJECT.yaml optional — reads `ci.platform` to select the correct CI linter (GitHub Actions or GitLab CI).

---

## When to use it

- Before pushing any change to `.github/workflows/`, `.gitlab-ci.yml`, `Dockerfile`, or `docker-compose.yml`
- After editing multiple CI or Docker files to validate all at once
- When a recent push failed a lint stage and you want to reproduce it locally

## Usage

```bash
/ci-lint-local
```

**Common invocations:**

```bash
/ci-lint-local                   # validate all: CI + Dockerfiles + Compose
/ci-lint-local --ci-only         # CI pipeline files only
/ci-lint-local --dockerfiles     # Dockerfiles only
/ci-lint-local --compose         # Compose files only
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--ci-only` | No | Validate CI pipeline files only |
| `--dockerfiles` | No | Validate Dockerfiles only |
| `--compose` | No | Validate docker-compose files only |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `actionlint` | GitHub Actions workflow linting | `brew install actionlint` |
| `gitlab-ci-lint` / `glab` | GitLab CI config validation | `brew install glab` |
| `hadolint` | Dockerfile linting and best-practice checks | `brew install hadolint` |
| `docker compose` | Compose file validation (`config --quiet`) | Docker Desktop / Engine |

Install only what your platform requires (GitHub Actions tools for work, GitLab tools for home).

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `ci.platform` selects the CI linter.
- `.github/workflows/*.yml` — GitHub Actions workflows
- `.gitlab-ci.yml` — GitLab CI config
- `Dockerfile*` — all Dockerfiles in the project
- `docker-compose*.yml` — all Compose files

## Backing script

**Script**: `~/.claude/scripts/ci-lint-local.sh`

**Inputs:** `--full`, `--ci-only`, `--dockerfiles`, `--compose`. Reads `ci.platform` from PROJECT.yaml if present.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`safe_to_push`, `fix_before_push`}
- On `safe_to_push`: warning count (non-blocking)
- On `fix_before_push`: array of errors with `file` and `description` per error

**Invocation surface:**

```bash
~/.claude/scripts/ci-lint-local.sh --full           # all checks
~/.claude/scripts/ci-lint-local.sh --ci-only        # CI only
~/.claude/scripts/ci-lint-local.sh --dockerfiles    # Dockerfiles only
~/.claude/scripts/ci-lint-local.sh --compose        # Compose only
```

No `--raw` flag needed; output is plain text on failure and is readable directly.

## How it works

1. **CI lint** — `actionlint` (GitHub) or `gitlab-ci-lint` (GitLab) validates pipeline YAML structure, step references, and expression syntax.
2. **Dockerfile lint** — `hadolint` checks each Dockerfile for best-practice violations (missing `HEALTHCHECK`, pinned base images, shell quoting, etc.).
3. **Compose validation** — `docker compose config --quiet` parses each Compose file and reports structural errors.
4. **Result** — all findings are aggregated. `safe_to_push` if zero errors (warnings are listed but non-blocking). `fix_before_push` with a per-error list if any errors exist.

Maximum 2 fix-validate cycles per push attempt — if still failing after 2 rounds, stop and ask the user.

## Example workflows

### Scenario: Pre-push gate

```
# after editing .github/workflows/deploy.yml
/ci-lint-local
/git-commit "ci: add staging deploy job"
git push
```

Validate before committing so the pipeline isn't used as a linter.

### Scenario: Errors found

```
/ci-lint-local
```

```
fix_before_push: 2 errors found

  .github/workflows/deploy.yml:34
    Unknown action: actions/upload-artifact@v2 (v3 required)

  Dockerfile.backend:12
    DL3008: Pin versions in apt-get install
```

## Notes & gotchas

- All linters run on the host, not inside Docker — install them via Homebrew (macOS) or apt (WSL).
- The CI platform linter is selected by `ci.platform` in PROJECT.yaml. If PROJECT.yaml is absent, both linters are attempted and results merged.
- Warnings are reported but never block the push — only errors require a fix.
- **If it fails with a tool-not-found error:** install the missing linter (`brew install hadolint`, `brew install actionlint`, etc.) and re-run.
- This command is read-only — it never modifies any file.
