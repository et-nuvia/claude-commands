#!/usr/bin/env python3
"""Tech stack detection for project configuration."""
import sys
import json
from pathlib import Path
from typing import List, Dict, Set


def detect_languages(paths: List[Path]) -> Set[str]:
    """
    Detect languages from marker files.

    Args:
        paths: List of paths to scan (typically [Path('.'), Path('backend'), Path('frontend')])

    Returns:
        Set of detected languages: {"python", "nodejs", "go", "rust"}
    """
    languages = set()

    for base_path in paths:
        # Python indicators
        if (base_path / "pyproject.toml").exists() or \
           (base_path / "requirements.txt").exists() or \
           (base_path / "setup.py").exists():
            languages.add("python")

        # Node.js indicators
        if (base_path / "package.json").exists():
            languages.add("nodejs")

        # Go indicators
        if (base_path / "go.mod").exists():
            languages.add("go")

        # Rust indicators
        if (base_path / "Cargo.toml").exists():
            languages.add("rust")

    return languages


def detect_frameworks(paths: List[Path]) -> Set[str]:
    """
    Detect frameworks by parsing dependency files.

    Checks:
    - Python: pyproject.toml dependencies (fastapi, django, flask)
    - Node.js: package.json dependencies (next, express, react, vue)
    """
    frameworks = set()

    for base_path in paths:
        # Python frameworks
        pyproject = base_path / "pyproject.toml"
        if pyproject.exists():
            try:
                # Try Python 3.11+ tomllib
                try:
                    import tomllib
                except ImportError:
                    # Fallback for older Python
                    try:
                        import tomli as tomllib
                    except ImportError:
                        # Skip if no TOML parser available
                        continue

                with open(pyproject, "rb") as f:
                    data = tomllib.load(f)

                # Check dependencies (PEP 621 [project.dependencies] and
                # Poetry's [tool.poetry.dependencies], which uses a dict
                # rather than a list)
                deps = data.get("project", {}).get("dependencies", [])
                poetry_deps = data.get("tool", {}).get("poetry", {}).get("dependencies", {})
                deps_str = " ".join(str(d) for d in deps).lower()
                deps_str += " " + " ".join(str(k) for k in poetry_deps).lower()

                if "fastapi" in deps_str:
                    frameworks.add("fastapi")
                if "django" in deps_str:
                    frameworks.add("django")
                if "flask" in deps_str:
                    frameworks.add("flask")
            except Exception:
                pass  # Ignore parse errors

        # Node.js frameworks
        package_json = base_path / "package.json"
        if package_json.exists():
            try:
                data = json.loads(package_json.read_text())
                deps = {**data.get("dependencies", {}), **data.get("devDependencies", {})}

                if "next" in deps:
                    frameworks.add("next")
                if "express" in deps:
                    frameworks.add("express")
                if "react" in deps:
                    frameworks.add("react")
                if "vue" in deps:
                    frameworks.add("vue")
            except Exception:
                pass

    return frameworks


def detect_tools(paths: List[Path]) -> Set[str]:
    """Detect build/dev tools from file presence."""
    tools = set()

    # Check root directory only
    root = Path(".")

    if (root / "Dockerfile").exists():
        tools.add("docker")
    if (root / "docker-compose.yml").exists() or (root / "compose.yml").exists():
        tools.add("docker-compose")
    if (root / "flake.nix").exists():
        tools.add("nix")
    if (root / ".github/workflows").exists():
        tools.add("github-actions")
    if (root / ".gitlab-ci.yml").exists():
        tools.add("gitlab-ci")
    if (root / "Makefile").exists():
        tools.add("make")

    return tools


def main():
    """CLI entry point with commands."""
    import argparse

    parser = argparse.ArgumentParser(description="Detect project tech stack")
    parser.add_argument("command",
                        nargs="?",
                        choices=["languages", "frameworks", "tools", "all", "json"],
                        default="all",
                        help="What to detect (default: all)")
    args = parser.parse_args()

    # Scan paths (root + common subdirs)
    scan_paths = [Path(".")]
    for subdir in ["backend", "frontend", "server", "client"]:
        subdir_path = Path(subdir)
        if subdir_path.exists() and subdir_path.is_dir():
            scan_paths.append(subdir_path)

    # Detect
    languages = detect_languages(scan_paths)
    frameworks = detect_frameworks(scan_paths)
    tools = detect_tools(scan_paths)

    # Output
    if args.command == "json":
        result = {
            "languages": sorted(languages),
            "frameworks": sorted(frameworks),
            "tools": sorted(tools)
        }
        print(json.dumps(result, indent=2))
    elif args.command == "all":
        for lang in sorted(languages):
            print(f"language:{lang}")
        for fw in sorted(frameworks):
            print(f"framework:{fw}")
        for tool in sorted(tools):
            print(f"tool:{tool}")
    elif args.command == "languages":
        for lang in sorted(languages):
            print(lang)
    elif args.command == "frameworks":
        for fw in sorted(frameworks):
            print(fw)
    elif args.command == "tools":
        for tool in sorted(tools):
            print(tool)


if __name__ == "__main__":
    main()
