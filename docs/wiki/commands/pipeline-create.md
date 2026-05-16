---
command: pipeline-create
group: generators
backing_script: ~/.claude/scripts/pipeline-create.sh
mutates: [files]
runtime: ~20-45s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - git.platform
  - tech_stack.languages
  - ci.branches
  - docker.registry
requires_project_knowledge: none
project_knowledge_sections: []
---

# /pipeline-create

Generates a ready-to-use CI/CD pipeline file — GitHub Actions workflow or
GitLab CI configuration — from your PROJECT.yaml settings and optional
feature preferences. At the end you have a pipeline that covers the standard
lint → test → security → build → deploy → smoke-test flow with no manual
YAML authoring.

> **Config:** PROJECT.yaml **required** — reads `git.platform`, `tech_stack.languages`,
> `ci.branches`, `docker.registry`. Run `/project-config init` first if PROJECT.yaml
> is missing.

---

## When to use it

- Starting a new project that has no CI/CD pipeline yet
- Switching platforms (e.g., migrating from GitLab CI to GitHub Actions)
- After `/pipeline-audit` scores below 50 and recommends a full regeneration

## Usage

```bash
/pipeline-create
```

**Common invocations:**

```bash
/pipeline-create                        # default: auto-detect platform, interactive preferences
/pipeline-create --platform github      # force GitHub Actions output
/pipeline-create --platform gitlab      # force GitLab CI output
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--platform <github\|gitlab>` | No | Override platform auto-detection from PROJECT.yaml |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `gh` | Validate reusable workflow refs (GitHub platform) | `brew install gh` |
| `glab` | Validate include refs (GitLab platform) | install per platform docs |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `yq` | Parse YAML in generated file validation | `brew install yq` |

Only the tool matching your platform is required; the other can be absent.

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `git.platform`, `tech_stack.languages`,
  `ci.branches`, `docker.registry`. Missing keys trigger a `prompt_user`
  response directing you to `/project-config init`.
- `.github/workflows/deploy.yml` (GitHub) or `.gitlab-ci.yml` (GitLab) — written here

## Backing script

**Script**: `~/.claude/scripts/pipeline-create.sh`

**Inputs:** `--full` (default), or stage flags. Optional `--platform
<github|gitlab>` overrides PROJECT.yaml detection. Reads PROJECT.yaml for
all configuration.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `prompt_user`, `generate_pipeline`, `fix_error`}
- `pipeline_file` — path to the written pipeline file
- `section` — populated on `prompt_user`; indicates what is missing (`detect`, `gather`, `preferences`)
- `stages` — list of stages included in the generated pipeline
- `features` — key features enabled (security scanning, E2E, notifications, migrations)

**Invocation surface:**

```bash
~/.claude/scripts/pipeline-create.sh --full               # detect + gather + preferences + generate
~/.claude/scripts/pipeline-create.sh --detect             # platform detection only
~/.claude/scripts/pipeline-create.sh --gather             # load project info from PROJECT.yaml
~/.claude/scripts/pipeline-create.sh --preferences        # collect optional feature preferences
~/.claude/scripts/pipeline-create.sh --generate           # generate pipeline file (after preferences)
~/.claude/scripts/pipeline-create.sh --raw --detect       # debug: unformatted output
```

## How it works

1. **Detect** — script reads `git.platform` from PROJECT.yaml (or the `--platform`
   flag) to determine whether to emit GitHub Actions or GitLab CI syntax.
   Returns `prompt_user` with `section: detect` if neither can be resolved.
2. **Gather** — loads `tech_stack.languages`, `ci.branches`, and
   `docker.registry` from PROJECT.yaml. Returns `prompt_user` with
   `section: gather` if PROJECT.yaml is missing entirely.
3. **Preferences** — script returns `prompt_user` with `section: preferences`;
   LLM asks the user which optional stages to include: security scanning,
   E2E tests, Slack/email notifications, database migrations.
4. **Generate** — with all inputs resolved, script writes the pipeline file.
   GitHub output lands in `.github/workflows/deploy.yml`; GitLab output in
   `.gitlab-ci.yml`. The generated pipeline follows the project's branch
   strategy: PR branches get lint + test only; staging branch adds security +
   build + deploy + smoke test; production branch promotes the existing image
   rather than rebuilding.
5. **Summarize** — reports platform, file path, included stages, and next steps:
   configure CI/CD secrets in the platform UI, commit the file, push to
   trigger the first run.

## Example workflows

### Scenario: New project, full setup chain

```
/project-config init        # create PROJECT.yaml
/dockerfile-build           # generate Dockerfile
/pipeline-create            # generate CI/CD pipeline
/pipeline-audit             # verify score before first push
/git-commit                 # commit generated files
```

Use this sequence when standing up a new service from scratch.

### Scenario: Generated pipeline summary

```
/pipeline-create
```

```
✓ Pipeline generated: .github/workflows/deploy.yml
  Platform:  github-actions
  Stages:    lint → test → security → build → deploy → smoke-test
  Features:  Trivy security scan, E2E tests, Slack notifications
  Registry:  123456789.dkr.ecr.us-east-1.amazonaws.com/nuvia-api

Next steps:
  1. Add secrets to GitHub repository settings:
       AWS_ACCOUNT_ID, SLACK_WEBHOOK_URL
  2. git add .github/workflows/deploy.yml && git commit
  3. Push to trigger the first pipeline run
```

## Notes & gotchas

- Generated pipelines follow the **build-once, promote** pattern: staging
  builds and tags the image; production re-tags and deploys the same artifact.
  Do not manually edit to rebuild on the production branch.
- The pipeline file **does not** handle secrets values — it references secret
  names. Configure the actual secrets in GitHub Settings → Secrets or GitLab
  CI/CD → Variables before pushing.
- For non-standard setups (monorepos, custom build tools, multiple deployment
  targets), provide requirements to the LLM before running so it can adjust
  the preferences answers accordingly.
- **If it fails (detect):** platform cannot be inferred — run with
  `--platform github` or `--platform gitlab` explicitly.
- **If it fails (gather):** PROJECT.yaml is missing or incomplete — run
  `/project-config init` then retry.
- **If it fails (generate):** debug with
  `~/.claude/scripts/pipeline-create.sh --raw --detect` to see unformatted
  script output.
- Run `/pipeline-audit` after generating to get a scored baseline and identify
  any gaps before the first real deployment.
