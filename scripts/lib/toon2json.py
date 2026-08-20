#!/usr/bin/env python3
"""toon2json.py — Convert TOON (Token-Oriented Object Notation) to JSON.

Reads TOON from stdin, outputs compact JSON to stdout. This is the inverse of
json2toon.py and is intended for scripts that call a TOON-emitting helper and
need to feed the result to `jq`.

If the input is already JSON, it is normalized and passed through. On any
unrecoverable parse error the raw input is written back unchanged and the
process exits non-zero (so callers can `|| echo null`), mirroring json2toon.py's
fail-safe behavior.

TOON spec v3.0: https://github.com/toon-format/spec
"""

import json
import re
import sys

_INT_RE = re.compile(r"^-?\d+$")
_FLOAT_RE = re.compile(r"^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$")


def _unescape(s: str) -> str:
    """Reverse json2toon's _escape()."""
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            nxt = s[i + 1]
            out.append({"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _scalar(tok: str):
    """Decode a single TOON scalar token to a Python value."""
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == '"' and tok[-1] == '"':
        return _unescape(tok[1:-1])
    if tok == "null":
        return None
    if tok == "true":
        return True
    if tok == "false":
        return False
    if _INT_RE.match(tok):
        try:
            return int(tok)
        except ValueError:
            return tok
    if _FLOAT_RE.match(tok):
        try:
            return float(tok)
        except ValueError:
            return tok
    return tok


def _split_delim(s: str, delim: str = ",") -> list:
    """Split on `delim`, ignoring delimiters inside double-quoted spans."""
    parts = []
    buf = []
    in_q = False
    esc = False
    for c in s:
        if esc:
            buf.append(c)
            esc = False
            continue
        if in_q and c == "\\":
            buf.append(c)
            esc = True
            continue
        if c == '"':
            in_q = not in_q
            buf.append(c)
            continue
        if c == delim and not in_q:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(c)
    parts.append("".join(buf))
    return parts


def _split_key(content: str):
    """Split a content line into (key, remainder-after-key)."""
    if content.startswith('"'):
        i = 1
        n = len(content)
        while i < n:
            if content[i] == "\\":
                i += 2
                continue
            if content[i] == '"':
                break
            i += 1
        return _unescape(content[1:i]), content[i + 1:]
    m = re.match(r"[^:\[]*", content)
    return m.group(0), content[m.end():]


class _Parser:
    def __init__(self, text: str):
        self.lines = []
        for raw in text.split("\n"):
            raw = raw.rstrip("\r")
            if raw.strip() == "":
                continue
            indent = len(raw) - len(raw.lstrip(" "))
            self.lines.append((indent, raw[indent:]))
        self.i = 0

    def parse_root(self):
        if not self.lines:
            return None
        indent, content = self.lines[0]
        if content.startswith("["):
            # Consume the array header line (lines[0]) before parsing rows/items,
            # so the tabular/expanded readers start at the first DATA line instead
            # of re-reading the header as a row. (The object/scalar branches below
            # advance self.i themselves via parse_object.)
            self.i = 1
            return self._parse_array_from_line(content, indent, key_consumed=True)
        # object or single scalar
        key, rest = _split_key(content)
        if rest.startswith(":") or rest.startswith("["):
            return self.parse_object(indent)
        # bare single scalar document
        return _scalar(content)

    def parse_object(self, indent: int) -> dict:
        obj = {}
        while self.i < len(self.lines):
            ind, content = self.lines[self.i]
            if ind != indent:
                break
            self.i += 1
            key, rest = _split_key(content)
            if rest.startswith("["):
                obj[key] = self._parse_array_from_line(rest, indent, key_consumed=False)
            elif rest.startswith(":"):
                after = rest[1:].strip()
                if after == "":
                    obj[key] = self.parse_object(indent + 2)
                elif after == "{}":
                    obj[key] = {}
                else:
                    obj[key] = _scalar(after)
            else:
                # malformed; treat whole as scalar under key
                obj[key] = _scalar(rest)
        return obj

    def _parse_array_from_line(self, rest: str, indent: int, key_consumed: bool):
        """Parse an array given the marker text `rest` beginning at '['."""
        m = re.match(r"\[(\d+)\]", rest)
        if not m:
            return _scalar(rest)
        n = int(m.group(1))
        rest = rest[m.end():]

        # Tabular: {field,field}:
        if rest.startswith("{"):
            fend = rest.index("}")
            fields = [f for f in rest[1:fend].split(",")]
            rows = []
            for _ in range(n):
                if self.i >= len(self.lines):
                    break
                _, content = self.lines[self.i]
                self.i += 1
                vals = _split_delim(content)
                row = {}
                for k, field in enumerate(fields):
                    row[field] = _scalar(vals[k]) if k < len(vals) else None
                rows.append(row)
            return rows

        # rest should start with ':'
        after = rest[1:] if rest.startswith(":") else rest
        if n == 0:
            return []
        if after.strip() != "":
            # inline primitive array
            return [_scalar(v) for v in _split_delim(after.strip())]

        # expanded list: '- ' items at indent+2
        arr = []
        child_indent = indent + 2
        while self.i < len(self.lines):
            ind, content = self.lines[self.i]
            if ind != child_indent or not content.startswith("- "):
                break
            self.i += 1
            arr.append(self._parse_list_item(content[2:], child_indent))
        return arr

    def _parse_list_item(self, body: str, item_indent: int):
        key, rest = _split_key(body)
        if rest.startswith(":") or rest.startswith("["):
            # object item: first field on the hyphen line, continued fields at +2
            item = {}
            if rest.startswith("["):
                item[key] = self._parse_array_from_line(rest, item_indent, key_consumed=False)
            else:
                after = rest[1:].strip()
                if after == "":
                    item[key] = self.parse_object(item_indent + 2)
                elif after == "{}":
                    item[key] = {}
                else:
                    item[key] = _scalar(after)
            cont_indent = item_indent + 2
            while self.i < len(self.lines):
                ind, content = self.lines[self.i]
                if ind != cont_indent or content.startswith("- "):
                    break
                self.i += 1
                k2, r2 = _split_key(content)
                if r2.startswith("["):
                    item[k2] = self._parse_array_from_line(r2, cont_indent, key_consumed=False)
                elif r2.startswith(":"):
                    a2 = r2[1:].strip()
                    if a2 == "":
                        item[k2] = self.parse_object(cont_indent + 2)
                    elif a2 == "{}":
                        item[k2] = {}
                    else:
                        item[k2] = _scalar(a2)
            return item
        # scalar item
        return _scalar(body)


def main():
    raw = sys.stdin.read()
    # Already JSON? normalize and pass through.
    try:
        return print(json.dumps(json.loads(raw)))
    except Exception:
        pass
    try:
        data = _Parser(raw).parse_root()
        print(json.dumps(data))
    except Exception:
        try:
            sys.stdout.write(raw)
        except Exception:
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
