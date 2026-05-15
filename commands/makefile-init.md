---
name: makefile-init
description: Generate hierarchical Makefiles for project automation
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-init" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-init" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Generate hierarchical Makefile structures for multi-component projects.

## Workflow

**1. Preview generation:**
```bash
~/.claude/scripts/generate-makefile.sh --dry-run
```
The script auto-detects components from PROJECT.yaml or directory structure, detects language per component, and previews root + component Makefiles.

**2. Generate or customize:**
- Accept standard: run without `--dry-run`
- Customize first: edit PROJECT.yaml, then `--force`
- Root only: `--root-only`
- Explicit components: `--components "backend:backend:python,frontend:frontend:nodejs"`

**3. Ask me to review** after generating for custom targets or framework-specific needs.

## PROJECT.yaml Configuration

```yaml
components:
  - name: backend
    path: backend
    language: python
    service: backend
  - name: frontend
    path: frontend
    language: nodejs
    service: frontend
```

## Generated Structure

**Root Makefile** (`./Makefile`) — orchestrates all components via delegation:
- Standard targets: `up`, `down`, `test`, `lint`, `format`, `typecheck`, `migrate`, `build`, `clean`, `status`
- Delegates to component Makefiles: `$(MAKE) -C backend test`

**Component Makefiles** — Python backend uses pytest/ruff/pyright; Node.js frontend uses npm/eslint/prettier/tsc. Both include `ci-*` variants (no color, strict mode).

## Troubleshooting

- **No components detected**: Add `components:` to PROJECT.yaml or create `backend/requirements.txt` / `frontend/package.json`
- **Tabs vs spaces error**: Regenerate with `--force` (script preserves tabs); never use spaces in Makefiles
- **Service not found**: Verify service names in `docker-compose.yml` match `service:` in PROJECT.yaml

## LLM-Optimized Output

Generated Makefiles include `FORMAT=json` support for structured output:
- All targets support `FORMAT=json` — auto-detected for AI callers, no need to pass explicitly
- `make help` discovers available operations
- Pass additional args: `make test ARGS="--file tests/test_auth.py"`
- See: [Makefile Standard Reference](docs/reference/makefile-standard.md)

After generating, run `/makefile-optimize` to verify compliance.

## When to Ask Me Instead of the Script

Use the script for standard Python+Node.js setups. Ask me for:
- Custom build tools or non-standard directory layouts
- Multiple backends, multiple frontends, or monorepos with many services
- Cross-component dependencies (e.g., frontend needs generated API client)
- Framework-specific targets (Alembic, Django collectstatic, Next.js standalone)
- Parallel test execution or mutation testing

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-init" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
