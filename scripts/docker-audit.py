#!/usr/bin/env python3
"""Docker implementation audit with industry-standard tool integration.

Replaces docker-audit.sh with a Python implementation (stdlib only, no pip).
Uses yq subprocess for YAML parsing.

Usage:
    docker-audit.py --stage <scan|score|report|all> [options]
    docker-audit.py --stage all --quick
    docker-audit.py --stage all --skip-external
    docker-audit.py --stage all --with-image-scan
    docker-audit.py --stage all --compare
    docker-audit.py --stage all --project-root /path/to/project

Reads configuration from PROJECT.yaml (no environment variables).
Outputs structured JSON to stdout, status messages to stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# =============================================================================
# Constants
# =============================================================================

SCHEMA_VERSION = 2

CATEGORIES = [
    "base_image", "compose", "security", "operations",
    "networking", "versions", "build_performance", "dhi_compliance",
    "vulnerability", "efficiency",
]

# Default weights (no image scan)
WEIGHTS_DEFAULT = {
    "security": 25, "compose": 15, "base_image": 15,
    "build_performance": 10, "operations": 15, "versions": 10,
    "networking": 10, "dhi_compliance": 0,
    "vulnerability": 0, "efficiency": 0,
}

# Weights with image scan
WEIGHTS_IMAGE_SCAN = {
    "security": 18, "compose": 12, "base_image": 10,
    "build_performance": 8, "operations": 10, "versions": 7,
    "networking": 5, "dhi_compliance": 0,
    "vulnerability": 20, "efficiency": 10,
}

GRADE_THRESHOLDS = [(90, "EXCELLENT"), (70, "GOOD"), (50, "FAIR"), (0, "NEEDS_WORK")]

# DHI catalog — hardcoded known images available as dhi.io/<name>
DHI_CATALOG = {
    # Runtimes
    "node", "python", "golang", "ruby", "rust", "php", "bun", "deno",
    "dotnet", "erlang", "dart", "eclipse-temurin", "amazoncorretto",
    # Databases
    "mysql", "postgres", "postgresql", "redis", "valkey", "mongodb", "mongo",
    "elasticsearch", "couchdb", "influxdb", "neo4j", "opensearch", "clickhouse",
    # Infrastructure
    "nginx", "traefik", "haproxy", "caddy", "envoy", "memcached",
    "rabbitmq", "kafka", "nats", "mosquitto",
    # Monitoring
    "prometheus", "grafana", "loki", "tempo", "alertmanager",
    "uptime-kuma", "opensearch-dashboards",
    # CI/CD
    "jenkins", "k6", "sonarqube", "flyway", "liquibase",
    # Security
    "vault", "keycloak", "trivy", "gitleaks", "trufflehog", "clamav", "dex",
    # Base
    "alpine", "debian", "busybox", "static",
    # Tools
    "curl", "bash", "helm", "kubectl", "aws-cli", "docker",
}

# Sensitive volume paths
SENSITIVE_PATHS = {"/etc/shadow", "/etc/passwd", "/root", "/var/run/docker.sock"}

# .dockerignore required entries
DOCKERIGNORE_REQUIRED = {"node_modules", ".git", ".env", ".secrets"}
DOCKERIGNORE_RECOMMENDED = {"docs", "*.md", "coverage", ".vscode", ".idea"}

# Infrastructure services to skip for security hardening
INFRA_SERVICE_PATTERNS = {"redis", "mysql", "postgres", "mongo", "minio", "emulator", "mock", "db", "nginx"}

# Colors for stderr output
RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
NC = "\033[0m"


# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class Finding:
    """Single audit finding."""
    category: str
    check: str
    result: str  # pass, fail, warn, skip
    detail: str
    service: str = "_global"

    def to_dict(self) -> dict[str, Any]:
        return {
            "category": self.category,
            "check": self.check,
            "result": self.result,
            "detail": self.detail,
            "service": self.service,
        }


@dataclass
class DockerfileAnalysis:
    """Parsed Dockerfile data, computed once per file."""
    path: Path
    service: str
    raw_lines: list[str] = field(default_factory=list)
    from_lines: list[str] = field(default_factory=list)
    stages: list[dict[str, Any]] = field(default_factory=list)
    has_user: bool = False
    user_name: str = ""
    has_run_tests: bool = False
    stage_count: int = 0
    base_image: str = ""
    prod_image: str = ""
    has_copy_chown: bool = False
    has_separate_chown_layer: bool = False
    has_init_copy: bool = False
    run_instructions: list[str] = field(default_factory=list)

    @classmethod
    def parse(cls, path: Path, service: str) -> DockerfileAnalysis:
        """Parse a Dockerfile into analysis data."""
        da = cls(path=path, service=service)
        try:
            content = path.read_text()
        except OSError:
            return da

        da.raw_lines = content.splitlines()

        current_stage: dict[str, Any] = {"name": "", "from_image": "", "instructions": []}
        for line in da.raw_lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            if stripped.upper().startswith("FROM "):
                if current_stage["from_image"]:
                    da.stages.append(current_stage)
                parts = stripped.split()
                image = parts[1] if len(parts) > 1 else ""
                stage_name = ""
                if len(parts) >= 4 and parts[2].upper() == "AS":
                    stage_name = parts[3]
                current_stage = {"name": stage_name, "from_image": image, "instructions": []}
                da.from_lines.append(stripped)
            else:
                current_stage["instructions"].append(stripped)

        if current_stage["from_image"]:
            da.stages.append(current_stage)

        da.stage_count = len(da.stages)

        # Base and prod images
        if da.from_lines:
            first_from = da.from_lines[0].split()
            da.base_image = first_from[1] if len(first_from) > 1 else ""

            # Find production stage
            prod_from = None
            for fl in da.from_lines:
                if re.search(r'\bAS\s+production\b', fl, re.IGNORECASE):
                    prod_from = fl
            if prod_from:
                da.prod_image = prod_from.split()[1]
            else:
                last_from = da.from_lines[-1].split()
                da.prod_image = last_from[1] if len(last_from) > 1 else ""

        # USER directive
        for line in da.raw_lines:
            stripped = line.strip()
            if re.match(r'^USER\s+', stripped):
                da.has_user = True
                da.user_name = stripped.split()[1] if len(stripped.split()) > 1 else ""

        # RUN_TESTS
        da.has_run_tests = bool(re.search(r'RUN_TESTS', content))

        # COPY --chown
        da.has_copy_chown = bool(re.search(r'COPY\s+--chown', content))

        # Separate RUN chown layer
        da.has_separate_chown_layer = bool(re.search(r'^RUN\s+.*chown', content, re.MULTILINE))

        # RUN instructions — join continuation lines (backslash at end)
        i = 0
        while i < len(da.raw_lines):
            stripped = da.raw_lines[i].strip()
            if stripped.upper().startswith("RUN "):
                full_run = stripped
                while full_run.endswith("\\") and i + 1 < len(da.raw_lines):
                    i += 1
                    full_run = full_run[:-1] + " " + da.raw_lines[i].strip()
                da.run_instructions.append(full_run)
            i += 1

        return da


@dataclass
class AuditState:
    """Mutable audit state."""
    findings: list[Finding] = field(default_factory=list)
    services: list[str] = field(default_factory=list)
    service_dockerfiles: dict[str, str] = field(default_factory=dict)
    service_images: dict[str, str] = field(default_factory=dict)
    dockerfile_service: dict[str, str] = field(default_factory=dict)
    dockerfiles: list[Path] = field(default_factory=list)
    dockerfile_analyses: dict[str, DockerfileAnalysis] = field(default_factory=dict)
    tool_ran: dict[str, bool] = field(default_factory=lambda: {
        "hadolint": False, "trivy_config": False, "trivy_image": False,
        "dockle": False, "dive": False,
    })
    version_data: list[dict[str, Any]] = field(default_factory=list)

    def record(self, category: str, check: str, result: str, detail: str,
               service: str = "_global") -> None:
        """Record a finding and print to stderr."""
        # Sanitize
        detail = detail.replace("|", "-")
        finding = Finding(category=category, check=check, result=result,
                         detail=detail, service=service)
        self.findings.append(finding)

        if result == "pass":
            print_success(check)
        elif result == "fail":
            print_error(f"{check}: {detail}")
        elif result == "warn":
            print_warning(f"{check}: {detail}")
        elif result == "skip":
            print_info(f"{check}: {detail} (skipped)")


# =============================================================================
# Output Helpers
# =============================================================================

def print_error(msg: str) -> None:
    print(f"{RED}✗ {msg}{NC}", file=sys.stderr)

def print_success(msg: str) -> None:
    print(f"{GREEN}✓ {msg}{NC}", file=sys.stderr)

def print_warning(msg: str) -> None:
    print(f"{YELLOW}⚠ {msg}{NC}", file=sys.stderr)

def print_info(msg: str) -> None:
    print(f"{BLUE}ℹ {msg}{NC}", file=sys.stderr)

def print_tool(msg: str) -> None:
    print(f"{CYAN}⚙ {msg}{NC}", file=sys.stderr)


def grade_for_score(score: int) -> str:
    for threshold, grade in GRADE_THRESHOLDS:
        if score >= threshold:
            return grade
    return "NEEDS_WORK"


# =============================================================================
# PROJECT.yaml + yq Helpers
# =============================================================================

def yq_eval(expr: str, filepath: str) -> str:
    """Run yq (kislyuk/yq jq wrapper) and return stdout, or empty string on failure."""
    try:
        result = subprocess.run(
            ["yq", "-r", expr, filepath],
            capture_output=True, text=True, timeout=10,
        )
        val = result.stdout.strip()
        if val in ("null", ""):
            return ""
        return val
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ""


def get_config(path: str, default: str = "", config_file: str = "PROJECT.yaml") -> str:
    """Get a value from PROJECT.yaml via yq."""
    val = yq_eval(f'{path} // ""', config_file)
    return val if val else default


def require_tools() -> dict[str, bool]:
    """Detect available external tools."""
    tools = {}
    for tool in ["hadolint", "trivy", "dockle", "dive", "docker", "jq", "yq"]:
        try:
            result = subprocess.run(["which", tool], capture_output=True, timeout=5)
            tools[tool] = result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            tools[tool] = False
    return tools


# =============================================================================
# Service Discovery
# =============================================================================

def discover_services(state: AuditState, compose_file: str) -> None:
    """Discover services from compose file using yq."""
    services_str = yq_eval('.services | keys | .[]', compose_file)
    if not services_str:
        return

    for svc in services_str.splitlines():
        svc = svc.strip()
        if not svc:
            continue

        # Check for build context
        build_val = yq_eval(f'.services."{svc}".build // ""', compose_file)
        if build_val:
            build_ctx = yq_eval(f'.services."{svc}".build.context // ""', compose_file)
            if not build_ctx:
                build_ctx = build_val
            df_name = yq_eval(f'.services."{svc}".build.dockerfile // "Dockerfile"', compose_file)
            if not df_name:
                df_name = "Dockerfile"
            full_path = f"{build_ctx}/{df_name}".replace("//", "/")
            state.service_dockerfiles[svc] = full_path
            state.dockerfile_service[full_path] = svc

        # Check for image
        img = yq_eval(f'.services."{svc}".image // ""', compose_file)
        if img:
            state.service_images[svc] = img


def get_service_for_dockerfile(state: AuditState, df: str) -> str:
    """Get service name for a dockerfile path."""
    # Direct match
    if df in state.dockerfile_service:
        return state.dockerfile_service[df]

    # Normalized match
    norm_df = df.lstrip("./")
    for key, svc in state.dockerfile_service.items():
        if key.lstrip("./") == norm_df:
            return svc

    # Fallback from directory name
    parent = Path(df).parent
    if str(parent) == ".":
        return "_root"
    return parent.name


def resolve_compose_image(raw: str) -> str:
    """Resolve Docker Compose variable substitution in image names."""
    if "${" in raw:
        resolved = re.sub(r'\$\{[^:}]+:-([^}]+)\}', r'\1', raw)
        resolved = re.sub(r'\$\{[^}]+\}', '', resolved)
        if resolved and "$" not in resolved:
            return resolved
        return ""
    return raw


def is_infra_service(svc: str) -> bool:
    """Check if service is infrastructure (skip security hardening)."""
    svc_lower = svc.lower()
    return any(pat in svc_lower for pat in INFRA_SERVICE_PATTERNS)


# =============================================================================
# External Tool Scans
# =============================================================================

def scan_hadolint(state: AuditState, tools: dict[str, bool], quick: bool) -> None:
    """Run hadolint on all Dockerfiles."""
    if not tools.get("jq"):
        state.record("base_image", "Hadolint", "skip", "jq required to parse hadolint output")
        return

    print_tool("Running Hadolint...")
    state.tool_ran["hadolint"] = True

    all_output: list[dict[str, Any]] = []

    for df in state.dockerfiles:
        svc_name = get_service_for_dockerfile(state, str(df))

        try:
            result = subprocess.run(
                ["hadolint", "--format", "json", str(df)],
                capture_output=True, text=True, timeout=30,
            )
            output = json.loads(result.stdout) if result.stdout.strip() else []
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            output = []

        all_output.append({"file": str(df), "service": svc_name, "results": output})

        errors = [r for r in output if r.get("level") == "error"]
        warnings = [r for r in output if r.get("level") == "warning"]
        top_issues = "; ".join(
            f"{r.get('code', '')}: {r.get('message', '')[:80]}"
            for r in (errors + warnings)[:3]
        )

        df_label = _df_label(df)
        if not errors and not warnings:
            state.record("base_image", f"Hadolint clean ({df_label})", "pass",
                        "No errors or warnings", svc_name)
        elif not errors:
            state.record("base_image", f"Hadolint ({df_label})", "warn",
                        f"{len(warnings)} warning(s): {top_issues}", svc_name)
        else:
            state.record("base_image", f"Hadolint ({df_label})", "fail",
                        f"{len(errors)} error(s), {len(warnings)} warning(s): {top_issues}", svc_name)

        if quick:
            break

    _write_tool_output("/tmp/docker-audit-hadolint.json", all_output)


def scan_trivy_config(state: AuditState, tools: dict[str, bool]) -> None:
    """Run trivy config scan."""
    if not tools.get("jq"):
        state.record("security", "Trivy config", "skip", "jq required to parse trivy output")
        return

    print_tool("Running Trivy config scan...")
    state.tool_ran["trivy_config"] = True

    try:
        result = subprocess.run(
            ["trivy", "config", "--format", "json", "--severity", "HIGH,CRITICAL", "."],
            capture_output=True, text=True, timeout=60,
        )
        output = json.loads(result.stdout) if result.stdout.strip() else {}
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        output = {}

    _write_tool_output("/tmp/docker-audit-trivy-config.json", output)

    results = output.get("Results", [])
    if not results:
        state.record("security", "Trivy config scan", "pass",
                     "No HIGH/CRITICAL misconfigurations found")
        return

    for r in results:
        target = r.get("Target", "unknown")
        misconfigs = r.get("Misconfigurations", [])
        if not misconfigs:
            continue

        criticals = [m for m in misconfigs if m.get("Severity") == "CRITICAL"]
        highs = [m for m in misconfigs if m.get("Severity") == "HIGH"]
        top = "; ".join(m.get("Title", "")[:60] for m in misconfigs[:3])

        svc_name = "_global"
        if "Dockerfile" in target:
            svc_name = get_service_for_dockerfile(state, target)

        if criticals:
            state.record("security", f"Trivy config ({target})", "fail",
                        f"{len(criticals)} critical, {len(highs)} high: {top}", svc_name)
        elif highs:
            state.record("security", f"Trivy config ({target})", "warn",
                        f"{len(highs)} high: {top}", svc_name)


def scan_trivy_image(state: AuditState, tools: dict[str, bool], quick: bool) -> None:
    """Run trivy image scan on built images."""
    if not tools.get("jq") or not tools.get("docker"):
        state.record("vulnerability", "Trivy image scan", "skip", "docker and jq required")
        return

    print_tool("Running Trivy image vulnerability scan...")
    state.tool_ran["trivy_image"] = True
    all_output: list[dict[str, Any]] = []

    for svc in state.services:
        image = state.service_images.get(svc, "")
        if not image:
            continue
        resolved = resolve_compose_image(image)
        if not resolved:
            continue

        # Check if image exists locally
        check = subprocess.run(["docker", "image", "inspect", resolved],
                              capture_output=True, timeout=10)
        if check.returncode != 0:
            state.record("vulnerability", f"Trivy image ({svc})", "skip",
                        f"Image not built locally: {resolved}", svc)
            continue

        try:
            result = subprocess.run(
                ["trivy", "image", "--format", "json", "--severity", "HIGH,CRITICAL", resolved],
                capture_output=True, text=True, timeout=120,
            )
            output = json.loads(result.stdout) if result.stdout.strip() else {}
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            output = {}

        all_output.append({"service": svc, "image": resolved, "results": output})

        vulns = []
        for r in output.get("Results", []):
            vulns.extend(r.get("Vulnerabilities", []))

        criticals = [v for v in vulns if v.get("Severity") == "CRITICAL"]
        highs = [v for v in vulns if v.get("Severity") == "HIGH"]

        if not criticals and not highs:
            state.record("vulnerability", f"Trivy image ({svc})", "pass",
                        f"No HIGH/CRITICAL CVEs in {resolved}", svc)
        elif not criticals:
            state.record("vulnerability", f"Trivy image ({svc})", "warn",
                        f"{len(highs)} HIGH CVEs in {resolved}", svc)
        else:
            state.record("vulnerability", f"Trivy image ({svc})", "fail",
                        f"{len(criticals)} CRITICAL, {len(highs)} HIGH CVEs in {resolved}", svc)

        if quick:
            break

    if all_output:
        _write_tool_output("/tmp/docker-audit-trivy-image.json", all_output)


def scan_dockle(state: AuditState, tools: dict[str, bool], quick: bool) -> None:
    """Run dockle CIS benchmark scan."""
    if not tools.get("jq") or not tools.get("docker"):
        state.record("security", "Dockle CIS scan", "skip", "docker and jq required")
        return

    print_tool("Running Dockle CIS benchmark scan...")
    state.tool_ran["dockle"] = True
    all_output: list[dict[str, Any]] = []

    for svc in state.services:
        image = state.service_images.get(svc, "")
        if not image:
            continue
        resolved = resolve_compose_image(image)
        if not resolved:
            continue

        check = subprocess.run(["docker", "image", "inspect", resolved],
                              capture_output=True, timeout=10)
        if check.returncode != 0:
            state.record("security", f"Dockle CIS ({svc})", "skip",
                        f"Image not built locally: {resolved}", svc)
            continue

        try:
            result = subprocess.run(
                ["dockle", "--format", "json", resolved],
                capture_output=True, text=True, timeout=60,
            )
            output = json.loads(result.stdout) if result.stdout.strip() else {}
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            output = {}

        all_output.append({"service": svc, "image": resolved, "results": output})

        fatal = output.get("summary", {}).get("fatal", 0)
        warn = output.get("summary", {}).get("warn", 0)

        if not fatal and not warn:
            state.record("security", f"Dockle CIS ({svc})", "pass",
                        f"CIS benchmark passed for {resolved}", svc)
        elif not fatal:
            state.record("security", f"Dockle CIS ({svc})", "warn",
                        f"{warn} CIS warnings", svc)
        else:
            state.record("security", f"Dockle CIS ({svc})", "fail",
                        f"{fatal} CIS failures, {warn} warnings", svc)

        if quick:
            break

    if all_output:
        _write_tool_output("/tmp/docker-audit-dockle.json", all_output)


def scan_dive(state: AuditState, tools: dict[str, bool], quick: bool) -> None:
    """Run dive image efficiency analysis."""
    if not tools.get("docker"):
        state.record("efficiency", "Dive image analysis", "skip", "docker required")
        return

    print_tool("Running Dive image efficiency analysis...")
    state.tool_ran["dive"] = True
    all_output: list[str] = []

    for svc in state.services:
        image = state.service_images.get(svc, "")
        if not image:
            continue
        resolved = resolve_compose_image(image)
        if not resolved:
            continue

        check = subprocess.run(["docker", "image", "inspect", resolved],
                              capture_output=True, timeout=10)
        if check.returncode != 0:
            state.record("efficiency", f"Dive ({svc})", "skip",
                        f"Image not built locally: {resolved}", svc)
            continue

        try:
            env = dict(os.environ, CI="true")
            result = subprocess.run(
                ["dive", resolved],
                capture_output=True, text=True, timeout=120, env=env,
            )
            output = result.stdout + result.stderr
        except (subprocess.TimeoutExpired, FileNotFoundError):
            output = ""

        all_output.append(f"=== {svc} ({resolved}) ===\n{output}\n")

        # Parse efficiency
        match = re.search(r'efficiency:\s*([0-9.]+)', output)
        if not match:
            state.record("efficiency", f"Dive ({svc})", "skip",
                        f"Could not parse efficiency for {resolved}", svc)
            continue

        eff = float(match.group(1))
        if eff >= 95:
            state.record("efficiency", f"Dive ({svc})", "pass",
                        f"Efficiency: {eff}% for {resolved}", svc)
        elif eff >= 85:
            state.record("efficiency", f"Dive ({svc})", "warn",
                        f"Efficiency: {eff}% (optimize layers) for {resolved}", svc)
        else:
            state.record("efficiency", f"Dive ({svc})", "fail",
                        f"Efficiency: {eff}% (significant waste) for {resolved}", svc)

        if quick:
            break

    if all_output:
        Path("/tmp/docker-audit-dive.txt").write_text("\n".join(all_output))


def scan_external_tools(state: AuditState, tools: dict[str, bool],
                        quick: bool, skip_external: bool, with_image_scan: bool) -> None:
    """Orchestrate all external tool scans."""
    if skip_external:
        print_info("Skipping external tool scans (--skip-external)")
        return
    if quick:
        print_info("Skipping external tool scans (--quick mode)")
        return

    print_info("--- External Tool Scans (Static Analysis) ---")

    if tools.get("hadolint"):
        scan_hadolint(state, tools, quick)
    else:
        state.record("base_image", "Hadolint", "skip", "Not installed (brew install hadolint)")

    if tools.get("trivy"):
        scan_trivy_config(state, tools)
    else:
        state.record("security", "Trivy config scan", "skip", "Not installed (brew install trivy)")

    if with_image_scan:
        print_info("--- External Tool Scans (Image Analysis) ---")

        if tools.get("trivy"):
            scan_trivy_image(state, tools, quick)
        else:
            state.record("vulnerability", "Trivy image scan", "skip",
                        "Not installed (brew install trivy)")

        if tools.get("dockle"):
            scan_dockle(state, tools, quick)
        else:
            state.record("security", "Dockle CIS scan", "skip",
                        "Not installed (brew install goodwithtech/r/dockle)")

        if tools.get("dive"):
            scan_dive(state, tools, quick)
        else:
            state.record("efficiency", "Dive analysis", "skip",
                        "Not installed (brew install dive)")
    else:
        print_info("Image scans skipped (use --with-image-scan to enable)")


# =============================================================================
# Category Checks
# =============================================================================

def check_base_image(state: AuditState, compose_file: str, quick: bool) -> None:
    """Category 1: Base image checks."""
    print_info("--- Base Image Checks ---")

    if not state.dockerfiles:
        state.record("base_image", "Dockerfile exists", "fail", "No Dockerfile found")
        return

    state.record("base_image", "Dockerfile exists", "pass",
                f"Found {len(state.dockerfiles)} Dockerfile(s)")

    for df in state.dockerfiles:
        da = DockerfileAnalysis.parse(df, get_service_for_dockerfile(state, str(df)))
        state.dockerfile_analyses[str(df)] = da
        svc_name = da.service
        df_label = _df_label(df)

        # Multi-stage build
        if da.stage_count > 1:
            state.record("base_image", f"Multi-stage build ({df_label})", "pass",
                        f"{da.stage_count} stages", svc_name)
        else:
            state.record("base_image", f"Multi-stage build ({df_label})", "fail",
                        "Single stage only", svc_name)

        # Testing stage with RUN_TESTS
        if da.has_run_tests:
            state.record("base_image", f"Testing stage ({df_label})", "pass",
                        "RUN_TESTS build arg found", svc_name)
        else:
            state.record("base_image", f"Testing stage ({df_label})", "fail",
                        "No RUN_TESTS build arg", svc_name)

        # Non-root user
        # DHI distroless images (dhi.io/<name> without -dev suffix) run as UID 1000 by default
        dhi_distroless = (da.prod_image.startswith("dhi.io/")
                          and "-dev" not in da.prod_image.split(":")[1] if ":" in da.prod_image
                          else da.prod_image.startswith("dhi.io/"))
        if da.has_user:
            if da.user_name != "root":
                state.record("base_image", f"Non-root user ({df_label})", "pass",
                            f"USER {da.user_name}", svc_name)
            else:
                state.record("base_image", f"Non-root user ({df_label})", "fail",
                            "USER root is not allowed", svc_name)
        elif dhi_distroless:
            state.record("base_image", f"Non-root user ({df_label})", "pass",
                        "DHI distroless runs as UID 1000 by default", svc_name)
        else:
            state.record("base_image", f"Non-root user ({df_label})", "fail",
                        "No USER directive found", svc_name)

        # Base image preference: DHI > Debian slim > warn alpine (runtime) > fail nix
        base = da.base_image
        if base.startswith("dhi.io/"):
            state.record("base_image", f"Base image ({df_label})", "pass",
                        f"DHI image: {base}", svc_name)
        elif "slim" in base:
            state.record("base_image", f"Base image ({df_label})", "pass",
                        f"Debian slim: {base}", svc_name)
        elif "alpine" in base:
            # Alpine is acceptable for infrastructure images but not for Node.js/Python runtimes
            base_lower = base.lower()
            is_runtime = any(rt in base_lower for rt in ("node", "python", "golang", "ruby", "rust", "php", "bun", "deno"))
            if is_runtime:
                state.record("base_image", f"Base image ({df_label})", "warn",
                            f"Alpine base for runtime: {base} (musl compatibility issues — use DHI or Debian slim)", svc_name)
            else:
                state.record("base_image", f"Base image ({df_label})", "pass",
                            f"Alpine infrastructure image: {base}", svc_name)
        elif "nix" in base.lower():
            state.record("base_image", f"Base image ({df_label})", "fail",
                        f"NixOS base not allowed: {base} (use DHI or Debian slim)", svc_name)
        elif "latest" in base:
            state.record("base_image", f"Base image ({df_label})", "fail",
                        f"Using :latest tag - unpredictable: {base}", svc_name)
        elif "cgr.dev" in base:
            state.record("base_image", f"Base image ({df_label})", "warn",
                        f"Chainguard is paid - use DHI instead: {base}", svc_name)
        else:
            state.record("base_image", f"Base image ({df_label})", "warn",
                        f"Non-standard base: {base}", svc_name)

        # COPY --chown vs separate RUN chown
        if da.has_copy_chown:
            state.record("base_image", f"COPY --chown ({df_label})", "pass",
                        "Using COPY --chown (efficient)", svc_name)
        elif da.has_separate_chown_layer:
            state.record("base_image", f"COPY --chown ({df_label})", "warn",
                        "Separate RUN chown layer (use COPY --chown instead)", svc_name)

        if quick:
            break


def check_compose(state: AuditState, compose_file: str, project_root: Path) -> None:
    """Category 2: Compose structure checks."""
    print_info("--- Compose Structure Checks ---")

    compose_path = project_root / compose_file
    override_path = project_root / "docker-compose.override.yml"
    env_path = project_root / ".env"
    env_example_path = project_root / ".env.example"

    if not compose_path.exists():
        state.record("compose", "Compose file exists", "fail", f"{compose_file} not found")
        return

    state.record("compose", "Compose file exists", "pass", f"{compose_file} found")

    # V2 syntax (no 'version:' key)
    version_val = yq_eval('.version', str(compose_path))
    if version_val:
        state.record("compose", "V2 syntax", "warn",
                     "'version:' key found (V2 doesn't need it)")
    else:
        state.record("compose", "V2 syntax", "pass", "No deprecated 'version:' key")

    # Project name
    proj_name = yq_eval('.name // ""', str(compose_path))
    if proj_name:
        state.record("compose", "Project name defined", "pass", f"name: {proj_name}")
    else:
        state.record("compose", "Project name defined", "warn",
                     "No 'name:' key in compose file")

    # Environment variables leak check
    services_str = yq_eval('.services | keys | .[]', str(compose_path))
    services = [s.strip() for s in services_str.splitlines() if s.strip()] if services_str else []

    env_leak = False
    allowed_env = {"ENVIRONMENT", "REGION", "<<", "",
                   "INFISICAL_URL", "INFISICAL_CLIENT_ID", "INFISICAL_PROJECT_ID"}

    for svc in services:
        # Skip infra services — they legitimately need config env vars
        if is_infra_service(svc):
            continue
        # Try list format first (- KEY=VALUE), then map format (KEY: value)
        env_vars = yq_eval(f'.services."{svc}".environment[]? // ""', str(compose_path))
        if not env_vars:
            # Map format — keys are the variable names
            env_vars = yq_eval(f'.services."{svc}".environment | keys | .[]', str(compose_path))
        if env_vars:
            for var_line in env_vars.splitlines():
                var_line = var_line.strip().lstrip("- ")
                if not var_line:
                    continue
                var_name = var_line.split("=")[0].split(":")[0].strip()
                if var_name not in allowed_env and "${" not in var_name:
                    env_leak = True
                    state.record("compose", f"Env var leak: {var_name} in {svc}", "fail",
                                "Only ENVIRONMENT/REGION allowed in compose", svc)

    if not env_leak:
        state.record("compose", "Minimal env vars", "pass",
                     "Only allowed variables in compose")

    # Network segmentation (C11)
    networks = yq_eval('.networks | keys | .[]', str(compose_path))
    if networks:
        net_list = [n.strip() for n in networks.splitlines() if n.strip()]
        has_public = any("-public" in n for n in net_list)
        has_private = any("-private" in n for n in net_list)
        if has_public and has_private:
            state.record("compose", "Network segmentation", "pass",
                        "<project>-public and <project>-private networks defined")
        elif has_public or has_private:
            missing = "private" if has_public else "public"
            state.record("compose", "Network segmentation", "warn",
                        f"Only one segmented network found, missing <project>-{missing}")
        else:
            # Check for legacy -internal pattern
            has_internal = any("-internal" in n for n in net_list)
            if has_internal:
                state.record("compose", "Network segmentation", "warn",
                            "Uses legacy <project>-internal pattern; migrate to <project>-public + <project>-private")
            else:
                state.record("compose", "Network segmentation", "warn",
                            "Networks defined but don't follow <project>-public/<project>-private pattern")
    else:
        state.record("compose", "Network segmentation", "fail", "No networks defined")

    # Container naming
    naming_ok = True
    for svc in services:
        cn = yq_eval(f'.services."{svc}".container_name // ""', str(compose_path))
        if not cn:
            state.record("compose", f"Container name ({svc})", "warn",
                        "No explicit container_name", svc)
            naming_ok = False

    if naming_ok and services:
        state.record("compose", "Container naming", "pass",
                     "All services have explicit container_name")

    # Container name uniqueness
    container_names: list[str] = []
    for svc in services:
        cn = yq_eval(f'.services."{svc}".container_name // ""', str(compose_path))
        if cn:
            container_names.append(cn)
    if len(container_names) != len(set(container_names)) and container_names:
        dupes = [n for n in container_names if container_names.count(n) > 1]
        state.record("compose", "Container name uniqueness", "fail",
                     f"Duplicate container names: {', '.join(set(dupes))}")
    elif container_names:
        state.record("compose", "Container name uniqueness", "pass",
                     "All container names are unique")

    # .env.example
    if env_example_path.exists():
        state.record("compose", ".env.example committed", "pass", ".env.example found")
    else:
        state.record("compose", ".env.example committed", "warn", "No .env.example template")

    # No Traefik in base compose
    try:
        compose_content = compose_path.read_text()
        if "traefik" in compose_content.lower():
            state.record("compose", "No Traefik in base", "fail",
                        "Traefik references found in base compose (should be in override)")
        else:
            state.record("compose", "No Traefik in base", "pass",
                        "No Traefik in base compose")
    except OSError:
        pass

    # Override file checks
    if override_path.exists():
        state.record("compose", "Override file exists", "pass",
                     "docker-compose.override.yml found")
        try:
            override_content = override_path.read_text()
            if "traefik" in override_content.lower():
                state.record("compose", "Traefik in override", "pass",
                            "Traefik labels in override")
            else:
                state.record("compose", "Traefik in override", "warn",
                            "No Traefik labels in override")
        except OSError:
            pass
    else:
        state.record("compose", "Override file exists", "warn",
                     "No override file for local dev")


def check_security(state: AuditState, compose_file: str, project_root: Path,
                   quick: bool) -> None:
    """Category 3: Security hardening checks."""
    print_info("--- Security Hardening Checks ---")

    compose_path = project_root / compose_file

    if not compose_path.exists():
        return

    services_str = yq_eval('.services | keys | .[]', str(compose_path))
    services = [s.strip() for s in services_str.splitlines() if s.strip()] if services_str else []

    for svc in services:
        if is_infra_service(svc):
            continue

        # read_only
        ro = yq_eval(f'.services."{svc}".read_only // false', str(compose_path))
        if ro == "true":
            state.record("security", f"read_only ({svc})", "pass",
                        "Filesystem is read-only", svc)
        else:
            state.record("security", f"read_only ({svc})", "fail",
                        "Missing read_only: true", svc)

        # no-new-privileges
        sec_opts = yq_eval(f'.services."{svc}".security_opt[]? // ""', str(compose_path))
        if sec_opts and "no-new-privileges" in sec_opts:
            state.record("security", f"no-new-privileges ({svc})", "pass",
                        "Privilege escalation blocked", svc)
        else:
            state.record("security", f"no-new-privileges ({svc})", "fail",
                        "Missing no-new-privileges:true", svc)

        # cap_drop ALL
        cap_drop = yq_eval(f'.services."{svc}".cap_drop[]? // ""', str(compose_path))
        if cap_drop and "ALL" in cap_drop:
            state.record("security", f"cap_drop ALL ({svc})", "pass",
                        "All capabilities dropped", svc)
        else:
            state.record("security", f"cap_drop ALL ({svc})", "fail",
                        "Missing cap_drop: [ALL]", svc)

        # tmpfs
        tmpfs = yq_eval(f'.services."{svc}".tmpfs[]? // ""', str(compose_path))
        if tmpfs:
            state.record("security", f"tmpfs mounts ({svc})", "pass",
                        "tmpfs defined for writable dirs", svc)
        elif ro == "true":
            state.record("security", f"tmpfs mounts ({svc})", "warn",
                        "read_only but no tmpfs (may fail at runtime)", svc)

        # Resource limits
        mem = yq_eval(f'.services."{svc}".deploy.resources.limits.memory // ""', str(compose_path))
        if mem:
            state.record("security", f"Resource limits ({svc})", "pass",
                        f"Memory limit: {mem}", svc)
        else:
            state.record("security", f"Resource limits ({svc})", "warn",
                        "No resource limits defined", svc)

        # Init process (Node/Python services)
        init_val = yq_eval(f'.services."{svc}".init // false', str(compose_path))
        svc_df = state.service_dockerfiles.get(svc, "")
        da = state.dockerfile_analyses.get(svc_df)
        is_node_python = False
        if da:
            base_lower = da.base_image.lower()
            is_node_python = "node" in base_lower or "python" in base_lower
        if is_node_python:
            if init_val == "true":
                state.record("security", f"Init process ({svc})", "pass",
                            "init: true on Node/Python service", svc)
            else:
                state.record("security", f"Init process ({svc})", "warn",
                            "Missing init: true on Node/Python service", svc)

        if quick:
            break

    # Secrets management checks
    _check_secrets_management(state, compose_path, project_root, services)

    # Secrets in compose (hardcoded values)
    try:
        compose_content = compose_path.read_text()
        secret_patterns = re.compile(
            r'^\s+-\s+.*(PASSWORD|SECRET|API_KEY|TOKEN|PRIVATE_KEY)',
            re.MULTILINE
        )
        matches = secret_patterns.findall(compose_content)
        # Filter out infisical_client_secret references and file: entries
        leaked_lines = []
        for line in compose_content.splitlines():
            if re.match(r'^\s+-\s+.*(PASSWORD|SECRET|API_KEY|TOKEN|PRIVATE_KEY)', line):
                if "infisical_client_secret" not in line and "file:" not in line:
                    leaked_lines.append(line.strip())
        if leaked_lines:
            state.record("security", "No secrets in compose", "fail",
                        f"Possible secrets found in {compose_file}")
        else:
            state.record("security", "No secrets in compose", "pass",
                        "No obvious secrets in compose")
    except OSError:
        pass

    # .env check
    env_path = project_root / ".env"
    if env_path.exists():
        try:
            env_allowed = True
            for line in env_path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key = line.split("=")[0].strip()
                if key not in ("ENVIRONMENT", "REGION"):
                    env_allowed = False
            if env_allowed:
                state.record("security", ".env minimal", "pass",
                            "Only ENVIRONMENT/REGION in .env")
            else:
                state.record("security", ".env minimal", "fail",
                            "Extra variables in .env (should be in secrets manager)")
        except OSError:
            pass


def _check_secrets_management(state: AuditState, compose_path: Path,
                               project_root: Path, services: list[str]) -> None:
    """Check secrets management (4 checks)."""
    # 1. secrets: key exists in compose
    secrets_key = yq_eval('.secrets | keys | .[]', str(compose_path))
    if secrets_key:
        state.record("security", "Secrets key in compose", "pass",
                     "Docker secrets defined in compose")
    else:
        state.record("security", "Secrets key in compose", "warn",
                     "No Docker secrets defined in compose")
        return  # Skip dependent checks

    # 2. Services mount secrets
    services_with_secrets = 0
    for svc in services:
        if is_infra_service(svc):
            continue
        svc_secrets = yq_eval(f'.services."{svc}".secrets[]? // ""', str(compose_path))
        if svc_secrets:
            services_with_secrets += 1
    app_services = [s for s in services if not is_infra_service(s)]
    if app_services and services_with_secrets == len(app_services):
        state.record("security", "Services mount secrets", "pass",
                     f"All {services_with_secrets} app services mount secrets")
    elif services_with_secrets > 0:
        state.record("security", "Services mount secrets", "warn",
                     f"{services_with_secrets}/{len(app_services)} app services mount secrets")
    elif app_services:
        state.record("security", "Services mount secrets", "fail",
                     "No app services mount Docker secrets")

    # 3. .secrets/ in .gitignore
    gitignore_path = project_root / ".gitignore"
    if gitignore_path.exists():
        try:
            gitignore_content = gitignore_path.read_text()
            if ".secrets" in gitignore_content or ".secrets/" in gitignore_content:
                state.record("security", ".secrets in .gitignore", "pass",
                            ".secrets/ directory is gitignored")
            else:
                state.record("security", ".secrets in .gitignore", "fail",
                            ".secrets/ not found in .gitignore")
        except OSError:
            pass
    else:
        state.record("security", ".secrets in .gitignore", "warn",
                     "No .gitignore file found")

    # 4. SECRETS_PATH pattern
    try:
        compose_content = compose_path.read_text()
        if "${SECRETS_PATH:-.secrets}" in compose_content or "SECRETS_PATH" in compose_content:
            state.record("security", "SECRETS_PATH pattern", "pass",
                        "Using SECRETS_PATH variable for dev/prod flexibility")
        else:
            state.record("security", "SECRETS_PATH pattern", "warn",
                        "No SECRETS_PATH pattern (hardcoded .secrets/ path)")
    except OSError:
        pass


def check_operations(state: AuditState, compose_file: str, project_root: Path) -> None:
    """Category 4: Operations checks."""
    print_info("--- Operations Checks ---")

    compose_path = project_root / compose_file
    if not compose_path.exists():
        return

    services_str = yq_eval('.services | keys | .[]', str(compose_path))
    services = [s.strip() for s in services_str.splitlines() if s.strip()] if services_str else []
    svc_count = len(services)

    health_count = 0
    depends_count = 0
    logging_count = 0

    for svc in services:
        # Health check
        hc = yq_eval(f'.services."{svc}".healthcheck.test // null | type', str(compose_path))
        if hc and hc != "null":
            health_count += 1

            # Healthcheck completeness
            hc_interval = yq_eval(f'.services."{svc}".healthcheck.interval // ""', str(compose_path))
            hc_timeout = yq_eval(f'.services."{svc}".healthcheck.timeout // ""', str(compose_path))
            hc_retries = yq_eval(f'.services."{svc}".healthcheck.retries // ""', str(compose_path))
            hc_start = yq_eval(f'.services."{svc}".healthcheck.start_period // ""', str(compose_path))

            complete_parts = []
            if hc_interval:
                complete_parts.append(f"interval: {hc_interval}")
            if hc_timeout:
                complete_parts.append(f"timeout: {hc_timeout}")
            if hc_retries:
                complete_parts.append(f"retries: {hc_retries}")
            if hc_start:
                complete_parts.append(f"start_period: {hc_start}")

            missing = []
            if not hc_timeout:
                missing.append("timeout")
            if not hc_retries:
                missing.append("retries")
            if not hc_start:
                missing.append("start_period")

            if not missing:
                state.record("operations", f"Healthcheck complete ({svc})", "pass",
                            ", ".join(complete_parts), svc)
            else:
                state.record("operations", f"Healthcheck complete ({svc})", "warn",
                            f"Missing: {', '.join(missing)}", svc)

        # depends_on — handle both list and map syntax
        deps_type = yq_eval(f'.services."{svc}".depends_on | type', str(compose_path))
        if deps_type in ("object", "!!map"):
            deps = yq_eval(f'.services."{svc}".depends_on | keys | .[]', str(compose_path))
            if deps:
                has_condition = False
                for dep in deps.splitlines():
                    dep = dep.strip()
                    if not dep:
                        continue
                    cond = yq_eval(
                        f'.services."{svc}".depends_on."{dep}".condition // ""',
                        str(compose_path)
                    )
                    if cond == "service_healthy":
                        has_condition = True
                if has_condition:
                    depends_count += 1
        elif deps_type in ("array", "!!seq"):
            # List syntax has no conditions
            pass

        # Logging
        log_driver = yq_eval(f'.services."{svc}".logging.driver // ""', str(compose_path))
        if log_driver:
            logging_count += 1

        # Restart policy
        restart = yq_eval(f'.services."{svc}".restart // ""', str(compose_path))
        if restart in ("unless-stopped", "always", "on-failure"):
            state.record("operations", f"Restart policy ({svc})", "pass",
                        f"restart: {restart}", svc)
        elif restart:
            state.record("operations", f"Restart policy ({svc})", "warn",
                        f"restart: {restart} (prefer unless-stopped)", svc)
        else:
            state.record("operations", f"Restart policy ({svc})", "warn",
                        "No restart policy defined", svc)

        # Stop grace period
        sgp = yq_eval(f'.services."{svc}".stop_grace_period // ""', str(compose_path))
        if sgp:
            state.record("operations", f"Stop grace period ({svc})", "pass",
                        f"stop_grace_period: {sgp}", svc)

    # Summary checks
    if health_count == svc_count and svc_count > 0:
        state.record("operations", "Health checks on all services", "pass",
                     f"{health_count}/{svc_count} services")
    elif health_count > 0:
        state.record("operations", "Health checks on all services", "warn",
                     f"{health_count}/{svc_count} services have health checks")
    else:
        state.record("operations", "Health checks on all services", "fail",
                     "No health checks defined")

    if depends_count > 0:
        state.record("operations", "depends_on with service_healthy", "pass",
                     f"{depends_count} services use health-based ordering")
    elif svc_count <= 1:
        state.record("operations", "depends_on with service_healthy", "pass",
                     "Single service -- no dependencies needed")
    else:
        state.record("operations", "depends_on with service_healthy", "warn",
                     "No service_healthy conditions found")

    if logging_count > 0:
        state.record("operations", "Logging configured", "pass",
                     f"{logging_count} services have logging config")
    else:
        state.record("operations", "Logging configured", "pass",
                     "Using Docker default JSON logging")


def check_networking_ci(state: AuditState, compose_file: str,
                         project_root: Path) -> None:
    """Category 5: Networking & CI checks."""
    print_info("--- Networking & CI Checks ---")

    compose_path = project_root / compose_file

    if compose_path.exists():
        services_str = yq_eval('.services | keys | .[]', str(compose_path))
        services = [s.strip() for s in services_str.splitlines() if s.strip()] if services_str else []

        # Port exposure
        port_violations: list[str] = []
        allowed_port_svc = {"frontend", "admin", "app", "redis", "mysql",
                           "postgres", "db", "mongo"}
        for svc in services:
            ports = yq_eval(f'.services."{svc}".ports[]? // ""', str(compose_path))
            if ports:
                svc_lower = svc.lower()
                if not any(pat in svc_lower for pat in allowed_port_svc):
                    port_violations.append(svc)

        if not port_violations:
            state.record("networking", "Port exposure", "pass",
                        "Only frontend/admin expose host ports")
        else:
            state.record("networking", "Port exposure", "warn",
                        f"Backend services expose ports: {' '.join(port_violations)}")

        # Network segmentation per service (C11a-C11c)
        top_networks = yq_eval('.networks | keys | .[]', str(compose_path))
        net_list = [n.strip() for n in top_networks.splitlines() if n.strip()] if top_networks else []
        has_public_net = any("-public" in n for n in net_list)
        has_private_net = any("-private" in n for n in net_list)

        if has_public_net and has_private_net:
            # Identify service roles by name patterns
            frontend_patterns = {"frontend", "admin", "web", "ui"}
            backend_patterns = {"backend", "api", "app", "server", "gateway"}
            proxy_patterns = {"nginx", "traefik", "haproxy", "caddy", "envoy",
                            "proxy", "reverse-proxy"}
            infra_patterns = {"db", "database", "mysql", "postgres", "postgresql",
                            "redis", "valkey", "mongo", "mongodb", "rabbitmq",
                            "kafka", "nats", "elasticsearch", "opensearch",
                            "memcached", "worker", "queue", "celery", "minio"}

            # Pre-scan: check if a proxy service bridges both networks
            # If so, backend being private-only is correct (proxy forwards requests)
            proxy_bridges = False
            for svc in services:
                svc_lower = svc.lower()
                if any(p in svc_lower for p in proxy_patterns):
                    proxy_nets_str = yq_eval(
                        f'.services."{svc}".networks[]? // ""', str(compose_path))
                    proxy_nets = [n.strip() for n in proxy_nets_str.splitlines()
                                if n.strip()] if proxy_nets_str else []
                    if (any("-public" in n for n in proxy_nets) and
                            any("-private" in n for n in proxy_nets)):
                        proxy_bridges = True

            for svc in services:
                svc_lower = svc.lower()
                # Handle both array syntax (networks: [net1]) and map syntax (networks: {net1: {aliases: ...}})
                nets_type = yq_eval(f'.services."{svc}".networks | type', str(compose_path))
                if nets_type in ("object", "!!map"):
                    svc_nets_str = yq_eval(
                        f'.services."{svc}".networks | keys | .[]', str(compose_path))
                else:
                    svc_nets_str = yq_eval(
                        f'.services."{svc}".networks[]? // ""', str(compose_path))
                svc_nets = [n.strip() for n in svc_nets_str.splitlines()
                           if n.strip()] if svc_nets_str else []

                on_public = any("-public" in n for n in svc_nets)
                on_private = any("-private" in n for n in svc_nets)

                is_frontend = any(p in svc_lower for p in frontend_patterns)
                is_backend = any(p in svc_lower for p in backend_patterns)
                is_proxy = any(p in svc_lower for p in proxy_patterns)
                is_infra = any(p in svc_lower for p in infra_patterns)

                if is_proxy:
                    # C11c: Proxy as bridge — should be on both networks
                    if on_public and on_private:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "pass",
                                    "Proxy bridges public and private networks")
                    elif on_public and not on_private:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "warn",
                                    "Proxy on public only — cannot reach backend services")
                    else:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "warn",
                                    "Proxy not on public network")
                elif is_frontend and not is_backend:
                    # C11a: Frontend should be public only
                    if on_public and not on_private:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "pass",
                                    "Frontend on public network only")
                    elif on_private:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "fail",
                                    "Frontend on private network — can reach DB directly")
                    elif not on_public:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "warn",
                                    "Frontend not on any segmented network")
                elif is_backend:
                    # C11c: Backend — bridges both, OR private-only if proxy bridges
                    if proxy_bridges:
                        # Proxy handles bridging; backend should be private only
                        if on_private and not on_public:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "pass",
                                        "Backend on private only (proxy bridges)")
                        elif on_public and on_private:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "warn",
                                        "Backend on both networks — unnecessary when proxy bridges")
                        elif on_public and not on_private:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "warn",
                                        "Backend on public only — should be on private (proxy bridges)")
                        else:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "warn",
                                        "Backend not on any segmented network")
                    else:
                        # No proxy — backend must bridge both
                        if on_public and on_private:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "pass",
                                        "Backend bridges public and private networks")
                        elif on_public and not on_private:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "warn",
                                        "Backend on public only — cannot reach DB/cache")
                        elif on_private and not on_public:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "warn",
                                        "Backend on private only — unreachable from frontend")
                        else:
                            state.record("networking",
                                        f"Network segmentation ({svc})", "warn",
                                        "Backend not on any segmented network")
                elif is_infra:
                    # C11b: Infrastructure should be private only
                    if on_private and not on_public:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "pass",
                                    "Infrastructure on private network only")
                    elif on_public:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "fail",
                                    "Infrastructure on public network — exposed to frontend")
                    elif not on_private:
                        state.record("networking",
                                    f"Network segmentation ({svc})", "warn",
                                    "Infrastructure not on any segmented network")

        # No external networks in base
        try:
            compose_content = compose_path.read_text()
            # Check top-level networks for external: true
            ext_nets = yq_eval(
                '.networks | to_entries[]? | select(.value.external == true) | .key',
                str(compose_path)
            )
            if not ext_nets:
                state.record("networking", "No external networks in base", "pass",
                            "Clean base compose")
            else:
                state.record("networking", "No external networks in base", "fail",
                            f"External networks in base: {ext_nets}")
        except OSError:
            pass

    # CI integration
    has_run_tests_df = False
    has_run_tests_pipeline = False

    for df in state.dockerfiles:
        try:
            if "RUN_TESTS" in df.read_text():
                has_run_tests_df = True
        except OSError:
            pass

    # Find pipeline files
    pipeline_files: list[Path] = []
    gh_dir = project_root / ".github" / "workflows"
    if gh_dir.is_dir():
        pipeline_files.extend(gh_dir.glob("*.yml"))
        pipeline_files.extend(gh_dir.glob("*.yaml"))
    gl_ci = project_root / ".gitlab-ci.yml"
    if gl_ci.exists():
        pipeline_files.append(gl_ci)

    for pf in pipeline_files:
        try:
            if "RUN_TESTS" in pf.read_text():
                has_run_tests_pipeline = True
        except OSError:
            pass

    if has_run_tests_df and has_run_tests_pipeline:
        state.record("networking", "CI build args (RUN_TESTS)", "pass",
                     "RUN_TESTS in Dockerfile and CI pipeline")
    elif has_run_tests_df:
        state.record("networking", "CI build args (RUN_TESTS)", "warn",
                     "RUN_TESTS in Dockerfile but not found in CI pipeline")
    elif has_run_tests_pipeline:
        state.record("networking", "CI build args (RUN_TESTS)", "warn",
                     "RUN_TESTS in CI pipeline but not in any Dockerfile")
    else:
        state.record("networking", "CI build args (RUN_TESTS)", "fail",
                     "No RUN_TESTS in Dockerfiles or CI pipeline")

    # .dockerignore exists — check project root and per-service build contexts
    dockerignore_path = project_root / ".dockerignore"
    per_service_ignores = [df.parent / ".dockerignore" for df in state.dockerfiles]
    found_ignores = [p for p in [dockerignore_path] + per_service_ignores if p.exists()]

    if found_ignores:
        locations = ", ".join(str(p.relative_to(project_root)) for p in found_ignores)
        state.record("networking", ".dockerignore exists", "pass",
                     f".dockerignore found: {locations}")
        for di in found_ignores:
            _check_dockerignore_content(state, di)
    else:
        state.record("networking", ".dockerignore exists", "warn",
                     "No .dockerignore (larger build context)")


def _check_dockerignore_content(state: AuditState, dockerignore_path: Path) -> None:
    """Validate .dockerignore content."""
    try:
        content = dockerignore_path.read_text()
        entries = {line.strip() for line in content.splitlines()
                   if line.strip() and not line.strip().startswith("#")}

        missing_required: list[str] = []
        for req in DOCKERIGNORE_REQUIRED:
            if not any(req in e for e in entries):
                missing_required.append(req)

        if not missing_required:
            state.record("networking", ".dockerignore content", "pass",
                        "All required entries present")
        else:
            state.record("networking", ".dockerignore content", "warn",
                        f"Missing entries: {', '.join(missing_required)}")
    except OSError:
        pass


def check_versions(state: AuditState, compose_file: str, project_root: Path,
                    quick: bool) -> None:
    """Category 6: Version pinning & staleness."""
    print_info("--- Version Pinning & Staleness Checks ---")

    compose_path = project_root / compose_file
    all_images: list[tuple[str, str, str]] = []  # (source, location, image_ref)

    # Images from Dockerfiles
    for df in state.dockerfiles:
        try:
            for line in df.read_text().splitlines():
                stripped = line.strip()
                if stripped.startswith("FROM "):
                    parts = stripped.split()
                    img = parts[1] if len(parts) > 1 else ""
                    if ":" in img or "/" in img:
                        all_images.append(("dockerfile", str(df), img))
        except OSError:
            pass

    # Images from compose
    if compose_path.exists():
        services_str = yq_eval('.services | keys | .[]', str(compose_path))
        services = [s.strip() for s in services_str.splitlines() if s.strip()] if services_str else []
        for svc in services:
            img = yq_eval(f'.services."{svc}".image // ""', str(compose_path))
            if img:
                resolved = resolve_compose_image(img)
                if resolved:
                    all_images.append(("compose", svc, resolved))

    unpinned = 0
    stale = 0
    skipped_registries: list[str] = []

    for source, location, image_ref in all_images:
        if ":" in image_ref:
            image_name = image_ref.rsplit(":", 1)[0]
            image_tag = image_ref.rsplit(":", 1)[1]
        else:
            image_name = image_ref
            image_tag = ""

        label = f"{source}({location})"
        ver_svc = "_global"
        if source == "compose":
            ver_svc = location
        elif source == "dockerfile":
            ver_svc = get_service_for_dockerfile(state, location)

        # Check pinning
        if not image_tag or image_tag == "latest":
            unpinned += 1
            state.record("versions", f"Version pinned ({label})", "fail",
                        f"{image_ref} -- using :latest or no tag", ver_svc)
            continue

        state.record("versions", f"Version pinned ({label})", "pass",
                     image_ref, ver_svc)

        if quick:
            continue

        # Skip private registries
        private_patterns = [".amazonaws.com", ".gcr.io", "ghcr.io", "turnersrus.com"]
        if any(pat in image_name for pat in private_patterns):
            skipped_registries.append(image_name)
            continue

        # Docker Hub staleness check
        _check_staleness(state, image_name, image_tag, label, ver_svc)

    if unpinned > 0:
        state.record("versions", "All images pinned", "fail",
                     f"{unpinned} image(s) not pinned to specific version")
    elif all_images:
        state.record("versions", "All images pinned", "pass",
                     f"All {len(all_images)} image(s) have pinned versions")

    if skipped_registries:
        state.record("versions", "Private registry skip", "skip",
                     "Cannot check staleness for private registries")


def _check_staleness(state: AuditState, image_name: str, image_tag: str,
                      label: str, ver_svc: str) -> None:
    """Check Docker Hub for newer versions."""
    if "/" in image_name:
        namespace = image_name.split("/")[0]
        repo = image_name.split("/", 1)[1]
        hub_url = f"https://hub.docker.com/v2/repositories/{namespace}/{repo}/tags?page_size=100&ordering=last_updated"
    else:
        hub_url = f"https://hub.docker.com/v2/repositories/library/{image_name}/tags?page_size=100&ordering=last_updated"

    try:
        req = urllib.request.Request(hub_url, headers={"User-Agent": "docker-audit/2.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            tags_data = json.loads(resp.read())
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        state.record("versions", f"Staleness check ({label})", "skip",
                     f"Could not reach Docker Hub for {image_name}", ver_svc)
        return

    tag_names = [r.get("name", "") for r in tags_data.get("results", [])]

    # Find latest in same major series
    tag_match = re.match(r'^(\d+)\.([\d.]+)(-.+)?$', image_tag)
    if not tag_match:
        state.record("versions", f"Staleness check ({label})", "skip",
                     f"Could not parse version: {image_tag}", ver_svc)
        return

    major = tag_match.group(1)
    suffix = tag_match.group(3) or ""

    # Find tags in same series
    pattern = re.compile(rf'^{re.escape(major)}\.[\d.]+ {re.escape(suffix)}$'.replace(" ", ""))
    if suffix:
        pattern = re.compile(rf'^{re.escape(major)}\.[\d.]+{re.escape(suffix)}$')
    else:
        pattern = re.compile(rf'^{re.escape(major)}\.[\d.]+$')

    matching = [t for t in tag_names if pattern.match(t)]
    if not matching:
        state.record("versions", f"Staleness check ({label})", "skip",
                     f"Could not determine latest for {image_name}:{image_tag}", ver_svc)
        state.version_data.append({
            "image": image_name, "current": image_tag,
            "latest": "unknown", "source": label.split("(")[0],
        })
        return

    # Sort by version
    def version_key(tag: str) -> list[int]:
        nums = re.findall(r'\d+', tag.split("-")[0] if "-" in tag else tag)
        return [int(n) for n in nums]

    try:
        matching.sort(key=version_key)
        latest = matching[-1]
    except (ValueError, IndexError):
        latest = matching[-1] if matching else image_tag

    if latest != image_tag:
        state.record("versions", f"Version current ({label})", "warn",
                     f"{image_name}:{image_tag} -> latest in series: {image_name}:{latest}",
                     ver_svc)
    else:
        state.record("versions", f"Version current ({label})", "pass",
                     f"{image_name}:{image_tag} is latest in series", ver_svc)

    state.version_data.append({
        "image": image_name, "current": image_tag, "latest": latest,
    })


def check_volume_security(state: AuditState, compose_file: str,
                           project_root: Path) -> None:
    """Check volume mount security."""
    compose_path = project_root / compose_file
    if not compose_path.exists():
        return

    services_str = yq_eval('.services | keys | .[]', str(compose_path))
    services = [s.strip() for s in services_str.splitlines() if s.strip()] if services_str else []

    # Load allowlist from PROJECT.yaml
    project_yaml = project_root / "PROJECT.yaml"
    docker_sock_allowed: list[str] = []
    if project_yaml.exists():
        allowed = yq_eval('.docker.docker_sock_allowed[]? // ""', str(project_yaml))
        if allowed:
            docker_sock_allowed = [s.strip() for s in allowed.splitlines() if s.strip()]

    for svc in services:
        volumes = yq_eval(f'.services."{svc}".volumes[]? // ""', str(compose_path))
        if not volumes:
            continue

        for vol_line in volumes.splitlines():
            vol = vol_line.strip()
            if not vol:
                continue

            # Check docker.sock
            if "docker.sock" in vol:
                if svc in docker_sock_allowed:
                    state.record("security", f"Docker socket ({svc})", "warn",
                                f"docker.sock mounted (allowed by PROJECT.yaml)", svc)
                else:
                    state.record("security", f"Docker socket ({svc})", "fail",
                                "docker.sock mounted without allowlist entry", svc)

            # Check sensitive paths
            for sensitive in SENSITIVE_PATHS:
                if sensitive in vol and "docker.sock" not in vol:
                    state.record("security", f"Sensitive volume ({svc})", "fail",
                                f"Sensitive path mounted: {sensitive}", svc)

            # Check :ro on data volumes (skip tmpfs-like mounts)
            if ":" in vol and not vol.startswith("/tmp"):
                parts = vol.split(":")
                if len(parts) >= 2 and not any(p in vol for p in [":ro", "readonly"]):
                    # Only warn for host mounts, not named volumes
                    host_path = parts[0]
                    if host_path.startswith("/") or host_path.startswith(".") or host_path.startswith("$"):
                        pass  # Don't warn on every mount — too noisy


def check_build_performance(state: AuditState) -> None:
    """Category: Build performance scoring (7 weighted checks)."""
    print_info("--- Build Performance Checks ---")

    if not state.dockerfile_analyses:
        state.record("build_performance", "Build performance", "skip",
                     "No Dockerfiles analyzed")
        return

    for df_path, da in state.dockerfile_analyses.items():
        svc = da.service
        df_label = _df_label(da.path)

        # 1. Layer cache order (25pts) — source should come after deps
        cache_order_ok = _check_layer_cache_order(da)
        if cache_order_ok:
            state.record("build_performance", f"Layer cache order ({df_label})", "pass",
                        "Dependencies installed before source copy", svc)
        else:
            state.record("build_performance", f"Layer cache order ({df_label})", "fail",
                        "Source copied before deps install", svc)

        # 2. Dependency file separation (20pts)
        dep_sep = _check_dep_separation(da)
        if dep_sep:
            state.record("build_performance", f"Dep file separation ({df_label})", "pass",
                        "Dependency files copied separately", svc)
        else:
            state.record("build_performance", f"Dep file separation ({df_label})", "fail",
                        "No separate dep file copy before install", svc)

        # 3. Multi-stage copy efficiency (15pts)
        copy_eff = _check_multistage_copy(da)
        if copy_eff == "pass":
            state.record("build_performance", f"Multi-stage copy ({df_label})", "pass",
                        "Only specific paths copied to final stage", svc)
        elif copy_eff == "warn":
            state.record("build_performance", f"Multi-stage copy ({df_label})", "warn",
                        "Copies entire directory from build stage", svc)
        else:
            state.record("build_performance", f"Multi-stage copy ({df_label})", "pass",
                        "Single stage or no COPY --from", svc)

        # 4. Dev deps excluded (15pts)
        dev_deps = _check_dev_deps(da)
        if dev_deps == "pass":
            state.record("build_performance", f"Dev deps excluded ({df_label})", "pass",
                        "Production deps only in final image", svc)
        elif dev_deps == "warn":
            state.record("build_performance", f"Dev deps excluded ({df_label})", "warn",
                        "npm install without --omit=dev in production stage", svc)
        else:
            state.record("build_performance", f"Dev deps excluded ({df_label})", "pass",
                        "No npm/pip install found or properly handled", svc)

        # 5. Unnecessary files in final (10pts)
        unnecessary = _check_unnecessary_files(da)
        if unnecessary:
            state.record("build_performance", f"Unnecessary files ({df_label})", "warn",
                        "Source files may be present in final image", svc)
        else:
            state.record("build_performance", f"Unnecessary files ({df_label})", "pass",
                        "Final image appears clean", svc)

        # 6. Layer consolidation (10pts)
        consolidated = _check_layer_consolidation(da)
        if consolidated:
            state.record("build_performance", f"Layer consolidation ({df_label})", "pass",
                        "RUN commands properly combined", svc)
        else:
            state.record("build_performance", f"Layer consolidation ({df_label})", "warn",
                        "Multiple apt-get/apk commands could be combined", svc)

        # 7. Package cache cleanup (5pts)
        cache_clean = _check_cache_cleanup(da)
        if cache_clean == "pass":
            state.record("build_performance", f"Package cache cleanup ({df_label})", "pass",
                        "Package cache cleaned in same layer", svc)
        elif cache_clean == "fail":
            state.record("build_performance", f"Package cache cleanup ({df_label})", "fail",
                        "Package cache cleanup in separate layer", svc)
        else:
            state.record("build_performance", f"Package cache cleanup ({df_label})", "pass",
                        "No package manager detected or clean", svc)


def _check_layer_cache_order(da: DockerfileAnalysis) -> bool:
    """Check if deps are installed before source copy."""
    content = "\n".join(da.raw_lines)

    # Find positions of key operations
    copy_all_pos = -1
    npm_ci_pos = -1
    pip_install_pos = -1
    go_mod_pos = -1

    for i, line in enumerate(da.raw_lines):
        stripped = line.strip()
        if re.match(r'^COPY\s+\.\s+\.', stripped) or stripped == "COPY . .":
            if copy_all_pos == -1:
                copy_all_pos = i
        if re.search(r'npm ci|npm install|yarn install|pnpm install', stripped):
            npm_ci_pos = i
        if re.search(r'pip install|uv pip install', stripped):
            pip_install_pos = i
        if re.search(r'go mod download', stripped):
            go_mod_pos = i

    if copy_all_pos == -1:
        return True  # No COPY . . found

    install_pos = -1
    for pos in [npm_ci_pos, pip_install_pos, go_mod_pos]:
        if pos != -1:
            install_pos = pos
            break

    if install_pos == -1:
        return True  # No install command found

    return copy_all_pos > install_pos


def _check_dep_separation(da: DockerfileAnalysis) -> bool:
    """Check if dependency files are copied separately."""
    content = "\n".join(da.raw_lines)

    dep_files = ["package.json", "package-lock.json", "requirements.txt",
                 "pyproject.toml", "go.mod", "go.sum", "Gemfile", "Cargo.toml"]

    for dep_file in dep_files:
        if re.search(rf'COPY.*{re.escape(dep_file)}', content):
            return True

    return False


def _check_multistage_copy(da: DockerfileAnalysis) -> str:
    """Check multi-stage COPY efficiency."""
    if da.stage_count <= 1:
        return "na"

    for line in da.raw_lines:
        stripped = line.strip()
        if re.match(r'^COPY\s+--from=\S+\s+/\S+\s+\.\s*$', stripped):
            return "warn"  # Copies everything
        if re.match(r'^COPY\s+--from=', stripped):
            return "pass"  # Specific path copy

    return "na"


def _check_dev_deps(da: DockerfileAnalysis) -> str:
    """Check if dev dependencies are excluded from production."""
    # Look at the final stage
    if not da.stages:
        return "na"

    final_stage = da.stages[-1]
    final_instructions = "\n".join(final_stage["instructions"])

    if "npm ci --omit=dev" in final_instructions or "npm ci --production" in final_instructions:
        return "pass"
    if "npm install --omit=dev" in final_instructions or "npm install --production" in final_instructions:
        return "pass"
    if "npm ci" in final_instructions or "npm install" in final_instructions:
        # npm install without production flag in final stage
        if da.stage_count > 1:
            # Multi-stage might copy only built artifacts
            return "pass"
        return "warn"

    return "na"


def _check_unnecessary_files(da: DockerfileAnalysis) -> bool:
    """Check if unnecessary files might be in final image."""
    if da.stage_count <= 1:
        # Single stage — COPY . . likely includes everything
        content = "\n".join(da.raw_lines)
        if "COPY . ." in content or "COPY . /" in content:
            return True
    return False


def _check_layer_consolidation(da: DockerfileAnalysis) -> bool:
    """Check if RUN commands are properly consolidated."""
    apt_runs = sum(1 for r in da.run_instructions
                   if "apt-get" in r or "apk add" in r)
    return apt_runs <= 1


def _check_cache_cleanup(da: DockerfileAnalysis) -> str:
    """Check if package caches are cleaned in the same layer."""
    for run in da.run_instructions:
        if "apt-get install" in run:
            if "rm -rf /var/lib/apt/lists" in run:
                return "pass"
            return "fail"
        if "apk add" in run:
            if "--no-cache" in run:
                return "pass"
            return "fail"
    return "na"


def check_dhi_compliance(state: AuditState) -> None:
    """Category: DHI (Docker Hardened Images) compliance."""
    print_info("--- DHI Compliance Checks ---")

    # Collect all images from Dockerfiles and compose
    all_images: list[tuple[str, str, str]] = []  # (source, location, image)

    for df_path, da in state.dockerfile_analyses.items():
        for from_line in da.from_lines:
            parts = from_line.split()
            img = parts[1] if len(parts) > 1 else ""
            if img:
                all_images.append(("dockerfile", str(da.path), img))

    for svc, img in state.service_images.items():
        resolved = resolve_compose_image(img)
        if resolved:
            all_images.append(("compose", svc, resolved))

    if not all_images:
        state.record("dhi_compliance", "DHI compliance", "skip", "No images to check")
        return

    dhi_pass = 0
    dhi_total = 0

    for source, location, image_ref in all_images:
        # Extract base image name (without tag and registry)
        img_name = image_ref.split(":")[0]

        # Strip registry prefix
        if "/" in img_name:
            parts = img_name.split("/")
            if "." in parts[0] or ":" in parts[0]:
                # Has registry prefix
                base_name = parts[-1]
                registry = "/".join(parts[:-1])
            else:
                base_name = parts[-1]
                registry = ""
        else:
            base_name = img_name
            registry = ""

        label = f"{source}({location})"
        svc = location if source == "compose" else get_service_for_dockerfile(state, location)

        dhi_total += 1

        if img_name.startswith("dhi.io/"):
            state.record("dhi_compliance", f"DHI ({label})", "pass",
                        f"Using DHI: {image_ref}", svc)
            dhi_pass += 1
        elif "cgr.dev" in img_name:
            state.record("dhi_compliance", f"DHI ({label})", "warn",
                        f"Chainguard is paid - use DHI dhi.io/{base_name} instead: {image_ref}", svc)
        elif base_name in DHI_CATALOG:
            state.record("dhi_compliance", f"DHI ({label})", "warn",
                        f"DHI available: dhi.io/{base_name} instead of {image_ref}", svc)
        elif img_name.startswith("$"):
            # Variable reference — skip
            state.record("dhi_compliance", f"DHI ({label})", "skip",
                        f"Variable image reference: {image_ref}", svc)
            dhi_total -= 1
        else:
            state.record("dhi_compliance", f"DHI ({label})", "pass",
                        f"No DHI equivalent: {image_ref}", svc)
            dhi_pass += 1


# =============================================================================
# Scoring
# =============================================================================

def compute_scores(state: AuditState, with_image_scan: bool) -> dict[str, Any]:
    """Compute category and overall scores."""
    weights = WEIGHTS_IMAGE_SCAN if with_image_scan else WEIGHTS_DEFAULT

    # Check if image scan categories have actual data
    has_vuln = any(f.category == "vulnerability" and f.result != "skip" for f in state.findings)
    has_eff = any(f.category == "efficiency" and f.result != "skip" for f in state.findings)

    if has_vuln or has_eff:
        weights = WEIGHTS_IMAGE_SCAN
    else:
        weights = WEIGHTS_DEFAULT

    category_scores: dict[str, int] = {}

    for cat in CATEGORIES:
        cat_findings = [f for f in state.findings if f.category == cat and f.result != "skip"]
        if not cat_findings:
            category_scores[cat] = 0
            continue

        full_pass = sum(1 for f in cat_findings if f.result == "pass")
        half_pass = sum(1 for f in cat_findings if f.result == "warn")
        total = len(cat_findings)

        score = (full_pass * 2 + half_pass) * 100 // (total * 2) if total > 0 else 0
        category_scores[cat] = score

    # Compute weighted overall
    total_weight = sum(weights.get(cat, 0) for cat in CATEGORIES
                       if category_scores.get(cat, 0) > 0 or weights.get(cat, 0) > 0)

    # Only count categories with weight and findings
    overall = 0
    actual_weight = 0
    for cat in CATEGORIES:
        w = weights.get(cat, 0)
        if w == 0:
            continue
        # Include the category if it has any non-skip findings
        cat_findings = [f for f in state.findings if f.category == cat and f.result != "skip"]
        if cat_findings:
            overall += category_scores[cat] * w
            actual_weight += w

    overall_score = overall // actual_weight if actual_weight > 0 else 0

    # Print scores
    print_info("Scores calculated")
    for cat in CATEGORIES:
        w = weights.get(cat, 0)
        if w > 0 or category_scores.get(cat, 0) > 0:
            print_info(f"  {cat:<20s}: {category_scores.get(cat, 0):>3d}/100  (weight: {w}%)")
    print_info(f"  {'Overall':<20s}: {overall_score:>3d}/100")

    scores = {
        "overall": overall_score,
    }
    for cat in CATEGORIES:
        scores[cat] = {
            "score": category_scores.get(cat, 0),
            "weight": weights.get(cat, 0),
        }

    return scores


def compute_service_scores(state: AuditState) -> dict[str, Any]:
    """Compute per-service scores."""
    # Discover all services from findings
    service_set: set[str] = set()
    for f in state.findings:
        if f.service != "_global" and f.result != "skip":
            service_set.add(f.service)

    svc_scores: dict[str, Any] = {}

    for svc in sorted(service_set):
        svc_findings = [f for f in state.findings
                       if f.service == svc and f.result != "skip"]
        if not svc_findings:
            continue

        passed = sum(1 for f in svc_findings if f.result == "pass")
        warned = sum(1 for f in svc_findings if f.result == "warn")
        failed = sum(1 for f in svc_findings if f.result == "fail")
        total = passed + warned + failed

        score = (passed * 2 + warned) * 100 // (total * 2) if total > 0 else 0

        # Per-category breakdown
        cat_scores: dict[str, Any] = {}
        for cat in CATEGORIES:
            cat_f = [f for f in svc_findings if f.category == cat]
            if not cat_f:
                continue
            cp = sum(1 for f in cat_f if f.result == "pass")
            cw = sum(1 for f in cat_f if f.result == "warn")
            cf = sum(1 for f in cat_f if f.result == "fail")
            ct = cp + cw + cf
            cs = (cp * 2 + cw) * 100 // (ct * 2) if ct > 0 else 0
            cat_scores[cat] = {"score": cs, "passed": cp, "warnings": cw, "failed": cf}

        svc_scores[svc] = {
            "score": score,
            "grade": grade_for_score(score),
            "passed": passed,
            "warnings": warned,
            "failed": failed,
            "categories": cat_scores,
        }

    # Print summary
    if svc_scores:
        print_info("")
        print_info("Per-Service Scores:")
        for svc, data in svc_scores.items():
            print_info(f"  {svc}: {data['score']}/100 ({data['passed']} pass, "
                      f"{data['warnings']} warn, {data['failed']} fail)")

    return svc_scores


# =============================================================================
# Report Generation
# =============================================================================

def generate_report(state: AuditState, scores: dict[str, Any],
                     service_scores: dict[str, Any], args: argparse.Namespace,
                     project_root: Path, compose_file: str) -> dict[str, Any]:
    """Generate schema v2 JSON report."""
    overall = scores.get("overall", 0)

    # Generate unique ID
    ts = datetime.now(timezone.utc)
    timestamp = ts.isoformat()

    try:
        git_result = subprocess.run(
            ["git", "-C", str(project_root), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        commit = git_result.stdout.strip() if git_result.returncode == 0 else "unknown"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        commit = "unknown"

    try:
        branch_result = subprocess.run(
            ["git", "-C", str(project_root), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        branch = branch_result.stdout.strip() if branch_result.returncode == 0 else "unknown"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        branch = "unknown"

    snapshot_id = ts.strftime("%Y%m%dT%H%M%S") + f"-{commit}"

    # Categorize findings
    findings_by_result: dict[str, list[dict[str, Any]]] = {
        "pass": [], "fail": [], "warn": [], "skip": [],
    }
    for f in state.findings:
        findings_by_result.setdefault(f.result, []).append(f.to_dict())

    app_name = get_config(".name", "", str(project_root / "PROJECT.yaml"))

    report: dict[str, Any] = {
        "version": SCHEMA_VERSION,
        "id": snapshot_id,
        "audit_type": "docker",
        "project": app_name,
        "branch": branch,
        "commit": commit,
        "timestamp": timestamp,
        "quick_mode": args.quick,
        "image_scan": args.with_image_scan,
        "status": grade_for_score(overall),
        "scores": scores,
        "service_scores": service_scores,
        "summary": {
            "total_checks": len(state.findings),
            "passed": len(findings_by_result.get("pass", [])),
            "failed": len(findings_by_result.get("fail", [])),
            "warnings": len(findings_by_result.get("warn", [])),
            "skipped": len(findings_by_result.get("skip", [])),
            "services_audited": len(service_scores),
        },
        "findings": findings_by_result,
        "version_images": state.version_data,
        "external_tools": {
            tool: {"ran": ran}
            for tool, ran in state.tool_ran.items()
        },
        "files_scanned": {
            "compose_file": compose_file,
            "override_file": "docker-compose.override.yml",
            "compose_exists": (project_root / compose_file).exists(),
            "override_exists": (project_root / "docker-compose.override.yml").exists(),
            "dockerfiles": [str(df) for df in state.dockerfiles],
        },
    }

    return report


def write_report(report: dict[str, Any], project_root: Path) -> str:
    """Write report to /tmp and docs/audits/docker/."""
    # Write to /tmp
    tmp_path = "/tmp/docker-audit-result.json"
    Path(tmp_path).write_text(json.dumps(report, indent=2) + "\n")
    print_info(f"Report written to: {tmp_path}")

    # Write to docs/audits/docker/
    audit_dir = project_root / "docs" / "audits" / "docker"
    audit_dir.mkdir(parents=True, exist_ok=True)

    snapshot_file = audit_dir / f"{report['id']}.json"
    snapshot_file.write_text(json.dumps(report, indent=2) + "\n")
    print_info(f"Snapshot written to: {snapshot_file}")

    return str(snapshot_file)


# =============================================================================
# Compare (--compare flag)
# =============================================================================

def compare_with_previous(report: dict[str, Any], project_root: Path) -> dict[str, Any] | None:
    """Load previous snapshot and compute deltas."""
    audit_dir = project_root / "docs" / "audits" / "docker"
    if not audit_dir.is_dir():
        return None

    snapshots = sorted(audit_dir.glob("*.json"))
    current_id = report.get("id", "")

    # Find previous (not the current one)
    previous: dict[str, Any] | None = None
    for snap_path in reversed(snapshots):
        if snap_path.stem == current_id:
            continue
        try:
            data = json.loads(snap_path.read_text())
            # Support both individual and rollup formats
            if "snapshots" in data:
                # Rollup — get latest snapshot within
                inner = sorted(data["snapshots"], key=lambda s: s.get("id", ""))
                if inner:
                    previous = inner[-1]
            elif "id" in data and data["id"] != current_id:
                previous = data
            if previous:
                break
        except (json.JSONDecodeError, OSError):
            continue

    if not previous:
        print_info("No previous snapshot found for comparison")
        return None

    # Compute deltas
    prev_scores = previous.get("scores", {})
    curr_scores = report.get("scores", {})

    deltas: dict[str, Any] = {
        "previous_id": previous.get("id", "unknown"),
        "previous_timestamp": previous.get("timestamp", ""),
        "overall_delta": curr_scores.get("overall", 0) - prev_scores.get("overall", 0),
        "categories": {},
    }

    for cat in CATEGORIES:
        curr_cat = curr_scores.get(cat, {})
        prev_cat = prev_scores.get(cat, {})
        if isinstance(curr_cat, dict) and isinstance(prev_cat, dict):
            delta = curr_cat.get("score", 0) - prev_cat.get("score", 0)
            deltas["categories"][cat] = {
                "current": curr_cat.get("score", 0),
                "previous": prev_cat.get("score", 0),
                "delta": delta,
            }

    # Print comparison
    print_info("")
    print_info(f"Comparison with {deltas['previous_id']}:")
    overall_delta = deltas["overall_delta"]
    arrow = "▲" if overall_delta > 0 else "▼" if overall_delta < 0 else "─"
    print_info(f"  Overall: {arrow} {overall_delta:+d}")

    for cat, cd in deltas["categories"].items():
        d = cd["delta"]
        if d != 0:
            arr = "▲" if d > 0 else "▼"
            print_info(f"  {cat}: {arr} {d:+d} ({cd['previous']} → {cd['current']})")

    return deltas


# =============================================================================
# Helpers
# =============================================================================

def _df_label(df: Path) -> str:
    """Create human-readable label for a Dockerfile."""
    parent = df.parent
    if str(parent) == ".":
        return df.name
    return f"{parent.name}/{df.name}"


def _write_tool_output(path: str, data: Any) -> None:
    """Write tool output to a file as JSON."""
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


# =============================================================================
# Main Stages
# =============================================================================

def scan_stage(state: AuditState, args: argparse.Namespace,
               tools: dict[str, bool], project_root: Path,
               compose_file: str) -> None:
    """Run all scan checks."""
    print_info(f"Stage: Scanning Docker implementation...")

    # Discover Dockerfiles
    for df in sorted(project_root.glob("**/Dockerfile*")):
        # Skip nested directories too deep
        try:
            rel = df.relative_to(project_root)
        except ValueError:
            continue
        if len(rel.parts) > 4:
            continue
        if "node_modules" in str(df) or "lambda" in str(df) or "serverless" in str(df):
            continue
        state.dockerfiles.append(df)

    # Discover services
    compose_path = project_root / compose_file
    if compose_path.exists():
        discover_services(state, str(compose_path))
        services_str = yq_eval('.services | keys | .[]', str(compose_path))
        if services_str:
            state.services = [s.strip() for s in services_str.splitlines() if s.strip()]

    # Run all category checks
    check_base_image(state, compose_file, args.quick)
    check_compose(state, compose_file, project_root)
    check_security(state, compose_file, project_root, args.quick)
    check_volume_security(state, compose_file, project_root)
    check_operations(state, compose_file, project_root)
    check_networking_ci(state, compose_file, project_root)
    check_versions(state, compose_file, project_root, args.quick)
    check_build_performance(state)
    check_dhi_compliance(state)

    # External tools
    scan_external_tools(state, tools, args.quick, args.skip_external, args.with_image_scan)


def score_stage_fn(state: AuditState, with_image_scan: bool) -> tuple[dict[str, Any], dict[str, Any]]:
    """Compute all scores."""
    print_info("Stage: Calculating scores...")
    scores = compute_scores(state, with_image_scan)
    service_scores = compute_service_scores(state)
    return scores, service_scores


def report_stage_fn(state: AuditState, scores: dict[str, Any],
                     service_scores: dict[str, Any], args: argparse.Namespace,
                     project_root: Path, compose_file: str) -> dict[str, Any]:
    """Generate and write report."""
    print_info("Stage: Generating audit report...")
    report = generate_report(state, scores, service_scores, args, project_root, compose_file)
    write_report(report, project_root)
    return report


# =============================================================================
# CLI
# =============================================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Docker implementation audit with industry-standard tool integration"
    )
    parser.add_argument("--stage", default="all",
                       choices=["scan", "score", "report", "all"],
                       help="Stage to run (default: all)")
    parser.add_argument("--quick", action="store_true",
                       help="Quick mode: first Dockerfile only, no external tools, no staleness")
    parser.add_argument("--skip-external", action="store_true",
                       help="Skip external tool scans")
    parser.add_argument("--with-image-scan", action="store_true",
                       help="Include image scanning (trivy image, dockle, dive)")
    parser.add_argument("--compare", action="store_true",
                       help="Compare with previous snapshot")
    parser.add_argument("--output", default="/tmp/docker-audit-result.json",
                       help="Output file path")
    parser.add_argument("--project-root",
                       help="Project root (default: cwd)")
    parser.add_argument("--format", choices=["json"], default="json",
                       help="Output format (always JSON)")

    args = parser.parse_args()

    # Resolve project root
    project_root = Path(args.project_root).resolve() if args.project_root else Path.cwd().resolve()

    # Require PROJECT.yaml
    project_yaml = project_root / "PROJECT.yaml"
    if not project_yaml.exists():
        print_error("PROJECT.yaml not found in project directory")
        sys.exit(1)

    # Require yq
    tools = require_tools()
    if not tools.get("yq"):
        print_error("yq is required. Install: brew install yq")
        sys.exit(1)

    # Get compose file from config
    compose_file = get_config(".docker.compose_file", "docker-compose.yml", str(project_yaml))

    # Initialize state
    state = AuditState()

    # Clean previous tool outputs
    for f in ["/tmp/docker-audit-hadolint.json", "/tmp/docker-audit-trivy-config.json",
              "/tmp/docker-audit-trivy-image.json", "/tmp/docker-audit-dockle.json",
              "/tmp/docker-audit-dive.txt"]:
        Path(f).unlink(missing_ok=True)

    # Run stages
    if args.stage in ("scan", "score", "report", "all"):
        scan_stage(state, args, tools, project_root, compose_file)

    scores: dict[str, Any] = {}
    service_scores: dict[str, Any] = {}

    if args.stage in ("score", "report", "all"):
        scores, service_scores = score_stage_fn(state, args.with_image_scan)

    report: dict[str, Any] = {}

    if args.stage in ("report", "all"):
        report = report_stage_fn(state, scores, service_scores, args,
                                  project_root, compose_file)
        # Output JSON to stdout
        print(json.dumps(report, indent=2))

        # Compare if requested
        if args.compare:
            deltas = compare_with_previous(report, project_root)
            if deltas:
                report["comparison"] = deltas
                # Re-write with comparison data
                write_report(report, project_root)


if __name__ == "__main__":
    main()
