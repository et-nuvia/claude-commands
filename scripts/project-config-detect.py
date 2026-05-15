#!/usr/bin/env python3
"""
project-config-detect.py - Auto-detect PROJECT.yaml values from the current project.

Scans the filesystem, git config, and environment to build a structured JSON
detection report. The LLM uses this to walk users through PROJECT.yaml setup,
only asking for values that couldn't be auto-detected.

Usage:
    uv run ~/.claude/scripts/project-config-detect.py [--root PATH]

Output: JSON detection report (see schema below)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


_PROFILE_PATH_RE = re.compile(r"^\.[A-Za-z_][A-Za-z0-9_.]*$")


def _profile_get_env(yaml_path: str) -> str:
    """Read a value from the active profile's current environment block.

    Shells out to lib/load-profile.sh because the profile schema and
    resolution rules live there. Returns "" on any failure — callers
    should treat absence as "fall back to generic public defaults".

    yaml_path is validated against a strict regex before invocation and
    passed as a positional bash arg, so it cannot be interpreted as
    shell syntax even if a future caller plumbs user input through.
    """
    if not _PROFILE_PATH_RE.match(yaml_path):
        return ""
    lib = Path(__file__).parent / "lib" / "load-profile.sh"
    if not lib.exists():
        return ""
    try:
        result = subprocess.run(
            ["bash", "-c", f'source "{lib}" && profile_env_get "$1"', "_", yaml_path],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (subprocess.SubprocessError, OSError):
        return ""


# ── Detection helpers ─────────────────────────────────────────────────────────

def detected(value: Any, source: str, confidence: str = "high") -> dict:
    """Create a detected-value entry."""
    return {"value": value, "source": source, "confidence": confidence}


def run(cmd: list[str], cwd: Path | None = None) -> str:
    """Run a command and return stdout, empty string on failure."""
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=5, cwd=cwd
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ""


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def read_toml(path: Path) -> dict:
    """Parse TOML without requiring toml library — extract key=value patterns."""
    result: dict[str, Any] = {}
    try:
        text = path.read_text()
        # Extract [section] blocks and key = "value" pairs (basic, not full TOML)
        section = ""
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("[") and not line.startswith("[["):
                section = line[1:-1].strip()
                result.setdefault(section, {})
            elif "=" in line and not line.startswith("#"):
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                if section:
                    result.setdefault(section, {})[key] = val
                else:
                    result[key] = val
    except Exception:
        pass
    return result


def read_yaml_services(path: Path) -> list[str]:
    """Extract service names from a docker-compose file."""
    try:
        import yaml  # pyyaml - available via uv run --with pyyaml
        data = yaml.safe_load(path.read_text()) or {}
        services = data.get("services", {}) or {}
        return list(services.keys())
    except Exception:
        # Fallback: regex parse
        services = []
        try:
            text = path.read_text()
            in_services = False
            for line in text.splitlines():
                if line.strip() == "services:":
                    in_services = True
                    continue
                if in_services:
                    m = re.match(r"^  ([a-z][a-z0-9_-]+)\s*:", line)
                    if m:
                        services.append(m.group(1))
                    elif line and not line.startswith(" ") and not line.startswith("#"):
                        break
        except Exception:
            pass
        return services


def read_makefile_targets(path: Path) -> list[str]:
    """Extract target names from a Makefile."""
    targets = []
    try:
        text = path.read_text()
        for line in text.splitlines():
            m = re.match(r"^([a-zA-Z][a-zA-Z0-9_-]*)\s*:", line)
            if m and not m.group(1).startswith("."):
                targets.append(m.group(1))
    except Exception:
        pass
    return targets


# ── Individual detectors ─────────────────────────────────────────────────────

def detect_name_and_description(root: Path) -> tuple[dict | None, dict | None]:
    name = desc = None

    # package.json
    pkg = read_json(root / "package.json")
    if pkg.get("name"):
        name = detected(pkg["name"], "package.json")
    if pkg.get("description"):
        desc = detected(pkg["description"], "package.json")

    if not name or not desc:
        # pyproject.toml
        toml = read_toml(root / "pyproject.toml")
        project = toml.get("project", {})
        tool_poetry = toml.get("tool.poetry", {})
        src = project or tool_poetry
        if not name and src.get("name"):
            name = detected(src["name"], "pyproject.toml")
        if not desc and src.get("description"):
            desc = detected(src["description"], "pyproject.toml")

    if not name:
        # go.mod
        gomod = root / "go.mod"
        if gomod.exists():
            text = gomod.read_text()
            m = re.search(r"^module\s+(\S+)", text, re.MULTILINE)
            if m:
                # Use just the last path component as the name
                name = detected(m.group(1).split("/")[-1], "go.mod")

    if not name or not desc:
        # Cargo.toml
        toml = read_toml(root / "Cargo.toml")
        pkg_section = toml.get("package", {})
        if not name and pkg_section.get("name"):
            name = detected(pkg_section["name"], "Cargo.toml")
        if not desc and pkg_section.get("description"):
            desc = detected(pkg_section["description"], "Cargo.toml")

    if not name:
        name = detected(root.name, "directory", confidence="medium")

    return name, desc


def detect_languages(root: Path) -> list[dict]:
    langs = []

    # Python — check root first, then common backend subdirectories
    pyproject = root / "pyproject.toml"
    requirements = root / "requirements.txt"
    # Also look in common subdirectory layouts (monorepo / full-stack projects)
    py_subdir_pyproject = None
    py_subdir_name = None
    for subdir in ["backend", "api", "src", "app"]:
        candidate = root / subdir / "pyproject.toml"
        if candidate.exists():
            py_subdir_pyproject = candidate
            py_subdir_name = subdir
            break

    if pyproject.exists() or requirements.exists() or py_subdir_pyproject:
        version = None
        # Determine which pyproject.toml to read for version
        primary_pyproject = pyproject if pyproject.exists() else py_subdir_pyproject
        source = (
            "pyproject.toml" if pyproject.exists()
            else f"{py_subdir_name}/pyproject.toml" if py_subdir_pyproject
            else "requirements.txt"
        )
        if primary_pyproject and primary_pyproject.exists():
            toml = read_toml(primary_pyproject)
            req_python = (
                toml.get("project", {}).get("requires-python", "")
                or toml.get("tool", {}).get("poetry", {}).get("python", "")
            )
            m = re.search(r"(\d+\.\d+)", req_python)
            if m:
                version = m.group(1)
        # Check .python-version file
        pv = root / ".python-version"
        if not version and pv.exists():
            version = pv.read_text().strip()
            source = ".python-version"
        entry: dict[str, Any] = {"name": "python", "source": source, "confidence": "high"}
        if version:
            entry["version"] = version
        if py_subdir_name and not pyproject.exists():
            entry["root"] = py_subdir_name
        langs.append(entry)

    # TypeScript / JavaScript
    pkg_json = root / "package.json"
    if pkg_json.exists():
        lang = "typescript" if (root / "tsconfig.json").exists() else "javascript"
        pkg = read_json(pkg_json)
        version = pkg.get("engines", {}).get("node") or pkg.get("engines", {}).get("typescript")
        # Check for frontend subdir
        ts_root = None
        for subdir in ["frontend", "web", "client", "ui"]:
            if (root / subdir / "package.json").exists():
                ts_root = subdir
                break
        entry = {"name": lang, "source": "package.json", "confidence": "high"}
        if version:
            entry["version"] = re.sub(r"[^0-9.]", "", version).strip(".")
        if ts_root:
            entry["root"] = ts_root
        langs.append(entry)

    # Go
    gomod = root / "go.mod"
    if gomod.exists():
        text = gomod.read_text()
        m = re.search(r"^go\s+(\d+\.\d+)", text, re.MULTILINE)
        entry: dict[str, Any] = {"name": "go", "source": "go.mod", "confidence": "high"}
        if m:
            entry["version"] = m.group(1)
        langs.append(entry)

    # Rust
    cargo = root / "Cargo.toml"
    if cargo.exists():
        toml = read_toml(cargo)
        entry = {"name": "rust", "source": "Cargo.toml", "confidence": "high"}
        edition = toml.get("package", {}).get("edition")
        if edition:
            entry["version"] = edition
        langs.append(entry)

    return langs


def detect_testing(root: Path, langs: list[dict]) -> dict:
    commands: list[dict] = []
    coverage_commands: list[dict] = []

    # Makefile targets
    makefile = root / "Makefile"
    if makefile.exists():
        targets = read_makefile_targets(makefile)
        if "test" in targets:
            commands.append(detected("make test", "Makefile"))
        if "test-coverage" in targets or "coverage" in targets:
            cmd = "make test-coverage" if "test-coverage" in targets else "make coverage"
            coverage_commands.append(detected(cmd, "Makefile"))

    # package.json scripts
    pkg_json = root / "package.json"
    if pkg_json.exists():
        pkg = read_json(pkg_json)
        scripts = pkg.get("scripts", {})
        for key in ("test", "test:unit", "jest", "vitest"):
            if key in scripts:
                commands.append(detected(f"npm run {key}" if key != "test" else "npm test", "package.json"))
                break
        for key in ("test:coverage", "coverage", "jest:coverage"):
            if key in scripts:
                coverage_commands.append(detected(f"npm run {key}", "package.json"))
                break

    # Python - pyproject.toml / pytest.ini / setup.cfg
    lang_names = [l["name"] for l in langs]
    if "python" in lang_names:
        if not any(c["value"].startswith("make") for c in commands):
            pytest_ini = root / "pytest.ini"
            setup_cfg = root / "setup.cfg"
            if pytest_ini.exists() or setup_cfg.exists() or (root / "pyproject.toml").exists():
                commands.append(detected("pytest", "pytest config", "medium"))
                coverage_commands.append(detected("pytest --cov", "inferred", "low"))

    # go test
    if "go" in lang_names and not commands:
        commands.append(detected("go test ./...", "go.mod", "medium"))

    # cargo test
    if "rust" in lang_names and not commands:
        commands.append(detected("cargo test", "Cargo.toml", "medium"))

    # E2E test commands
    e2e_commands: list[dict] = []
    if makefile.exists() if (makefile := root / "Makefile") else False:
        targets = read_makefile_targets(root / "Makefile")
        for t in ("e2e", "test-e2e", "e2e-test", "test:e2e"):
            if t in targets:
                e2e_commands.append(detected(f"make {t}", "Makefile"))
                break
    pkg_json = root / "package.json"
    if pkg_json.exists():
        pkg = read_json(pkg_json)
        scripts = pkg.get("scripts", {})
        for key in ("test:e2e", "e2e", "playwright", "cypress"):
            if key in scripts:
                e2e_commands.append(detected(f"npm run {key}", "package.json"))
                break
        # Detect playwright/cypress installations
        deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
        if "playwright" in str(deps) or "@playwright/test" in deps:
            if not e2e_commands:
                e2e_commands.append(detected("npx playwright test", "package.json", "medium"))
        elif "cypress" in deps:
            if not e2e_commands:
                e2e_commands.append(detected("npx cypress run", "package.json", "medium"))

    # Smoke test commands
    smoke_commands: list[dict] = []
    if (root / "Makefile").exists():
        targets = read_makefile_targets(root / "Makefile")
        for t in ("smoke", "smoke-test", "test-smoke"):
            if t in targets:
                smoke_commands.append(detected(f"make {t}", "Makefile"))
                break
    if pkg_json.exists():
        pkg = read_json(pkg_json)
        scripts = pkg.get("scripts", {})
        for key in ("test:smoke", "smoke"):
            if key in scripts:
                smoke_commands.append(detected(f"npm run {key}", "package.json"))
                break

    result: dict[str, Any] = {}
    if commands:
        result["command"] = commands[0]
        result["all_options"] = [c["value"] for c in commands] if len(commands) > 1 else None
    if coverage_commands:
        result["coverage_command"] = coverage_commands[0]
    if e2e_commands:
        result["e2e_command"] = e2e_commands[0]
    if smoke_commands:
        result["smoke_command"] = smoke_commands[0]

    result["min_coverage"] = detected(80, "default", "low")

    return result


def detect_quality(root: Path, langs: list[dict]) -> dict:
    """Detect lint, format, and typecheck commands."""
    lang_names = [l["name"] for l in langs]
    result: dict[str, Any] = {}

    # Check Makefile targets first
    makefile = root / "Makefile"
    targets: list[str] = []
    if makefile.exists():
        targets = read_makefile_targets(makefile)

    # Lint command
    if "lint" in targets:
        result["lint_command"] = detected("make lint", "Makefile")
    elif "python" in lang_names:
        if (root / "pyproject.toml").exists() or (root / "ruff.toml").exists():
            result["lint_command"] = detected("ruff check .", "pyproject.toml/ruff.toml", "medium")
    elif "typescript" in lang_names or "javascript" in lang_names:
        pkg_json = root / "package.json"
        if pkg_json.exists():
            scripts = read_json(pkg_json).get("scripts", {})
            for key in ("lint", "eslint"):
                if key in scripts:
                    result["lint_command"] = detected(f"npm run {key}", "package.json")
                    break
    elif "go" in lang_names:
        result["lint_command"] = detected("golangci-lint run", "go.mod", "low")

    # Format command
    if "format" in targets or "fmt" in targets:
        cmd = "make format" if "format" in targets else "make fmt"
        result["format_command"] = detected(cmd, "Makefile")
    elif "python" in lang_names:
        if (root / "pyproject.toml").exists() or (root / "ruff.toml").exists():
            result["format_command"] = detected("ruff format .", "pyproject.toml/ruff.toml", "medium")
    elif "typescript" in lang_names or "javascript" in lang_names:
        pkg_json = root / "package.json"
        if pkg_json.exists():
            scripts = read_json(pkg_json).get("scripts", {})
            for key in ("format", "prettier"):
                if key in scripts:
                    result["format_command"] = detected(f"npm run {key}", "package.json")
                    break
    elif "go" in lang_names:
        result["format_command"] = detected("gofmt -w ./...", "go.mod", "low")

    # Typecheck command
    if "typecheck" in targets or "type-check" in targets or "mypy" in targets or "pyright" in targets:
        for t in ("typecheck", "type-check", "mypy", "pyright"):
            if t in targets:
                result["typecheck_command"] = detected(f"make {t}", "Makefile")
                break
    elif "python" in lang_names:
        if (root / "pyrightconfig.json").exists():
            result["typecheck_command"] = detected("pyright", "pyrightconfig.json")
        elif (root / ".mypy.ini").exists() or (root / "mypy.ini").exists():
            result["typecheck_command"] = detected("mypy .", ".mypy.ini")
    elif "typescript" in lang_names:
        pkg_json = root / "package.json"
        if pkg_json.exists():
            scripts = read_json(pkg_json).get("scripts", {})
            for key in ("typecheck", "type-check", "tsc"):
                if key in scripts:
                    result["typecheck_command"] = detected(f"npm run {key}", "package.json")
                    break
            if not result.get("typecheck_command") and (root / "tsconfig.json").exists():
                result["typecheck_command"] = detected("tsc --noEmit", "tsconfig.json", "medium")

    return result


def detect_docker(root: Path) -> dict | None:
    compose_path = None
    for name in ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"):
        p = root / name
        if p.exists():
            compose_path = p
            break

    if not compose_path:
        return None

    services = read_yaml_services(compose_path)

    result: dict[str, Any] = {
        "compose_file": detected(compose_path.name, "filesystem"),
        "services": detected(services, compose_path.name) if services else detected([], compose_path.name, "low"),
    }

    # Detect base image from Dockerfile
    for dockerfile_name in ("Dockerfile", "Dockerfile.dev", "backend/Dockerfile", "frontend/Dockerfile"):
        df = root / dockerfile_name
        if df.exists():
            text = df.read_text()
            m = re.search(r"^FROM\s+([^\s]+)", text, re.MULTILINE)
            if m:
                result["base_image"] = detected(m.group(1), dockerfile_name, "medium")
                break

    return result


def detect_git(root: Path) -> dict:
    result: dict[str, Any] = {}

    remote = run(["git", "remote", "get-url", "origin"], cwd=root)
    if not remote:
        return result

    # Parse platform and instance. Public hosts first (github.com,
    # gitlab.com), then check whether the remote matches the user's
    # self-hosted git instance from their profile.
    self_hosted = _profile_get_env(".git.instance")
    if self_hosted in ("github.com", "gitlab.com", ""):
        self_hosted = ""

    if "github.com" in remote:
        result["platform"] = detected("github", "git-remote")
        result["instance"] = detected("github.com", "git-remote")
    elif self_hosted and self_hosted in remote:
        # Self-hosted instance from profile — assume gitlab unless the
        # profile explicitly says otherwise
        platform = _profile_get_env(".git.platform") or "gitlab"
        result["platform"] = detected(platform, "git-remote")
        result["instance"] = detected(self_hosted, "git-remote")
    elif "gitlab" in remote:
        result["platform"] = detected("gitlab", "git-remote")
        result["instance"] = detected("gitlab.com", "git-remote")
    else:
        # Extract domain from URL
        m = re.search(r"[@/]([^/:@]+)[:/]", remote)
        if m:
            domain = m.group(1)
            platform = "github" if "github" in domain else "gitlab"
            result["platform"] = detected(platform, "git-remote", "medium")
            result["instance"] = detected(domain, "git-remote", "medium")

    # Extract repo path (owner/repo)
    # SSH format:   git@host:owner/repo.git  → colon separates host from path
    # HTTPS format: https://host/owner/repo.git → slashes after domain
    repo_path = None
    ssh_m = re.match(r"git@[^:]+:(.+?)(?:\.git)?$", remote)
    if ssh_m:
        repo_path = ssh_m.group(1)
    else:
        https_m = re.search(r"https?://[^/]+/(.+?)(?:\.git)?$", remote)
        if https_m:
            repo_path = https_m.group(1)
    if repo_path:
        result["repo"] = detected(repo_path, "git-remote")

    return result


def detect_branches(root: Path) -> dict:
    # Get all local + remote branches
    raw = run(["git", "branch", "-a", "--format=%(refname:short)"], cwd=root)
    all_branches = []
    for b in raw.splitlines():
        b = b.strip().lstrip("* ")
        if b and "HEAD" not in b:
            # Normalize remote tracking refs
            b = re.sub(r"^(origin|remotes/origin)/", "", b)
            if b not in all_branches:
                all_branches.append(b)

    # Infer staging branch
    staging = None
    for candidate in ("dev", "develop", "staging", "stage"):
        if candidate in all_branches:
            staging = detected(candidate, "git-branches")
            break
    if not staging:
        staging = detected("dev", "default", "low")

    # Infer production branch
    production = None
    for candidate in ("main", "master", "prod", "production", "release"):
        if candidate in all_branches:
            production = detected(candidate, "git-branches")
            break
    if not production:
        production = detected("main", "default", "low")

    # Infer dev/integration branch — where feature branches merge (used by task-close, git-merge)
    # Priority: dedicated dev/develop branch > same as staging branch
    dev = None
    for candidate in ("develop", "dev", "development", "integration"):
        if candidate in all_branches:
            dev = detected(candidate, "git-branches")
            break
    if not dev:
        # Fall back to the staging branch value (they're often the same)
        dev = detected(staging["value"], staging["source"], staging["confidence"])

    return {
        "all": sorted(set(all_branches)),
        "dev": dev,
        "staging": staging,
        "production": production,
    }


def detect_ci(root: Path, git_info: dict) -> dict:
    # GitHub Actions
    if (root / ".github" / "workflows").exists():
        return {"platform": detected("github", ".github/workflows")}
    # GitLab CI
    if (root / ".gitlab-ci.yml").exists():
        return {"platform": detected("gitlab", ".gitlab-ci.yml")}
    # Infer from git platform
    if git_info.get("platform"):
        plat = git_info["platform"]["value"]
        return {"platform": detected(plat, "git-remote", "medium")}
    # OS fallback
    os_type = "Darwin"
    try:
        os_type = run(["uname", "-s"])
    except Exception:
        pass
    plat = "github" if os_type == "Darwin" else "gitlab"
    return {"platform": detected(plat, "os", "low")}


def detect_secrets(root: Path) -> dict:
    os_type = run(["uname", "-s"]) or "Linux"
    backend = "aws" if os_type == "Darwin" else "infisical"
    return {"backend": detected(backend, "os")}


def detect_task_management(root: Path) -> dict:
    os_type = run(["uname", "-s"]) or "Linux"
    is_work = os_type == "Darwin"

    asana_token = Path.home() / ".asana-token"
    gitlab_token = Path.home() / ".gitlab-token"

    result: dict[str, Any] = {
        "asana_token_exists": asana_token.exists(),
        "gitlab_token_exists": gitlab_token.exists(),
    }

    # Determine best backend
    if is_work:
        backend = "asana" if asana_token.exists() else "asana"
        confidence = "high" if asana_token.exists() else "medium"
    else:
        backend = "gitlab" if gitlab_token.exists() else "gitlab"
        confidence = "high" if gitlab_token.exists() else "medium"

    result["backend"] = detected(backend, "os", confidence)

    # Asana workspace info (if token exists)
    if asana_token.exists():
        result["asana_hint"] = "Token found — workspace_id and project needed"

    return result


def detect_deployment(root: Path, docker_info: dict | None) -> dict:
    hints = []
    makefile_deploy_targets = []

    # Check Makefile for deploy targets
    makefile = root / "Makefile"
    if makefile.exists():
        all_targets = read_makefile_targets(makefile)
        deploy_targets = [t for t in all_targets if "deploy" in t.lower()]
        makefile_deploy_targets = deploy_targets
        if deploy_targets:
            hints.append(f"Makefile has deploy targets: {', '.join(deploy_targets)}")

    # Check for deploy scripts
    scripts_dir = root / "scripts"
    if scripts_dir.exists():
        deploy_scripts = [
            f.name for f in scripts_dir.iterdir()
            if f.is_file() and "deploy" in f.name.lower()
        ]
        if deploy_scripts:
            hints.append(f"Deploy scripts found: {', '.join(deploy_scripts)}")

    # Suggest strategy based on hints
    has_deploy = bool(makefile_deploy_targets or hints)

    # Infer method
    suggested_method = "pipeline"  # Most common default
    os_type = run(["uname", "-s"]) or "Linux"
    if os_type == "Darwin":
        # Work environment: likely AWS SSM or pipeline
        suggested_method = "pipeline"
    else:
        # Home: likely SSH to Unraid/Proxmox
        suggested_method = "ssh"

    return {
        "has_deploy_indicators": has_deploy,
        "makefile_deploy_targets": makefile_deploy_targets,
        "hints": hints,
        "suggested_strategy": detected("standard", "inferred", "low"),
        "suggested_method": detected(suggested_method, "os", "low"),
    }


# ── Main detector ─────────────────────────────────────────────────────────────

def detect(root: Path) -> dict[str, Any]:
    project_yaml = root / "PROJECT.yaml"

    # Run all detectors
    name, description = detect_name_and_description(root)
    languages = detect_languages(root)
    testing = detect_testing(root, languages)
    quality = detect_quality(root, languages)
    docker = detect_docker(root)
    git_info = detect_git(root)
    branches = detect_branches(root)
    ci = detect_ci(root, git_info)
    secrets = detect_secrets(root)
    task_mgmt = detect_task_management(root)
    deployment = detect_deployment(root, docker)

    # Build detections object
    detections: dict[str, Any] = {}
    if name:
        detections["name"] = name
    if description:
        detections["description"] = description
    detections["languages"] = languages
    detections["testing"] = testing
    if quality:
        detections["quality"] = quality
    if docker:
        detections["docker"] = docker
    detections["git"] = git_info
    detections["branches"] = branches
    detections["ci"] = ci
    detections["secrets"] = secrets
    detections["task_management"] = task_mgmt
    detections["deployment"] = deployment

    # Determine what needs user input
    needs_input = []

    if not description:
        needs_input.append({
            "field": "description",
            "label": "Project description",
            "reason": "Not found in project files",
            "required": False,
        })

    if not testing.get("command"):
        needs_input.append({
            "field": "testing.command",
            "label": "Test command",
            "reason": "Could not detect test command",
            "required": True,
        })
    elif testing.get("all_options") and len(testing["all_options"]) > 1:
        needs_input.append({
            "field": "testing.command",
            "label": "Test command",
            "reason": "Multiple options detected",
            "options": testing["all_options"],
            "required": True,
        })

    if branches["dev"]["confidence"] == "low":
        needs_input.append({
            "field": "ci.branches.dev",
            "label": "Dev/integration branch name",
            "reason": "Could not find integration branch (develop/dev) — used by task-close and git-merge for squash merges",
            "options": branches["all"],
            "required": True,
        })

    if branches["staging"]["confidence"] == "low":
        needs_input.append({
            "field": "ci.branches.staging",
            "label": "Staging branch name",
            "reason": "Could not find common staging branch (dev/develop/staging)",
            "options": branches["all"],
            "required": True,
        })

    if branches["production"]["confidence"] == "low":
        needs_input.append({
            "field": "ci.branches.production",
            "label": "Production branch name",
            "reason": "Could not find common production branch (main/master/prod)",
            "options": branches["all"],
            "required": True,
        })

    # Task management: always ask to confirm/provide workspace_id for asana
    if task_mgmt["backend"]["value"] == "asana":
        needs_input.append({
            "field": "task_management",
            "label": "Task management",
            "reason": "Asana workspace_id and project name needed",
            "required": False,
        })
    elif task_mgmt["backend"]["value"] == "gitlab" and git_info.get("repo"):
        # gitlab project_id can be inferred from repo
        pass

    # Deployment: always ask
    needs_input.append({
        "field": "deployment",
        "label": "Deployment configuration",
        "reason": "Server topology and method must be specified",
        "options": ["blue-green", "standard", "single", "none"],
        "required": False,
    })

    # Optional sections
    optional_sections = {
        "databases": {
            "should_configure": False,
            "hint": "No database services detected",
        },
        "deployment": {
            "should_configure": deployment["has_deploy_indicators"],
            "hint": "; ".join(deployment["hints"]) if deployment["hints"] else None,
        },
        "task_management": {
            "should_configure": task_mgmt["asana_token_exists"] or task_mgmt["gitlab_token_exists"],
            "hint": (
                "Asana token found at ~/.asana-token" if task_mgmt["asana_token_exists"]
                else "GitLab token found at ~/.gitlab-token" if task_mgmt["gitlab_token_exists"]
                else "No task management tokens found"
            ),
        },
        "notifications": {"should_configure": False, "hint": None},
        "infrastructure": {"should_configure": False, "hint": None},
    }

    # Check for database indicators
    db_indicators = []
    if docker:
        svc_names = docker.get("services", {}).get("value", [])
        for svc in svc_names:
            if any(db in svc.lower() for db in ("postgres", "mysql", "mongo", "redis", "db", "database")):
                db_indicators.append(svc)
    if db_indicators:
        optional_sections["databases"] = {
            "should_configure": True,
            "hint": f"Database services detected: {', '.join(db_indicators)}",
        }

    return {
        "project_root": str(root),
        "project_yaml_exists": project_yaml.exists(),
        "detections": detections,
        "needs_input": needs_input,
        "optional_sections": optional_sections,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Auto-detect PROJECT.yaml values from current project"
    )
    parser.add_argument("--root", default=".", help="Project root directory (default: cwd)")
    args = parser.parse_args()

    result = detect(Path(args.root))
    print(json.dumps(result, indent=2))
