"""
Tests for project-config-detect.py

Tests every detector in isolation using temporary directories with fixture files.
Platform-specific behavior (macOS vs Linux) is covered by patching the run()
helper so no actual git commands are needed.

Run with:
    pytest scripts/tests/test-project-config-detect.py -v
    # or via wrapper:
    ~/.claude/scripts/tests/run-python-tests.sh
"""

from __future__ import annotations

import json
import sys
import textwrap
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

# ── Load module from hyphenated filename via importlib ────────────────────────
# Normal `import` doesn't support hyphens in filenames; use spec_from_file_location.
import importlib.util  # noqa: E402

SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "project-config-detect.py"
_spec = importlib.util.spec_from_file_location("project_config_detect", _MODULE_PATH)
det = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(det)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def tmp_project(tmp_path: Path) -> Path:
    """Empty project directory."""
    return tmp_path


@pytest.fixture
def python_project(tmp_path: Path) -> Path:
    """Python project with pyproject.toml."""
    (tmp_path / "pyproject.toml").write_text(textwrap.dedent("""\
        [project]
        name = "my-api"
        description = "A Python API"
        requires-python = ">=3.12"

        [tool.pytest.ini_options]
        testpaths = ["tests"]
    """))
    (tmp_path / "requirements.txt").write_text("fastapi\n")
    (tmp_path / "Makefile").write_text(textwrap.dedent("""\
        test:
        \tpytest

        test-coverage:
        \tpytest --cov

        lint:
        \truff check .
    """))
    return tmp_path


@pytest.fixture
def typescript_project(tmp_path: Path) -> Path:
    """TypeScript project with package.json and tsconfig.json."""
    pkg = {
        "name": "my-frontend",
        "description": "A TypeScript frontend",
        "scripts": {
            "test": "jest",
            "test:coverage": "jest --coverage",
            "build": "tsc",
        },
        "engines": {"node": ">=20"},
    }
    (tmp_path / "package.json").write_text(json.dumps(pkg, indent=2))
    (tmp_path / "tsconfig.json").write_text('{"compilerOptions": {}}')
    return tmp_path


@pytest.fixture
def go_project(tmp_path: Path) -> Path:
    """Go project with go.mod."""
    (tmp_path / "go.mod").write_text(textwrap.dedent("""\
        module github.com/myorg/my-service

        go 1.22

        require (
            github.com/gin-gonic/gin v1.9.1
        )
    """))
    (tmp_path / "Makefile").write_text("test:\n\tgo test ./...\n")
    return tmp_path


@pytest.fixture
def rust_project(tmp_path: Path) -> Path:
    """Rust project with Cargo.toml."""
    (tmp_path / "Cargo.toml").write_text(textwrap.dedent("""\
        [package]
        name = "my-rust-app"
        version = "0.1.0"
        edition = "2021"
        description = "A Rust application"
    """))
    return tmp_path


@pytest.fixture
def fullstack_project(tmp_path: Path) -> Path:
    """Full-stack project: Python backend, TypeScript frontend, Docker."""
    # Backend
    backend = tmp_path / "backend"
    backend.mkdir()
    (backend / "pyproject.toml").write_text(textwrap.dedent("""\
        [project]
        name = "my-app-backend"
        requires-python = ">=3.12"
    """))

    # Frontend
    frontend = tmp_path / "frontend"
    frontend.mkdir()
    (frontend / "package.json").write_text(json.dumps({"name": "my-app-frontend"}))
    (frontend / "tsconfig.json").write_text("{}")

    # Root package.json (monorepo)
    (tmp_path / "package.json").write_text(json.dumps({
        "name": "my-app",
        "description": "Full-stack application",
        "scripts": {"test": "jest", "test:coverage": "jest --coverage"},
    }))
    (tmp_path / "tsconfig.json").write_text("{}")

    # Docker Compose
    (tmp_path / "docker-compose.yml").write_text(textwrap.dedent("""\
        services:
          postgres:
            image: postgres:16
          redis:
            image: redis:7
          backend:
            build: ./backend
          frontend:
            build: ./frontend
    """))

    # Makefile
    (tmp_path / "Makefile").write_text(textwrap.dedent("""\
        test:
        \tmake -C backend test && make -C frontend test

        test-coverage:
        \tmake -C backend test-coverage

        deploy-staging:
        \t./scripts/deploy.sh staging

        deploy-prod:
        \t./scripts/deploy.sh production

        lint:
        \truff check backend
    """))

    return tmp_path


# ── Helper: run detector with git mocked out ──────────────────────────────────

def run_detect(root: Path, git_remote: str = "", branches: str = "",
               uname: str = "Darwin") -> dict:
    """
    Run the full detect() with git and uname calls mocked.

    git_remote: simulated output of `git remote get-url origin`
    branches:   simulated output of `git branch -a --format=...`
    uname:      simulated output of `uname -s` ("Darwin" or "Linux")
    """
    def mock_run(cmd: list[str], cwd=None) -> str:
        if "remote" in cmd and "get-url" in cmd:
            return git_remote
        if "branch" in cmd:
            return branches
        if cmd == ["uname", "-s"]:
            return uname
        return ""

    with patch.object(det, "run", side_effect=mock_run):
        return det.detect(root)


# ── Tests: detect_name_and_description ───────────────────────────────────────

class TestDetectNameAndDescription:
    def test_name_from_package_json(self, typescript_project):
        name, _ = det.detect_name_and_description(typescript_project)
        assert name["value"] == "my-frontend"
        assert name["source"] == "package.json"
        assert name["confidence"] == "high"

    def test_description_from_package_json(self, typescript_project):
        _, desc = det.detect_name_and_description(typescript_project)
        assert desc is not None
        assert desc["value"] == "A TypeScript frontend"
        assert desc["source"] == "package.json"

    def test_name_from_pyproject_toml(self, python_project):
        name, _ = det.detect_name_and_description(python_project)
        assert name["value"] == "my-api"
        assert name["source"] == "pyproject.toml"

    def test_description_from_pyproject_toml(self, python_project):
        _, desc = det.detect_name_and_description(python_project)
        assert desc is not None
        assert desc["value"] == "A Python API"

    def test_name_from_go_mod(self, go_project):
        name, _ = det.detect_name_and_description(go_project)
        assert name["value"] == "my-service"
        assert name["source"] == "go.mod"

    def test_name_from_cargo_toml(self, rust_project):
        name, _ = det.detect_name_and_description(rust_project)
        assert name["value"] == "my-rust-app"
        assert name["source"] == "Cargo.toml"

    def test_name_from_description_rust(self, rust_project):
        _, desc = det.detect_name_and_description(rust_project)
        assert desc is not None
        assert desc["value"] == "A Rust application"

    def test_falls_back_to_directory(self, tmp_project):
        name, _ = det.detect_name_and_description(tmp_project)
        assert name["value"] == tmp_project.name
        assert name["source"] == "directory"
        assert name["confidence"] == "medium"

    def test_no_description_returns_none(self, tmp_project):
        _, desc = det.detect_name_and_description(tmp_project)
        assert desc is None


# ── Tests: detect_languages ───────────────────────────────────────────────────

class TestDetectLanguages:
    def test_python_from_pyproject_toml(self, python_project):
        langs = det.detect_languages(python_project)
        names = [l["name"] for l in langs]
        assert "python" in names

    def test_python_version_from_requires_python(self, python_project):
        langs = det.detect_languages(python_project)
        py = next(l for l in langs if l["name"] == "python")
        assert py["version"] == "3.12"

    def test_python_from_requirements_txt(self, tmp_path):
        (tmp_path / "requirements.txt").write_text("flask\n")
        langs = det.detect_languages(tmp_path)
        assert any(l["name"] == "python" for l in langs)

    def test_typescript_detected_with_tsconfig(self, typescript_project):
        langs = det.detect_languages(typescript_project)
        names = [l["name"] for l in langs]
        assert "typescript" in names
        assert "javascript" not in names

    def test_javascript_when_no_tsconfig(self, tmp_path):
        (tmp_path / "package.json").write_text('{"name": "no-ts"}')
        langs = det.detect_languages(tmp_path)
        names = [l["name"] for l in langs]
        assert "javascript" in names
        assert "typescript" not in names

    def test_go_detected(self, go_project):
        langs = det.detect_languages(go_project)
        names = [l["name"] for l in langs]
        assert "go" in names

    def test_go_version_from_go_mod(self, go_project):
        langs = det.detect_languages(go_project)
        go = next(l for l in langs if l["name"] == "go")
        assert go["version"] == "1.22"

    def test_rust_detected(self, rust_project):
        langs = det.detect_languages(rust_project)
        names = [l["name"] for l in langs]
        assert "rust" in names

    def test_rust_edition_as_version(self, rust_project):
        langs = det.detect_languages(rust_project)
        rust = next(l for l in langs if l["name"] == "rust")
        assert rust["version"] == "2021"

    def test_empty_project_no_languages(self, tmp_project):
        langs = det.detect_languages(tmp_project)
        assert langs == []

    def test_python_version_from_dotfile(self, tmp_path):
        (tmp_path / "requirements.txt").write_text("requests\n")
        (tmp_path / ".python-version").write_text("3.13\n")
        langs = det.detect_languages(tmp_path)
        py = next(l for l in langs if l["name"] == "python")
        assert py["version"] == "3.13"
        assert py["source"] == ".python-version"

    def test_fullstack_has_both_python_and_typescript(self, fullstack_project):
        langs = det.detect_languages(fullstack_project)
        names = [l["name"] for l in langs]
        assert "python" in names
        assert "typescript" in names


# ── Tests: detect_testing ─────────────────────────────────────────────────────

class TestDetectTesting:
    def test_make_test_from_makefile(self, python_project):
        langs = det.detect_languages(python_project)
        testing = det.detect_testing(python_project, langs)
        assert testing["command"]["value"] == "make test"
        assert testing["command"]["source"] == "Makefile"

    def test_make_test_coverage_from_makefile(self, python_project):
        langs = det.detect_languages(python_project)
        testing = det.detect_testing(python_project, langs)
        assert testing["coverage_command"]["value"] == "make test-coverage"

    def test_npm_test_from_package_json(self, typescript_project):
        langs = det.detect_languages(typescript_project)
        testing = det.detect_testing(typescript_project, langs)
        assert testing["command"]["value"] == "npm test"
        assert testing["command"]["source"] == "package.json"

    def test_npm_coverage_from_package_json(self, typescript_project):
        langs = det.detect_languages(typescript_project)
        testing = det.detect_testing(typescript_project, langs)
        assert testing["coverage_command"]["value"] == "npm run test:coverage"

    def test_go_test_inferred(self, go_project):
        langs = det.detect_languages(go_project)
        testing = det.detect_testing(go_project, langs)
        # Makefile has `test` target with `go test ./...`
        assert "make test" == testing["command"]["value"]

    def test_go_test_fallback_when_no_makefile(self, tmp_path):
        (tmp_path / "go.mod").write_text("module github.com/x/y\ngo 1.22\n")
        langs = det.detect_languages(tmp_path)
        testing = det.detect_testing(tmp_path, langs)
        assert testing["command"]["value"] == "go test ./..."

    def test_cargo_test_fallback(self, tmp_path):
        (tmp_path / "Cargo.toml").write_text("[package]\nname = \"x\"\n")
        langs = det.detect_languages(tmp_path)
        testing = det.detect_testing(tmp_path, langs)
        assert testing["command"]["value"] == "cargo test"

    def test_min_coverage_default(self, python_project):
        langs = det.detect_languages(python_project)
        testing = det.detect_testing(python_project, langs)
        assert testing["min_coverage"]["value"] == 80
        assert testing["min_coverage"]["confidence"] == "low"

    def test_no_command_for_empty_project(self, tmp_project):
        testing = det.detect_testing(tmp_project, [])
        assert "command" not in testing

    def test_makefile_preferred_over_package_json(self, fullstack_project):
        langs = det.detect_languages(fullstack_project)
        testing = det.detect_testing(fullstack_project, langs)
        assert testing["command"]["value"] == "make test"
        assert testing["command"]["source"] == "Makefile"


# ── Tests: detect_docker ──────────────────────────────────────────────────────

class TestDetectDocker:
    def test_no_docker_when_no_compose(self, tmp_project):
        result = det.detect_docker(tmp_project)
        assert result is None

    def test_detects_compose_file(self, fullstack_project):
        result = det.detect_docker(fullstack_project)
        assert result is not None
        assert result["compose_file"]["value"] == "docker-compose.yml"

    def test_parses_service_names(self, fullstack_project):
        result = det.detect_docker(fullstack_project)
        services = result["services"]["value"]
        assert "postgres" in services
        assert "redis" in services
        assert "backend" in services
        assert "frontend" in services

    def test_detects_compose_yaml_extension(self, tmp_path):
        (tmp_path / "compose.yaml").write_text("services:\n  app:\n    image: nginx\n")
        result = det.detect_docker(tmp_path)
        assert result is not None
        assert result["compose_file"]["value"] == "compose.yaml"

    def test_empty_services(self, tmp_path):
        (tmp_path / "docker-compose.yml").write_text("services: {}\n")
        result = det.detect_docker(tmp_path)
        assert result is not None
        assert result["services"]["value"] == []


# ── Tests: detect_git ─────────────────────────────────────────────────────────

class TestDetectGit:
    def _run_with_remote(self, root, remote):
        def mock_run(cmd, cwd=None):
            if "remote" in cmd:
                return remote
            return ""
        with patch.object(det, "run", side_effect=mock_run):
            return det.detect_git(root)

    def test_github_https_url(self, tmp_project):
        r = self._run_with_remote(tmp_project, "https://github.com/myorg/my-repo.git")
        assert r["platform"]["value"] == "github"
        assert r["instance"]["value"] == "github.com"
        assert r["repo"]["value"] == "myorg/my-repo"

    def test_github_ssh_url(self, tmp_project):
        r = self._run_with_remote(tmp_project, "git@github.com:myorg/my-repo.git")
        assert r["platform"]["value"] == "github"
        assert r["repo"]["value"] == "myorg/my-repo"

    def test_gitlab_turnersrus_url(self, tmp_project):
        r = self._run_with_remote(tmp_project, "git@git.turnersrus.com:eric/my-project.git")
        assert r["platform"]["value"] == "gitlab"
        assert r["instance"]["value"] == "git.turnersrus.com"
        assert r["repo"]["value"] == "eric/my-project"

    def test_gitlab_com_url(self, tmp_project):
        r = self._run_with_remote(tmp_project, "https://gitlab.com/myorg/my-repo.git")
        assert r["platform"]["value"] == "gitlab"
        assert r["instance"]["value"] == "gitlab.com"

    def test_empty_when_no_remote(self, tmp_project):
        r = self._run_with_remote(tmp_project, "")
        assert r == {}

    def test_repo_without_dot_git_suffix(self, tmp_project):
        r = self._run_with_remote(tmp_project, "https://github.com/myorg/my-repo")
        assert r["repo"]["value"] == "myorg/my-repo"

    def test_high_confidence_from_remote(self, tmp_project):
        r = self._run_with_remote(tmp_project, "git@github.com:org/repo.git")
        assert r["platform"]["confidence"] == "high"
        assert r["instance"]["confidence"] == "high"
        assert r["repo"]["confidence"] == "high"


# ── Tests: detect_branches ────────────────────────────────────────────────────

class TestDetectBranches:
    def _run_with_branches(self, root, branch_list):
        branches_str = "\n".join(branch_list)
        def mock_run(cmd, cwd=None):
            if "branch" in cmd:
                return branches_str
            return ""
        with patch.object(det, "run", side_effect=mock_run):
            return det.detect_branches(root)

    def test_detects_dev_as_staging(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "dev", "feature/x"])
        assert r["staging"]["value"] == "dev"
        assert r["staging"]["confidence"] == "high"

    def test_detects_staging_branch(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "staging"])
        assert r["staging"]["value"] == "staging"

    def test_detects_develop_as_staging(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "develop"])
        assert r["staging"]["value"] == "develop"

    def test_detects_main_as_production(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "dev"])
        assert r["production"]["value"] == "main"
        assert r["production"]["confidence"] == "high"

    def test_detects_master_as_production(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["master", "develop"])
        assert r["production"]["value"] == "master"

    def test_detects_prod_branch(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["prod", "dev"])
        assert r["production"]["value"] == "prod"

    def test_defaults_when_no_branches(self, tmp_project):
        r = self._run_with_branches(tmp_project, [])
        assert r["staging"]["value"] == "dev"
        assert r["staging"]["confidence"] == "low"
        assert r["production"]["value"] == "main"

    def test_deduplicates_remote_tracking_branches(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "origin/main", "remotes/origin/dev", "dev"])
        assert r["all"].count("main") == 1
        assert r["all"].count("dev") == 1

    def test_all_list_is_sorted(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["zebra", "alpha", "main"])
        assert r["all"] == sorted(r["all"])

    def test_detects_develop_as_dev_integration_branch(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "develop"])
        assert r["dev"]["value"] == "develop"
        assert r["dev"]["confidence"] == "high"

    def test_detects_dev_as_integration_branch(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "dev"])
        assert r["dev"]["value"] == "dev"
        assert r["dev"]["confidence"] == "high"

    def test_prefers_develop_over_dev_for_integration(self, tmp_project):
        """develop is checked before dev in priority list."""
        r = self._run_with_branches(tmp_project, ["main", "develop", "dev"])
        assert r["dev"]["value"] == "develop"

    def test_dev_falls_back_to_staging_when_no_integration_branch(self, tmp_project):
        """When no dedicated integration branch found, dev mirrors staging."""
        r = self._run_with_branches(tmp_project, ["main", "staging"])
        # staging is "staging", dev should fall back to that
        assert r["dev"]["value"] == r["staging"]["value"]

    def test_dev_defaults_to_dev_when_no_branches(self, tmp_project):
        r = self._run_with_branches(tmp_project, [])
        assert r["dev"]["value"] == "dev"
        assert r["dev"]["confidence"] == "low"

    def test_dev_key_present_in_result(self, tmp_project):
        r = self._run_with_branches(tmp_project, ["main", "dev"])
        assert "dev" in r


# ── Tests: detect_ci ──────────────────────────────────────────────────────────

class TestDetectCi:
    def test_github_from_workflows_dir(self, tmp_project):
        (tmp_project / ".github" / "workflows").mkdir(parents=True)
        (tmp_project / ".github" / "workflows" / "ci.yml").write_text("")
        r = det.detect_ci(tmp_project, {})
        assert r["platform"]["value"] == "github"
        assert r["platform"]["source"] == ".github/workflows"
        assert r["platform"]["confidence"] == "high"

    def test_gitlab_from_ci_yml(self, tmp_project):
        (tmp_project / ".gitlab-ci.yml").write_text("")
        r = det.detect_ci(tmp_project, {})
        assert r["platform"]["value"] == "gitlab"
        assert r["platform"]["source"] == ".gitlab-ci.yml"

    def test_infers_from_git_remote(self, tmp_project):
        git_info = {"platform": {"value": "github", "source": "git-remote", "confidence": "high"}}
        r = det.detect_ci(tmp_project, git_info)
        assert r["platform"]["value"] == "github"
        assert r["platform"]["source"] == "git-remote"

    def test_file_detection_beats_git_remote(self, tmp_project):
        """CI config files are authoritative."""
        (tmp_project / ".gitlab-ci.yml").write_text("")
        git_info = {"platform": {"value": "github", "source": "git-remote", "confidence": "high"}}
        r = det.detect_ci(tmp_project, git_info)
        assert r["platform"]["value"] == "gitlab"


# ── Tests: detect_secrets ────────────────────────────────────────────────────

class TestDetectSecrets:
    def _run(self, root, uname):
        def mock_run(cmd, cwd=None):
            if cmd == ["uname", "-s"]:
                return uname
            return ""
        with patch.object(det, "run", side_effect=mock_run):
            return det.detect_secrets(root)

    def test_darwin_returns_aws(self, tmp_project):
        r = self._run(tmp_project, "Darwin")
        assert r["backend"]["value"] == "aws"
        assert r["backend"]["confidence"] == "high"

    def test_linux_returns_infisical(self, tmp_project):
        r = self._run(tmp_project, "Linux")
        assert r["backend"]["value"] == "infisical"
        assert r["backend"]["confidence"] == "high"


# ── Tests: detect_task_management ─────────────────────────────────────────────

class TestDetectTaskManagement:
    def _run(self, root, uname, asana_exists=False, gitlab_exists=False):
        home = root / "fake_home"
        home.mkdir(exist_ok=True)
        if asana_exists:
            (home / ".asana-token").write_text("fake-token")
        if gitlab_exists:
            (home / ".gitlab-token").write_text("fake-token")

        def mock_run(cmd, cwd=None):
            if cmd == ["uname", "-s"]:
                return uname
            return ""

        with (
            patch.object(det, "run", side_effect=mock_run),
            patch("pathlib.Path.home", return_value=home),
        ):
            return det.detect_task_management(root)

    def test_darwin_suggests_asana(self, tmp_project):
        r = self._run(tmp_project, "Darwin", asana_exists=True)
        assert r["backend"]["value"] == "asana"

    def test_linux_suggests_gitlab(self, tmp_project):
        r = self._run(tmp_project, "Linux", gitlab_exists=True)
        assert r["backend"]["value"] == "gitlab"

    def test_asana_token_exists_flag(self, tmp_project):
        r = self._run(tmp_project, "Darwin", asana_exists=True)
        assert r["asana_token_exists"] is True
        assert r["gitlab_token_exists"] is False

    def test_gitlab_token_exists_flag(self, tmp_project):
        r = self._run(tmp_project, "Linux", gitlab_exists=True)
        assert r["gitlab_token_exists"] is True

    def test_no_tokens_still_returns_backend(self, tmp_project):
        r = self._run(tmp_project, "Darwin")
        assert r["backend"]["value"] == "asana"
        assert r["asana_token_exists"] is False

    def test_asana_hint_when_token_found(self, tmp_project):
        r = self._run(tmp_project, "Darwin", asana_exists=True)
        assert "asana_hint" in r


# ── Tests: detect_deployment ─────────────────────────────────────────────────

class TestDetectDeployment:
    def test_no_indicators_for_empty_project(self, tmp_project):
        r = det.detect_deployment(tmp_project, None)
        assert r["has_deploy_indicators"] is False
        assert r["hints"] == []

    def test_detects_makefile_deploy_targets(self, fullstack_project):
        r = det.detect_deployment(fullstack_project, None)
        assert r["has_deploy_indicators"] is True
        assert "deploy-staging" in r["makefile_deploy_targets"]
        assert "deploy-prod" in r["makefile_deploy_targets"]

    def test_hint_includes_deploy_targets(self, fullstack_project):
        r = det.detect_deployment(fullstack_project, None)
        assert any("deploy-staging" in h for h in r["hints"])

    def test_detects_deploy_scripts(self, tmp_path):
        scripts = tmp_path / "scripts"
        scripts.mkdir()
        (scripts / "deploy-staging.sh").write_text("#!/bin/bash\n")
        r = det.detect_deployment(tmp_path, None)
        assert r["has_deploy_indicators"] is True
        assert any("deploy-staging.sh" in h for h in r["hints"])

    def test_suggested_strategy_is_standard(self, tmp_project):
        r = det.detect_deployment(tmp_project, None)
        assert r["suggested_strategy"]["value"] == "standard"


# ── Tests: full detect() integration ─────────────────────────────────────────

class TestDetectIntegration:
    def test_project_yaml_exists_false(self, tmp_project):
        r = run_detect(tmp_project)
        assert r["project_yaml_exists"] is False

    def test_project_yaml_exists_true(self, tmp_project):
        (tmp_project / "PROJECT.yaml").write_text("name: test\n")
        r = run_detect(tmp_project)
        assert r["project_yaml_exists"] is True

    def test_project_root_is_absolute(self, tmp_project):
        r = run_detect(tmp_project)
        assert Path(r["project_root"]).is_absolute()

    def test_needs_input_has_deployment(self, python_project):
        r = run_detect(python_project)
        fields = [n["field"] for n in r["needs_input"]]
        assert "deployment" in fields

    def test_needs_input_no_description_when_missing(self, python_project):
        # python_project has description in pyproject.toml — should NOT be in needs_input
        r = run_detect(python_project)
        fields = [n["field"] for n in r["needs_input"]]
        assert "description" not in fields

    def test_needs_input_includes_description_when_absent(self, tmp_path):
        (tmp_path / "Makefile").write_text("test:\n\tpytest\n")
        r = run_detect(tmp_path)
        fields = [n["field"] for n in r["needs_input"]]
        assert "description" in fields

    def test_optional_sections_present(self, tmp_project):
        r = run_detect(tmp_project)
        assert "databases" in r["optional_sections"]
        assert "deployment" in r["optional_sections"]
        assert "task_management" in r["optional_sections"]
        assert "notifications" in r["optional_sections"]
        assert "infrastructure" in r["optional_sections"]

    def test_database_section_flagged_for_db_services(self, fullstack_project):
        r = run_detect(fullstack_project, uname="Darwin")
        assert r["optional_sections"]["databases"]["should_configure"] is True
        assert "postgres" in r["optional_sections"]["databases"]["hint"]

    def test_no_db_flag_for_non_db_services(self, typescript_project):
        (typescript_project / "docker-compose.yml").write_text(
            "services:\n  app:\n    image: nginx\n"
        )
        r = run_detect(typescript_project)
        assert r["optional_sections"]["databases"]["should_configure"] is False

    def test_full_python_project_structure(self, python_project):
        r = run_detect(
            python_project,
            git_remote="git@git.turnersrus.com:eric/my-api.git",
            branches="main\ndev\nfeature/auth",
            uname="Linux",
        )
        assert r["detections"]["name"]["value"] == "my-api"
        assert any(l["name"] == "python" for l in r["detections"]["languages"])
        assert r["detections"]["testing"]["command"]["value"] == "make test"
        assert r["detections"]["git"]["platform"]["value"] == "gitlab"
        assert r["detections"]["branches"]["staging"]["value"] == "dev"
        assert r["detections"]["branches"]["production"]["value"] == "main"
        assert r["detections"]["secrets"]["backend"]["value"] == "infisical"

    def test_full_typescript_macos_project(self, typescript_project):
        r = run_detect(
            typescript_project,
            git_remote="git@github.com:myorg/my-frontend.git",
            branches="main\ndevelop",
            uname="Darwin",
        )
        assert r["detections"]["name"]["value"] == "my-frontend"
        assert any(l["name"] == "typescript" for l in r["detections"]["languages"])
        assert r["detections"]["git"]["platform"]["value"] == "github"
        assert r["detections"]["secrets"]["backend"]["value"] == "aws"
        assert r["detections"]["task_management"]["backend"]["value"] == "asana"

    def test_output_is_json_serializable(self, fullstack_project):
        """Ensure the entire output can be serialized to JSON without errors."""
        r = run_detect(fullstack_project)
        serialized = json.dumps(r)
        parsed = json.loads(serialized)
        assert parsed["project_root"] == r["project_root"]


# ── Tests: helper functions ───────────────────────────────────────────────────

class TestHelpers:
    def test_detected_structure(self):
        d = det.detected("myvalue", "package.json", "high")
        assert d == {"value": "myvalue", "source": "package.json", "confidence": "high"}

    def test_detected_default_confidence(self):
        d = det.detected("x", "source")
        assert d["confidence"] == "high"

    def test_read_json_returns_empty_on_missing(self, tmp_path):
        result = det.read_json(tmp_path / "nonexistent.json")
        assert result == {}

    def test_read_json_returns_empty_on_invalid(self, tmp_path):
        (tmp_path / "bad.json").write_text("not json {{{")
        result = det.read_json(tmp_path / "bad.json")
        assert result == {}

    def test_read_toml_extracts_project_name(self, tmp_path):
        (tmp_path / "test.toml").write_text('[project]\nname = "myapp"\n')
        result = det.read_toml(tmp_path / "test.toml")
        assert result["project"]["name"] == "myapp"

    def test_read_makefile_targets(self, tmp_path):
        (tmp_path / "Makefile").write_text(
            "test:\n\tpytest\n\ncoverage:\n\tpytest --cov\n\n.PHONY: test coverage\n"
        )
        targets = det.read_makefile_targets(tmp_path / "Makefile")
        assert "test" in targets
        assert "coverage" in targets
        assert ".PHONY" not in targets

    def test_read_yaml_services_regex_fallback(self, tmp_path):
        """Should work even without pyyaml via regex fallback."""
        (tmp_path / "docker-compose.yml").write_text(
            "services:\n  web:\n    image: nginx\n  db:\n    image: postgres\n"
        )
        # Patch yaml import to fail, forcing regex fallback
        import builtins
        real_import = builtins.__import__
        def fail_yaml(name, *args, **kwargs):
            if name == "yaml":
                raise ImportError("no yaml")
            return real_import(name, *args, **kwargs)
        with patch("builtins.__import__", side_effect=fail_yaml):
            services = det.read_yaml_services(tmp_path / "docker-compose.yml")
        assert "web" in services
        assert "db" in services
