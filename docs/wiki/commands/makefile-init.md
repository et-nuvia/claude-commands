---
command: makefile-init
group: generators
backing_script: ~/.claude/scripts/generate-makefile.sh
mutates: [files]
runtime: ~10-20s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - components[].name
  - components[].path
  - components[].language
  - components[].service
requires_project_knowledge: none
project_knowledge_sections: []
---

# /makefile-init

Generates a hierarchical Makefile structure for your project — a root
orchestrator that delegates to per-component Makefiles for backend, frontend,
and any other service. At the end every standard operation (`test`, `lint`,
`format`, `build`, `up`, `down`) is reachable from one place, and all targets
emit structured JSON for LLM callers automatically.

> **Config:** PROJECT.yaml **optional** — reads `components[].{name, path, language, service}`.
> When PROJECT.yaml is absent or has no `components:` block, the script
> auto-detects components from directory structure and framework marker files.

---

## When to use it

- Setting up a new project that has no `Makefile` yet
- Replacing ad-hoc shell scripts with a standard target hierarchy
- After adding a new service to an existing project that needs its own component Makefile

## Usage

```bash
/makefile-init [arguments]
```

**Common invocations:**

```bash
/makefile-init                                                      # dry-run preview, then generate
/makefile-init --force                                              # regenerate without preview
/makefile-init --root-only                                          # generate only the root Makefile
/makefile-init --components "backend:backend:python,frontend:frontend:nodejs"  # explicit components
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--dry-run` | No | Preview what would be generated without writing files (default first step) |
| `--force` | No | Overwrite existing Makefiles without prompting |
| `--root-only` | No | Generate only the root `./Makefile`, skip component Makefiles |
| `--components <spec>` | No | Explicit component list: `name:path:language` triples, comma-separated |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `make` | Required to run the generated targets | `brew install make` / `apt install make` |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `components:` block defines names, paths, languages, and Docker service names. Without it, the script infers components from `backend/requirements.txt`, `frontend/package.json`, etc.
- `docker-compose.yml` — read to cross-reference service names so generated targets match actual container names
- `Makefile` (root) and `<component>/Makefile` — written here; overwritten with `--force`

## Backing script

**Script**: `~/.claude/scripts/generate-makefile.sh`

**Inputs:** `--dry-run`, `--force`, `--root-only`, `--components <spec>`.
Reads `PROJECT.yaml` for `components[]` config; falls back to filesystem
detection when absent.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `fix_error`}
- `data.components[]` — list of detected/configured components with `name`, `path`, `language`, `service`
- `data.files_written[]` — paths of generated Makefile files
- `data.dry_run_preview` — rendered preview text when `--dry-run` is passed

**Invocation surface:**

```bash
~/.claude/scripts/generate-makefile.sh --dry-run               # preview
~/.claude/scripts/generate-makefile.sh                          # generate
~/.claude/scripts/generate-makefile.sh --force                  # regenerate (overwrite)
~/.claude/scripts/generate-makefile.sh --root-only              # root only
~/.claude/scripts/generate-makefile.sh --components "..."       # explicit spec
~/.claude/scripts/generate-makefile.sh --raw --dry-run          # debug: unformatted output
```

## How it works

1. **Dry-run preview** — script detects or reads component config, renders a
   preview of the root and each component Makefile, and returns
   `data.dry_run_preview`. The LLM presents this to the user and asks whether
   to accept, customize, or cancel.
2. **Customization branch** — if the user wants changes, the LLM helps edit
   `PROJECT.yaml` to add or adjust the `components:` block, then reruns with
   `--force`.
3. **Generate** — script writes `Makefile` at the repo root and one
   `<component>/Makefile` per detected component. Python components get
   pytest/ruff/pyright targets; Node.js components get npm/eslint/prettier/tsc
   targets. All targets include `ci-*` variants (no color, strict mode).
4. **JSON support injection** — every generated target includes `FORMAT=json`
   auto-detection so LLM callers get structured output without passing flags.
5. **Post-generate review** — LLM offers to run `/makefile-optimize` to verify
   compliance and flag any non-standard targets the project needs.

## Example workflows

### Scenario: New multi-service project

```
/project-config init        # create PROJECT.yaml with components
/makefile-init              # generate Makefile hierarchy
/makefile-optimize          # verify compliance
```

Standard setup chain for a new backend + frontend project.

### Scenario: Dry-run preview

```
/makefile-init
```

```
Makefile Preview (dry run)
──────────────────────────
Components detected: backend (python), frontend (nodejs)
Files to create:
  ./Makefile
  backend/Makefile
  frontend/Makefile

Root targets: up, down, test, lint, format, typecheck, migrate, build, clean, status
backend targets: test, test-unit, test-integration, lint, format, typecheck, migrate, ci-test, ci-lint
frontend targets: test, lint, format, typecheck, build, ci-test, ci-lint

Accept and generate? [Yes / Customize / Cancel]
```

## Notes & gotchas

- Makefiles require **tabs** for recipe indentation — never spaces. The script
  preserves tabs; if you hand-edit and introduce spaces you'll get
  `*** missing separator` errors. Regenerate with `--force` to fix.
- **No components detected:** add a `components:` block to `PROJECT.yaml`, or
  ensure framework marker files exist (`backend/requirements.txt`,
  `frontend/package.json`).
- **Service not found errors at runtime:** verify that `service:` names in
  `PROJECT.yaml` match service names in `docker-compose.yml` exactly.
- For non-standard setups (monorepos, custom build tools, cross-component
  deps), provide the requirements directly rather than relying on auto-detect.
- **If it fails:** debug with
  `~/.claude/scripts/generate-makefile.sh --raw --dry-run` to inspect the raw
  detection output and confirm components are identified correctly.
