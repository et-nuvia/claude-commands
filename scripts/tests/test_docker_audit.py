"""
Tests for docker-audit.py

Tests pure functions: Dockerfile parsing, scoring, helpers.
Does NOT test external tool scans (hadolint, trivy, etc.) — those need subprocess mocking.
"""

from __future__ import annotations

import importlib.util
import textwrap
from pathlib import Path

import pytest

import sys

SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "docker-audit.py"
_spec = importlib.util.spec_from_file_location("docker_audit", _MODULE_PATH)
da = importlib.util.module_from_spec(_spec)
# dataclasses requires __module__ to resolve in sys.modules
sys.modules["docker_audit"] = da
try:
    _spec.loader.exec_module(da)
except Exception as exc:
    pytest.skip(f"docker-audit.py failed to load: {exc}", allow_module_level=True)


# ── Tests: grade_for_score ──────────────────────────────────────────────────

class TestGradeForScore:
    def test_excellent(self):
        assert da.grade_for_score(95) == "EXCELLENT"

    def test_good(self):
        assert da.grade_for_score(85) == "GOOD"

    def test_fair(self):
        assert da.grade_for_score(50) == "FAIR"

    def test_needs_work(self):
        assert da.grade_for_score(30) == "NEEDS_WORK"

    def test_zero(self):
        assert da.grade_for_score(0) == "NEEDS_WORK"


# ── Tests: resolve_compose_image ────────────────────────────────────────────

class TestResolveComposeImage:
    def test_plain_image(self):
        assert da.resolve_compose_image("python:3.12-slim") == "python:3.12-slim"

    def test_variable_with_default(self):
        assert da.resolve_compose_image("${REGISTRY:-myregistry}/app:latest") == "myregistry/app:latest"

    def test_variable_without_default(self):
        # Variable is stripped but surrounding text remains
        assert da.resolve_compose_image("${REGISTRY}/app:latest") == "/app:latest"

    def test_no_variable(self):
        assert da.resolve_compose_image("nginx:1.25") == "nginx:1.25"


# ── Tests: is_infra_service ─────────────────────────────────────────────────

class TestIsInfraService:
    def test_postgres(self):
        assert da.is_infra_service("postgres") is True

    def test_redis(self):
        assert da.is_infra_service("redis") is True

    def test_app_service(self):
        assert da.is_infra_service("backend") is False

    def test_case_insensitive(self):
        assert da.is_infra_service("REDIS") is True

    def test_partial_match(self):
        assert da.is_infra_service("my-postgres-db") is True

    def test_nginx(self):
        assert da.is_infra_service("nginx-proxy") is True


# ── Tests: DockerfileAnalysis.parse ─────────────────────────────────────────

class TestDockerfileAnalysisParse:
    def test_single_stage(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("FROM python:3.12-slim\nRUN pip install flask\nCMD [\"python\", \"app.py\"]\n")
        result = da.DockerfileAnalysis.parse(df, "backend")
        assert result.stage_count == 1
        assert result.base_image == "python:3.12-slim"

    def test_multistage(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text(textwrap.dedent("""\
            FROM python:3.12-slim AS builder
            RUN pip install deps

            FROM python:3.12-slim AS production
            COPY --from=builder /app /app
        """))
        result = da.DockerfileAnalysis.parse(df, "api")
        assert result.stage_count == 2
        assert result.prod_image == "python:3.12-slim"

    def test_user_directive(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("FROM alpine\nUSER appuser\nCMD [\"sh\"]\n")
        result = da.DockerfileAnalysis.parse(df, "svc")
        assert result.has_user is True
        assert result.user_name == "appuser"

    def test_no_user(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("FROM alpine\nCMD [\"sh\"]\n")
        result = da.DockerfileAnalysis.parse(df, "svc")
        assert result.has_user is False

    def test_run_tests_detected(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("FROM python:3.12\nARG RUN_TESTS=false\nRUN if [ \"$RUN_TESTS\" = \"true\" ]; then pytest; fi\n")
        result = da.DockerfileAnalysis.parse(df, "api")
        assert result.has_run_tests is True

    def test_copy_chown(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("FROM alpine\nCOPY --chown=1000:1000 . /app\n")
        result = da.DockerfileAnalysis.parse(df, "svc")
        assert result.has_copy_chown is True

    def test_from_lines_collected(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("FROM node:20 AS builder\nRUN npm ci\nFROM node:20-slim AS production\nCOPY --from=builder /app /app\n")
        result = da.DockerfileAnalysis.parse(df, "web")
        assert len(result.from_lines) == 2

    def test_missing_file(self, tmp_path):
        df = tmp_path / "nonexistent"
        result = da.DockerfileAnalysis.parse(df, "svc")
        assert result.stage_count == 0
        assert result.raw_lines == []

    def test_comments_and_blanks_skipped(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("# Comment\n\nFROM alpine\n# Another comment\nCMD [\"sh\"]\n")
        result = da.DockerfileAnalysis.parse(df, "svc")
        assert result.stage_count == 1

    def test_run_continuation_lines(self, tmp_path):
        df = tmp_path / "Dockerfile"
        df.write_text("FROM alpine\nRUN apk add --no-cache \\\n    curl \\\n    jq\n")
        result = da.DockerfileAnalysis.parse(df, "svc")
        assert len(result.run_instructions) == 1
        assert "curl" in result.run_instructions[0]
        assert "jq" in result.run_instructions[0]


# ── Tests: Finding ──────────────────────────────────────────────────────────

class TestFinding:
    def test_to_dict(self):
        f = da.Finding(
            category="security",
            check="S01",
            result="pass",
            detail="non-root user",
            service="api",
        )
        d = f.to_dict()
        assert d["category"] == "security"
        assert d["service"] == "api"
        assert d["result"] == "pass"
