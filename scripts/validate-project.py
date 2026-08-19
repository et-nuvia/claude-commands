#!/usr/bin/env -S uv run --with pyyaml --with 'jsonschema[format]' --quiet --python 3.12 python
"""
validate-project.py - Schema-driven PROJECT.yaml validation

Validates PROJECT.yaml against a JSON Schema (source of truth) and performs
optional runtime checks (file existence, token files, git state).

Usage:
    uv run ~/.claude/scripts/validate-project.py [options]

Options:
    --file PATH       Path to PROJECT.yaml (default: ./PROJECT.yaml)
    --json            Structured JSON output (default)
    --human           Colored human-readable output
    --strict          Treat warnings as errors
    --schema-only     Skip runtime checks (file/token existence)
    --quiet           Suppress info-level messages

Exit Codes:
    0 - Valid (no errors)
    1 - Invalid (has errors)
    2 - File not found or YAML parse error
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator
from jsonschema import ValidationError

SCHEMA_VERSION = "1.0.0"
SCHEMA_PATH = Path.home() / ".claude" / "schemas" / "project.schema.json"

# Map jsonschema validator names to human-friendly error codes
VALIDATOR_CODE_MAP = {
    "required": "REQUIRED_FIELD",
    "type": "INVALID_TYPE",
    "enum": "INVALID_ENUM",
    "additionalProperties": "ADDITIONAL_PROPERTY",
    "minimum": "VALUE_OUT_OF_RANGE",
    "maximum": "VALUE_OUT_OF_RANGE",
    "minLength": "REQUIRED_FIELD",
    "const": "INVALID_ENUM",
}


def make_issue(
    severity: str,
    code: str,
    path: str,
    message: str,
    context: dict[str, Any] | None = None,
    fix: str | None = None,
) -> dict[str, Any]:
    """Create a structured issue dict."""
    issue: dict[str, Any] = {
        "severity": severity,
        "code": code,
        "path": path,
        "message": message,
    }
    if context:
        issue["context"] = context
    if fix:
        issue["fix"] = fix
    return issue


def path_str(path_parts: list) -> str:
    """Convert jsonschema path deque to dot-separated string."""
    parts = []
    for p in path_parts:
        if isinstance(p, int):
            parts.append(f"[{p}]")
        else:
            parts.append(str(p))
    result = ""
    for part in parts:
        if part.startswith("["):
            result += part
        elif result:
            result += "." + part
        else:
            result = part
    return result or "(root)"


def is_conditional_error(error: ValidationError) -> bool:
    """Check if a validation error comes from an if/then conditional."""
    for ctx in error.context or []:
        if ctx.schema_path and "then" in list(ctx.schema_path):
            return True
        if ctx.schema_path and "if" in list(ctx.schema_path):
            return True
    return False


def get_conditional_context(error: ValidationError, config: dict) -> dict[str, str]:
    """Extract the condition that triggered this error."""
    schema_path = list(error.schema_path)
    # Walk up to find the allOf index which maps to our conditional
    conditional_names = [
        "deploymentScript",
        "deploymentSsh",
        "deploymentSsm",
        "taskManagementAsana",
        "taskManagementGitlab",
        "taskManagementTaskforge",
        "infrastructureEnabled",
    ]
    condition_map = {
        "deploymentScript": ("deployment.method", "script"),
        "deploymentSsh": ("deployment.method", "ssh"),
        "deploymentSsm": ("deployment.method", "ssm"),
        "taskManagementAsana": ("task_management.backend", "asana"),
        "taskManagementGitlab": ("task_management.backend", "gitlab"),
        "taskManagementTaskforge": ("task_management.backend", "taskforge"),
        "infrastructureEnabled": ("infrastructure.enabled", "true"),
    }
    # Try to identify which conditional from schema_path
    for name in conditional_names:
        if name in schema_path:
            field, value = condition_map[name]
            return {field: value}
    return {}


def process_schema_errors(
    errors: list[ValidationError], config: dict
) -> list[dict[str, Any]]:
    """Convert jsonschema errors to structured issues with human-friendly messages."""
    issues: list[dict[str, Any]] = []
    seen_paths: set[str] = set()

    for error in sorted(errors, key=lambda e: list(e.absolute_path)):
        error_path = path_str(list(error.absolute_path))
        validator = error.validator

        # Skip duplicate paths
        if error_path in seen_paths and validator != "additionalProperties":
            continue

        # Handle if/then conditional failures
        if validator == "if" or (error.context and is_conditional_error(error)):
            # Process the nested then-clause errors
            for ctx_error in error.context or []:
                ctx_path_parts = list(ctx_error.absolute_path)
                ctx_path = path_str(ctx_path_parts)
                if ctx_path in seen_paths:
                    continue
                ctx_validator = ctx_error.validator
                ctx_code = VALIDATOR_CODE_MAP.get(ctx_validator, "CONDITIONAL_REQUIRED")

                # Build a meaningful message
                cond_context = get_conditional_context(error, config)
                if cond_context:
                    cond_str = ", ".join(
                        f"{k}={v!r}" for k, v in cond_context.items()
                    )
                    msg = f"Required when {cond_str}"
                else:
                    msg = ctx_error.message

                fix = None
                if ctx_validator == "required":
                    missing = ctx_error.message.split("'")[1] if "'" in ctx_error.message else ""
                    if missing:
                        full_path = f"{ctx_path}.{missing}" if ctx_path != "(root)" else missing
                        ctx_path = full_path
                        msg = f"Required when {', '.join(f'{k}={v!r}' for k, v in cond_context.items())}" if cond_context else ctx_error.message
                        fix = f'Add: {full_path}: "..."'

                if ctx_path not in seen_paths:
                    issues.append(
                        make_issue("error", "CONDITIONAL_REQUIRED", ctx_path, msg, cond_context, fix)
                    )
                    seen_paths.add(ctx_path)
            continue

        # Standard validators
        code = VALIDATOR_CODE_MAP.get(validator, "SCHEMA_VALIDATION")

        if validator == "required":
            missing = error.message.split("'")[1] if "'" in error.message else ""
            full_path = f"{error_path}.{missing}" if error_path != "(root)" else missing
            issues.append(
                make_issue(
                    "error",
                    code,
                    full_path,
                    f"Required field missing: {missing}",
                    fix=f'Add: {full_path}: "..."',
                )
            )
            seen_paths.add(full_path)

        elif validator == "additionalProperties":
            # jsonschema reports every unknown key of an object in ONE message
            # ("'a', 'b' were unexpected"), so taking only the first quoted name
            # hid all but one per section — the rest looked schema-clean and got
            # committed. Report each key as its own issue.
            extras = re.findall(r"'([^']+)'", error.message)
            if not extras:
                extras = [str(error.message)]

            for extra in extras:
                full_path = f"{error_path}.{extra}" if error_path != "(root)" else extra
                if full_path in seen_paths:
                    continue
                issues.append(
                    make_issue(
                        "error",
                        code,
                        full_path,
                        f"Unknown property: {extra}",
                        fix=f"Remove: {full_path}",
                    )
                )
                seen_paths.add(full_path)

        elif validator == "enum":
            allowed = error.schema.get("enum", [])
            issues.append(
                make_issue(
                    "error",
                    code,
                    error_path,
                    f"Invalid value: {error.instance!r}. Must be one of: {allowed}",
                    fix=f"Change to one of: {', '.join(repr(v) for v in allowed)}",
                )
            )
            seen_paths.add(error_path)

        elif validator == "type":
            expected = error.schema.get("type", "unknown")
            issues.append(
                make_issue(
                    "error",
                    code,
                    error_path,
                    f"Invalid type: expected {expected}, got {type(error.instance).__name__}",
                    fix=f"Change value to type: {expected}",
                )
            )
            seen_paths.add(error_path)

        elif validator in ("minimum", "maximum"):
            limit = error.schema.get(validator, "?")
            issues.append(
                make_issue(
                    "error",
                    code,
                    error_path,
                    f"Value {error.instance} is out of range ({validator}: {limit})",
                    fix=f"Set value between {error.schema.get('minimum', '...')} and {error.schema.get('maximum', '...')}",
                )
            )
            seen_paths.add(error_path)

        elif validator == "minLength":
            issues.append(
                make_issue(
                    "error",
                    code,
                    error_path,
                    "Value must not be empty",
                    fix=f'Set: {error_path}: "your-value"',
                )
            )
            seen_paths.add(error_path)

        elif validator == "oneOf":
            # Skip oneOf — usually from conditional patterns, not user-facing
            pass

        else:
            # Fallback for any other validator
            issues.append(
                make_issue("error", code, error_path, error.message)
            )
            seen_paths.add(error_path)

    return issues


def get_nested(config: dict, path: str, default: Any = None) -> Any:
    """Get nested config value by dot-separated path."""
    keys = path.split(".")
    value = config
    for key in keys:
        if isinstance(value, dict) and key in value:
            value = value[key]
        else:
            return default
    return value


def find_empty_strings(obj: Any, prefix: str = "") -> list[str]:
    """Recursively find all empty string values in a config tree."""
    paths: list[str] = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            path = f"{prefix}.{key}" if prefix else key
            if isinstance(value, str) and value == "":
                paths.append(path)
            else:
                paths.extend(find_empty_strings(value, path))
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            path = f"{prefix}[{i}]"
            if isinstance(item, str) and item == "":
                paths.append(path)
            else:
                paths.extend(find_empty_strings(item, path))
    return paths


def runtime_checks(config: dict) -> list[dict[str, Any]]:
    """Layer 2: Runtime checks for file existence, tokens, git state, etc."""
    issues: list[dict[str, Any]] = []

    # Empty string detection
    empty_paths = find_empty_strings(config)
    for path in empty_paths:
        issues.append(
            make_issue(
                "warning",
                "EMPTY_STRING",
                path,
                "Field is set to empty string",
                fix=f'Set a value or remove: {path}',
            )
        )

    # File existence: compose_file
    compose_file = get_nested(config, "docker.compose_file")
    if compose_file and not Path(compose_file).exists():
        issues.append(
            make_issue(
                "warning",
                "FILE_NOT_FOUND",
                "docker.compose_file",
                f"Compose file not found: {compose_file}",
                fix="Check docker.compose_file path or create the file",
            )
        )

    # File existence: version_file
    version_file = config.get("version_file")
    if version_file and not Path(version_file).exists():
        issues.append(
            make_issue(
                "warning",
                "FILE_NOT_FOUND",
                "version_file",
                f"Version file not found: {version_file}",
                fix="Check version_file path or remove to use git tags",
            )
        )

    # File existence: deployment scripts
    method = get_nested(config, "deployment.method")
    if method == "script":
        for env in ("staging", "production"):
            script = get_nested(config, f"deployment.{env}.script")
            if script and not Path(script).exists():
                issues.append(
                    make_issue(
                        "warning",
                        "FILE_NOT_FOUND",
                        f"deployment.{env}.script",
                        f"Deploy script not found: {script}",
                        fix=f"Create script at: {script}",
                    )
                )

    # Token files
    tm_backend = get_nested(config, "task_management.backend")
    if tm_backend == "asana":
        token_path = Path.home() / ".asana-token"
        if not token_path.exists():
            issues.append(
                make_issue(
                    "warning",
                    "TOKEN_NOT_FOUND",
                    "task_management.asana",
                    "~/.asana-token not found",
                    fix="Create token at: https://app.asana.com/0/my-apps",
                )
            )
    elif tm_backend == "gitlab":
        token_path = Path.home() / ".secrets/gitlab-token"
        if not token_path.exists():
            issues.append(
                make_issue(
                    "warning",
                    "TOKEN_NOT_FOUND",
                    "task_management.gitlab",
                    "~/.secrets/gitlab-token not found",
                    fix="Create token at GitLab settings",
                )
            )
    elif tm_backend == "taskforge":
        key_file = get_nested(config, "task_management.taskforge.api_key_file") or "~/.task-forge-key"
        key_path = Path(key_file).expanduser()
        if not key_path.exists():
            issues.append(
                make_issue(
                    "warning",
                    "TOKEN_NOT_FOUND",
                    "task_management.taskforge",
                    f"{key_file} not found",
                    fix=f"Create key file: echo 'your-api-key' > {key_file}",
                )
            )

    # Git tags check (when no version_file)
    if not config.get("version_file"):
        try:
            result = subprocess.run(
                ["git", "describe", "--tags", "--abbrev=0"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode != 0:
                issues.append(
                    make_issue(
                        "info",
                        "GIT_NO_TAGS",
                        "version",
                        "No git tags found (versioning via tags recommended)",
                        fix="Create a tag: git tag v0.1.0",
                    )
                )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass  # Not a git repo or git not available

    # Database two-user model check
    databases = config.get("databases", [])
    for i, db in enumerate(databases):
        db_name = db.get("name", f"database[{i}]")
        db_type = db.get("type", "")
        users = db.get("users", {})

        # Skip SQLite (no users)
        if db_type == "sqlite":
            continue

        has_migration = "migration" in users
        has_app = "app" in users

        if has_migration and has_app:
            mig_user_key = get_nested(
                users, "migration.secret_keys.username"
            )
            app_user_key = get_nested(users, "app.secret_keys.username")
            if mig_user_key and app_user_key and mig_user_key == app_user_key:
                issues.append(
                    make_issue(
                        "error",
                        "SAME_DB_USERS",
                        f"databases[{i}].users",
                        f"Database '{db_name}': migration and app username keys are identical ({mig_user_key})",
                        fix="Use different key names for migration vs app usernames",
                    )
                )
        elif has_migration or has_app:
            # Only warn about single user when migrations are enabled
            migrations_enabled = db.get("migrations", {}).get("enabled", False)
            if migrations_enabled:
                issues.append(
                    make_issue(
                        "warning",
                        "SINGLE_DB_USER",
                        f"databases[{i}].users",
                        f"Database '{db_name}': only one user configured (migrations enabled)",
                        fix="Add both migration and app users for two-user security model",
                    )
                )

    # Migration directory existence
    for i, db in enumerate(databases):
        db_name = db.get("name", f"database[{i}]")
        migrations = db.get("migrations", {})
        if migrations.get("enabled") and migrations.get("directory"):
            mig_dir = Path(migrations["directory"])
            if not mig_dir.exists():
                issues.append(
                    make_issue(
                        "warning",
                        "FILE_NOT_FOUND",
                        f"databases[{i}].migrations.directory",
                        f"Database '{db_name}': migrations directory not found: {mig_dir}",
                        fix=f"Create directory: mkdir -p {mig_dir}",
                    )
                )

    # Infrastructure: symlink check
    infra = config.get("infrastructure", {})
    if infra.get("enabled"):
        link_target = get_nested(infra, "link.target")
        if link_target:
            target_path = Path(link_target)
            if target_path.is_symlink():
                if not target_path.exists():
                    issues.append(
                        make_issue(
                            "warning",
                            "BROKEN_SYMLINK",
                            "infrastructure.link.target",
                            f"Infrastructure symlink is broken: {link_target}",
                            fix=f"Fix symlink: ln -sf /path/to/infra {link_target}",
                        )
                    )
            elif not target_path.exists():
                issues.append(
                    make_issue(
                        "warning",
                        "FILE_NOT_FOUND",
                        "infrastructure.link.target",
                        f"Infrastructure path does not exist: {link_target}",
                        fix=f"Create symlink: ln -s /path/to/infra {link_target}",
                    )
                )

        # Infrastructure repo URL required when type=git
        repo_type = get_nested(infra, "repo.type")
        repo_url = get_nested(infra, "repo.url")
        if repo_type == "git" and not repo_url:
            issues.append(
                make_issue(
                    "error",
                    "CONDITIONAL_REQUIRED",
                    "infrastructure.repo.url",
                    "Required when infrastructure.repo.type is 'git'",
                    context={"infrastructure.repo.type": "git"},
                    fix='Add: infrastructure.repo.url: "git@github.com:org/infra.git"',
                )
            )

    return issues


def validate(
    file_path: str, schema_only: bool = False
) -> dict[str, Any]:
    """Main validation function. Returns structured result dict."""
    config_path = Path(file_path)

    # Check file exists
    if not config_path.exists():
        return {
            "valid": False,
            "file": str(config_path),
            "schema_version": SCHEMA_VERSION,
            "summary": {"errors": 1, "warnings": 0, "info": 0},
            "issues": [
                make_issue(
                    "error",
                    "YAML_PARSE_ERROR",
                    "(file)",
                    f"PROJECT.yaml not found at {config_path}",
                    fix="Run: /project-config init",
                )
            ],
        }

    # Parse YAML
    try:
        with open(config_path) as f:
            config = yaml.safe_load(f)
    except yaml.YAMLError as e:
        return {
            "valid": False,
            "file": str(config_path),
            "schema_version": SCHEMA_VERSION,
            "summary": {"errors": 1, "warnings": 0, "info": 0},
            "issues": [
                make_issue(
                    "error",
                    "YAML_PARSE_ERROR",
                    "(file)",
                    f"Invalid YAML syntax: {e}",
                    fix="Check YAML formatting and indentation",
                )
            ],
        }

    if not isinstance(config, dict):
        return {
            "valid": False,
            "file": str(config_path),
            "schema_version": SCHEMA_VERSION,
            "summary": {"errors": 1, "warnings": 0, "info": 0},
            "issues": [
                make_issue(
                    "error",
                    "YAML_PARSE_ERROR",
                    "(root)",
                    "PROJECT.yaml must be a YAML mapping (object), not a scalar or list",
                    fix="Ensure the file starts with key-value pairs",
                )
            ],
        }

    # Load schema
    if not SCHEMA_PATH.exists():
        return {
            "valid": False,
            "file": str(config_path),
            "schema_version": SCHEMA_VERSION,
            "summary": {"errors": 1, "warnings": 0, "info": 0},
            "issues": [
                make_issue(
                    "error",
                    "SCHEMA_NOT_FOUND",
                    "(schema)",
                    f"Schema not found at {SCHEMA_PATH}",
                    fix="Ensure ~/.claude/schemas/project.schema.json exists",
                )
            ],
        }

    with open(SCHEMA_PATH) as f:
        schema = json.load(f)

    # Layer 1: Schema validation
    validator = Draft202012Validator(schema)
    schema_errors = list(validator.iter_errors(config))
    issues = process_schema_errors(schema_errors, config)

    # Layer 2: Runtime checks
    if not schema_only:
        issues.extend(runtime_checks(config))

    # Build summary
    errors = sum(1 for i in issues if i["severity"] == "error")
    warnings = sum(1 for i in issues if i["severity"] == "warning")
    infos = sum(1 for i in issues if i["severity"] == "info")

    return {
        "valid": errors == 0,
        "file": str(config_path),
        "schema_version": SCHEMA_VERSION,
        "summary": {"errors": errors, "warnings": warnings, "info": infos},
        "issues": issues,
    }


def format_human(result: dict[str, Any], quiet: bool = False) -> str:
    """Format result as colored human-readable output."""
    RED = "\033[0;31m"
    YELLOW = "\033[1;33m"
    GREEN = "\033[0;32m"
    BLUE = "\033[0;34m"
    BOLD = "\033[1m"
    NC = "\033[0m"

    lines: list[str] = []
    lines.append(f"{BOLD}PROJECT.yaml Validation{NC} (schema v{result['schema_version']})")
    lines.append(f"File: {result['file']}")
    lines.append("")

    error_issues = [i for i in result["issues"] if i["severity"] == "error"]
    warn_issues = [i for i in result["issues"] if i["severity"] == "warning"]
    info_issues = [i for i in result["issues"] if i["severity"] == "info"]

    if error_issues:
        lines.append(f"{RED}Errors: {len(error_issues)}{NC}")
        for issue in error_issues:
            lines.append(f"  {RED}x{NC} [{issue['path']}] {issue['message']}")
            if issue.get("fix"):
                lines.append(f"    -> {issue['fix']}")
        lines.append("")

    if warn_issues:
        lines.append(f"{YELLOW}Warnings: {len(warn_issues)}{NC}")
        for issue in warn_issues:
            lines.append(f"  {YELLOW}!{NC} [{issue['path']}] {issue['message']}")
            if issue.get("fix"):
                lines.append(f"    -> {issue['fix']}")
        lines.append("")

    if info_issues and not quiet:
        lines.append(f"{BLUE}Info: {len(info_issues)}{NC}")
        for issue in info_issues:
            lines.append(f"  {BLUE}i{NC} [{issue['path']}] {issue['message']}")
            if issue.get("fix"):
                lines.append(f"    -> {issue['fix']}")
        lines.append("")

    if result["valid"]:
        lines.append(f"{GREEN}Valid{NC} - PROJECT.yaml passes all checks")
    else:
        lines.append(f"{RED}Invalid{NC} - {result['summary']['errors']} error(s) found")

    return "\n".join(lines)


def main() -> None:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Schema-driven PROJECT.yaml validator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--file", default="PROJECT.yaml", help="Path to PROJECT.yaml (default: ./PROJECT.yaml)"
    )
    parser.add_argument("--json", action="store_true", dest="json_output", help="Structured JSON output (default)")
    parser.add_argument("--human", action="store_true", help="Colored human-readable output")
    parser.add_argument("--strict", action="store_true", help="Treat warnings as errors")
    parser.add_argument("--schema-only", action="store_true", help="Skip runtime checks")
    parser.add_argument("--quiet", action="store_true", help="Suppress info-level messages")

    args = parser.parse_args()

    result = validate(args.file, schema_only=args.schema_only)

    if args.human:
        print(format_human(result, quiet=args.quiet))
    else:
        output = result
        if args.quiet:
            output = dict(result)
            output["issues"] = [i for i in result["issues"] if i["severity"] != "info"]
        print(json.dumps(output, indent=2))

    # Exit code
    if not result["valid"]:
        sys.exit(1)
    elif args.strict and result["summary"]["warnings"] > 0:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
