---
command: upgrade-dependencies
group: code-quality
backing_script: ~/.claude/scripts/upgrade-dependencies.sh
mutates: [files, deps]
runtime: ~2-10min
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - testing.command
requires_project_knowledge: none
project_knowledge_sections: []
---

# /upgrade-dependencies

Upgrades Python and/or Node.js dependencies to their latest compatible versions using a remove-pins → resolve → test → security-scan → re-pin pipeline. Any package that causes test failures or security issues is pinned with an explanatory comment rather than silently left behind.

> **Config:** PROJECT.yaml optional — reads `testing.command` to run tests after resolution.

---

## When to use it

- Routine dependency maintenance (monthly or before a major release)
- After a CVE advisory that requires upgrading a specific package
- When `uv pip install --upgrade` or `npm outdated` shows a long list of stale packages

## Usage

```bash
/upgrade-dependencies
```

**Common invocations:**

```bash
/upgrade-dependencies             # upgrade all detected languages
```

## Arguments

None — invoke with no input. Language is auto-detected from `pyproject.toml` and/or `package.json`.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `trivy` | Security scan after resolution | `brew install trivy` / `apt install trivy` |
| `uv` | Python dependency resolution and pinning | ships in Python DHI images |
| `npm` | Node.js dependency resolution and pinning | ships in Node.js DHI images |
| `docker compose` | Run install and tests inside containers | Docker Desktop / Engine |
| `make` | Run `make test` for validation | `apt install make` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `testing.command` used to validate after upgrade.
- `pyproject.toml` — Python: version pins removed then re-pinned after resolution
- `package.json` — Node.js: version specifiers set to `latest` then pinned after resolution
- `uv.lock` / `package-lock.json` — updated in place

## Backing script

**Script**: `~/.claude/scripts/upgrade-dependencies.sh`

**Inputs:** `--full`, plus per-language and per-step flags. Reads `pyproject.toml` and `package.json` to detect languages.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`edit_dependency_files`, `continue_upgrade_pipeline`, `fix_error`}
- `section` — which step is active (e.g., `python`, `python-test`, `nodejs-security`)
- `details.packages` — resolved versions to pin (on `*-versions` sections)
- `details.log` — error output on `fix_error`

**Invocation surface:**

```bash
~/.claude/scripts/upgrade-dependencies.sh --full
~/.claude/scripts/upgrade-dependencies.sh --json --python
~/.claude/scripts/upgrade-dependencies.sh --json --python-resolve
~/.claude/scripts/upgrade-dependencies.sh --json --python-test
~/.claude/scripts/upgrade-dependencies.sh --json --python-security
~/.claude/scripts/upgrade-dependencies.sh --json --python-versions
~/.claude/scripts/upgrade-dependencies.sh --json --nodejs
~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-resolve
~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-test
~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-security
~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-versions
~/.claude/scripts/upgrade-dependencies.sh --raw --python   # debug
```

## How it works

The pipeline runs once per language detected (Python then Node.js if both present):

1. **Remove pins** — LLM edits `pyproject.toml` (Python) or sets all deps to `"latest"` in `package.json` (Node.js), preserving any lines with a `# PINNED:` comment.
2. **Resolve** — `uv sync` or `npm install` resolves the latest compatible set inside the container.
3. **Test** — `make test` runs the project's test suite against the new versions. A failure means at least one package introduced a regression.
4. **Security scan** — Trivy scans the resolved set. Critical/High CVEs ask the user to choose: find an alternative, accept the risk, or pin the previous version.
5. **Re-pin** — LLM writes the exact resolved versions back into the manifest file. Forced pins include a `# PINNED: reason` comment for future reference.

If `fix_error` fires during resolve or test, identify the incompatible package from `details.log`, add a `# PINNED:` comment for it, and restart the resolve step.

## Example workflows

### Scenario: Monthly maintenance

```
/upgrade-dependencies
/git-commit "chore(deps): upgrade Python and Node.js dependencies"
/create-pr
```

Full upgrade, tested, scanned, and committed in one workflow.

### Scenario: Security vulnerability mid-pipeline

```
/upgrade-dependencies
```

```
python-security: 1 HIGH vulnerability found
  Package: cryptography 41.0.0
  CVE-2024-0727  HIGH  …
Options: [find alternative / accept risk / pin previous version]
```

## Notes & gotchas

- Lines with `# PINNED:` in `pyproject.toml` or `package.json` are never touched — use this comment to protect packages that must stay at a specific version.
- The pipeline is sequential within each language; Python and Node.js do not run in parallel.
- **If resolve fails:** read `details.log` for the incompatible package name. Add a `# PINNED: incompatible with X` comment for it, then re-run `--python-resolve` or `--nodejs-resolve`.
- **If tests fail after upgrade:** use `~/.claude/scripts/upgrade-dependencies.sh --raw --python-test` to see the full test output and identify the breaking package.
- Trivy must be installed on the host, not inside the container.
