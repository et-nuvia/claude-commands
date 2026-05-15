#!/usr/bin/env python3
"""
validate-project-yaml.py - Validate PROJECT.yaml against schema

Usage:
    validate-project-yaml.py [path/to/PROJECT.yaml]

Output:
    true - If validation passes
    false - If validation fails, followed by list of invalid paths

Exit codes:
    0 - Valid
    1 - Invalid
"""

import sys
import json
import yaml
from pathlib import Path
from jsonschema import Draft202012Validator, ValidationError

def validate_project_yaml(project_yaml_path: str, schema_path: str) -> tuple[bool, list[str]]:
    """
    Validate PROJECT.yaml against schema.

    Returns:
        tuple: (is_valid, list_of_invalid_paths)
    """
    # Load schema
    with open(schema_path, 'r') as f:
        schema = json.load(f)

    # Load PROJECT.yaml
    with open(project_yaml_path, 'r') as f:
        data = yaml.safe_load(f)

    # Create validator
    validator = Draft202012Validator(schema)

    # Collect all validation errors
    errors = list(validator.iter_errors(data))

    if not errors:
        return True, []

    # Extract paths from errors
    invalid_paths = set()
    for error in errors:
        # Build path from error.path (list of property names/indices)
        if error.path:
            path = '.' + '.'.join(str(p) for p in error.path)
            invalid_paths.add(path)
        # Also add absolute_path if available (more specific)
        if error.absolute_path:
            path = '.' + '.'.join(str(p) for p in error.absolute_path)
            invalid_paths.add(path)

        # Debug: print error message to stderr (uncomment for debugging)
        # print(f"DEBUG: {path}: {error.message}", file=sys.stderr)

    return False, sorted(invalid_paths)

def main():
    # Default paths
    home = Path.home()
    schema_file = home / '.claude' / 'schemas' / 'project.schema.json'
    project_yaml = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('PROJECT.yaml')

    # Check files exist
    if not schema_file.exists():
        print(f"ERROR: Schema file not found: {schema_file}", file=sys.stderr)
        sys.exit(1)

    if not project_yaml.exists():
        print(f"ERROR: {project_yaml} not found", file=sys.stderr)
        sys.exit(1)

    # Validate
    try:
        is_valid, invalid_paths = validate_project_yaml(str(project_yaml), str(schema_file))

        if is_valid:
            print("true")
            sys.exit(0)
        else:
            print("false")
            for path in invalid_paths:
                print(path)
            sys.exit(1)

    except Exception as e:
        print(f"ERROR: Validation failed: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
