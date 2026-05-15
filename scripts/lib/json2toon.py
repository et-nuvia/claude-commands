#!/usr/bin/env python3
"""json2toon.py — Convert JSON to TOON (Token-Oriented Object Notation).

Reads JSON from stdin, outputs TOON to stdout.
Falls back to raw JSON passthrough on any error.

TOON spec v3.0: https://github.com/toon-format/spec
"""

import json
import math
import re
import sys

# Keys that don't need quoting
_SAFE_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")

# Patterns that force string quoting
_NUMERIC_RE = re.compile(r"^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$")
_OCTAL_RE = re.compile(r"^0\d+$")
_NEEDS_QUOTE_CHARS = set(':"\\[]{}\n\r\t')


def _quote_key(key: str) -> str:
    """Quote a key if it doesn't match safe key pattern."""
    if _SAFE_KEY_RE.match(key):
        return key
    return '"' + _escape(key) + '"'


def _escape(s: str) -> str:
    """Escape a string for TOON quoted form."""
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def _needs_quoting(s: str, delimiter: str = ",") -> bool:
    """Check if a string value needs quoting."""
    if not s:
        return True  # empty string
    if s in ("true", "false", "null"):
        return True
    if s.startswith("-") or s.startswith(" ") or s.endswith(" "):
        return True
    if _NUMERIC_RE.match(s) or _OCTAL_RE.match(s):
        return True
    if any(c in _NEEDS_QUOTE_CHARS for c in s):
        return True
    if delimiter in s:
        return True
    return False


def _encode_value(val, delimiter: str = ",") -> str:
    """Encode a primitive value as a TOON string."""
    if val is None:
        return "null"
    if isinstance(val, bool):
        return "true" if val else "false"
    if isinstance(val, int):
        return str(val)
    if isinstance(val, float):
        if math.isnan(val) or math.isinf(val):
            return "null"
        # No trailing zeros, integer form if whole
        if val == int(val) and not math.isinf(val):
            return str(int(val))
        return f"{val:g}"
    if isinstance(val, str):
        if _needs_quoting(val, delimiter):
            return '"' + _escape(val) + '"'
        return val
    return '"' + _escape(str(val)) + '"'


def _is_tabular(arr: list) -> bool:
    """Check if an array of objects qualifies for tabular encoding.

    All elements must be dicts with the same keys, all values primitive.
    """
    if not arr or not all(isinstance(item, dict) for item in arr):
        return False
    keys = list(arr[0].keys())
    if not keys:
        return False
    for item in arr:
        if list(item.keys()) != keys:
            return False
        for v in item.values():
            if isinstance(v, (dict, list)):
                return False
    return True


def _is_primitive_array(arr: list) -> bool:
    """Check if all elements are primitives (not dict or list)."""
    return all(not isinstance(item, (dict, list)) for item in arr)


def _encode_object(obj: dict, depth: int = 0) -> list[str]:
    """Encode a dict as TOON lines."""
    lines = []
    indent = "  " * depth

    for key, val in obj.items():
        qkey = _quote_key(key)

        if isinstance(val, dict):
            if not val:
                # Empty object: key: {}
                lines.append(f"{indent}{qkey}: {{}}")
            else:
                lines.append(f"{indent}{qkey}:")
                lines.extend(_encode_object(val, depth + 1))

        elif isinstance(val, list):
            lines.extend(_encode_array(qkey, val, depth))

        else:
            lines.append(f"{indent}{qkey}: {_encode_value(val)}")

    return lines


def _encode_array(key: str, arr: list, depth: int) -> list[str]:
    """Encode an array field as TOON lines."""
    indent = "  " * depth
    n = len(arr)

    if n == 0:
        return [f"{indent}{key}[0]:"]

    # Tabular: array of uniform objects with primitive values
    if _is_tabular(arr):
        fields = list(arr[0].keys())
        header = f"{indent}{key}[{n}]{{{','.join(fields)}}}:"
        lines = [header]
        row_indent = "  " * (depth + 1)
        for item in arr:
            vals = [_encode_value(item[f]) for f in fields]
            lines.append(f"{row_indent}{','.join(vals)}")
        return lines

    # Inline primitive array
    if _is_primitive_array(arr):
        vals = [_encode_value(v) for v in arr]
        joined = ",".join(vals)
        # If short enough, inline
        if len(joined) < 200:
            return [f"{indent}{key}[{n}]: {joined}"]
        # Otherwise expanded
        lines = [f"{indent}{key}[{n}]:"]
        row_indent = "  " * (depth + 1)
        for v in arr:
            lines.append(f"{row_indent}- {_encode_value(v)}")
        return lines

    # Mixed/complex array: expanded list
    lines = [f"{indent}{key}[{n}]:"]
    row_indent = "  " * (depth + 1)
    for item in arr:
        if isinstance(item, dict):
            if not item:
                lines.append(f"{row_indent}- {{}}")
            else:
                obj_lines = _encode_object(item, depth + 2)
                if obj_lines:
                    # First field on hyphen line
                    first = obj_lines[0].lstrip()
                    lines.append(f"{row_indent}- {first}")
                    lines.extend(obj_lines[1:])
        elif isinstance(item, list):
            # Nested array as list item
            sub = _encode_array("", item, depth + 2)
            if sub:
                first = sub[0].lstrip()
                lines.append(f"{row_indent}- {first}")
                lines.extend(sub[1:])
        else:
            lines.append(f"{row_indent}- {_encode_value(item)}")

    return lines


def _encode_root_array(arr: list) -> list[str]:
    """Encode a root-level array."""
    n = len(arr)

    if n == 0:
        return ["[0]:"]

    if _is_tabular(arr):
        fields = list(arr[0].keys())
        header = f"[{n}]{{{','.join(fields)}}}:"
        lines = [header]
        for item in arr:
            vals = [_encode_value(item[f]) for f in fields]
            lines.append(f"  {','.join(vals)}")
        return lines

    if _is_primitive_array(arr):
        vals = [_encode_value(v) for v in arr]
        return [f"[{n}]: {','.join(vals)}"]

    lines = [f"[{n}]:"]
    for item in arr:
        if isinstance(item, dict):
            if not item:
                lines.append("  - {}")
            else:
                obj_lines = _encode_object(item, 2)
                if obj_lines:
                    first = obj_lines[0].lstrip()
                    lines.append(f"  - {first}")
                    lines.extend(obj_lines[1:])
        elif isinstance(item, list):
            sub = _encode_array("", item, 2)
            if sub:
                first = sub[0].lstrip()
                lines.append(f"  - {first}")
                lines.extend(sub[1:])
        else:
            lines.append(f"  - {_encode_value(item)}")

    return lines


def encode(data) -> str:
    """Encode a Python object as TOON."""
    if isinstance(data, dict):
        lines = _encode_object(data, 0)
    elif isinstance(data, list):
        lines = _encode_root_array(data)
    else:
        # Single primitive
        return _encode_value(data)

    return "\n".join(lines)


def main():
    """Read JSON from stdin, output TOON to stdout."""
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
        print(encode(data))
    except Exception:
        # Fallback: passthrough raw JSON on any error
        try:
            sys.stdout.write(raw)
        except Exception:
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
