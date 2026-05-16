---
command: add-dependency
group: code-quality
backing_script: ~/.claude/scripts/add-dependency.sh
mutates: [files, deps]
runtime: ~30-60s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /add-dependency

Adds a new package dependency after running automated license validation and Trivy security scanning. Blocks on copyleft licenses and critical/high CVEs; warns on unknown licenses and medium vulnerabilities so you can decide before installation proceeds.

---

## When to use it

- Adding any new package to a Python or Node.js project
- You want a gate that catches GPL/LGPL/AGPL licenses before they enter the codebase
- You need to confirm a new package has no known critical vulnerabilities

## Usage

```bash
/add-dependency <package-name>
```

**Common invocations:**

```bash
/add-dependency httpx              # Python package, production
/add-dependency httpx --dev        # Python package, dev dependency
/add-dependency axios --nodejs     # Node.js package
/add-dependency jest --nodejs --dev
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | Yes | Package name to add. Passed as `--package` to the script. |
| `--dev` | No | Install as a development dependency. |
| `--python` | No | Force Python package manager (uv). Auto-detected if omitted. |
| `--nodejs` | No | Force Node.js package manager (npm). Auto-detected if omitted. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `trivy` | Security vulnerability scanning (CVE database) | `brew install trivy` / `apt install trivy` |
| `uv` | Python package installation and pinning | ships in Python DHI images |
| `npm` | Node.js package installation | ships in Node.js DHI images |
| `docker compose` | Run install inside container | Docker Desktop / Engine |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No (language auto-detected from `pyproject.toml` / `package.json`)
- `pyproject.toml` — Python: license check source and install target
- `package.json` — Node.js: license check source and install target

## Backing script

**Script**: `~/.claude/scripts/add-dependency.sh`

**Inputs:** `--full --package <name>`, plus section flags and `--dev`, `--python`, `--nodejs`.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`display_summary`, `find_alternative`, `review_and_decide`, `fix_error`}
- `package`, `version`, `dependency_type`, `is_dev` — on success
- `blocking_reason` — license or CVE detail on `find_alternative`
- `concern` — detail on `review_and_decide` (unknown license, medium CVEs)

**Invocation surface:**

```bash
~/.claude/scripts/add-dependency.sh --full --package "pkg"          # full pipeline
~/.claude/scripts/add-dependency.sh --json --validate --package "pkg"  # license only
~/.claude/scripts/add-dependency.sh --json --security --package "pkg"  # license + scan
~/.claude/scripts/add-dependency.sh --json --add --package "pkg"        # skip checks, install
~/.claude/scripts/add-dependency.sh --json --verify --package "pkg"     # pin version only
~/.claude/scripts/add-dependency.sh --raw --validate --package "pkg"    # debug
```

## How it works

1. **License check** — script looks up the package's SPDX license. Copyleft licenses (GPL, LGPL, AGPL) return `find_alternative` and block installation. Unknown licenses return `review_and_decide`.
2. **Security scan** — Trivy scans the package for CVEs. Critical or High severity returns `find_alternative`. Medium severity returns `review_and_decide` and asks for user approval.
3. **Install** — package is installed inside the Docker container using `uv pip install` (Python) or `npm install` (Node.js). Version is pinned in the lock file.
4. **Summary** — reports package name, resolved version, and dependency type. Prompts to commit the lock file changes.

## Example workflows

### Scenario: Standard dependency addition

```
/add-dependency httpx
/git-commit "chore(deps): add httpx for async HTTP"
```

Clean path: license is MIT, no CVEs, installs and pins.

### Scenario: Blocked by license

```
/add-dependency some-gpl-lib
```

```
License check: GPL-3.0-only  ← copyleft, blocked
Installation cancelled.
Find an alternative with a permissive license (MIT, Apache-2.0, BSD).
```

## Notes & gotchas

- Trivy must be installed on the host (not inside the container) — it scans package metadata before installation.
- Copyleft and critical CVE blocks are hard stops; there is no override flag. Use `--add` to bypass checks only if you have explicit approval to accept the risk.
- **If it fails during security scan:** run `~/.claude/scripts/add-dependency.sh --raw --security --package "pkg"` to see the raw Trivy output.
- **If it fails during install:** run `~/.claude/scripts/add-dependency.sh --raw --add --package "pkg"` to see the package manager output.
- Always commit the updated lock file (`uv.lock` or `package-lock.json`) alongside the dependency change.
