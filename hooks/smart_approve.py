#!/usr/bin/env python3
"""Smart PreToolUse hook for Claude Code.

Decomposes compound bash commands (&&, ||, ;, |, $(), newlines) into
individual sub-commands and checks each against the allow/deny patterns
in ~/.claude/settings.json.

Input:  JSON on stdin with tool_name and tool_input.command
Output: JSON with {"decision": "allow"/"deny", "reason": "..."} or silent exit
"""

import fnmatch
import json
import os
import re
import shlex
import sys


def load_settings(path=None):
    """Load and return the permissions dict from settings.json."""
    if path is None:
        path = os.path.expanduser("~/.claude/settings.json")
    path = os.path.expanduser(path)
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def load_merged_settings(global_path=None):
    """Load and merge all settings layers matching Claude Code's behavior.

    Loads up to three sources and merges their permissions.allow/deny arrays:
      1. Global:        ~/.claude/settings.json (or $CLAUDE_SETTINGS_PATH)
      2. Project:       $CLAUDE_PROJECT_DIR/.claude/settings.json (committed)
      3. Project-local: $CLAUDE_PROJECT_DIR/.claude/settings.local.json (gitignored)
    """
    settings = load_settings(global_path)

    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if not project_dir:
        return settings

    # Load both project settings files
    project_shared = load_settings(
        os.path.join(project_dir, ".claude", "settings.json")
    )
    project_local = load_settings(
        os.path.join(project_dir, ".claude", "settings.local.json")
    )

    if not project_shared and not project_local:
        return settings

    # Merge permissions arrays from all layers (deduplicated, order-preserving)
    global_perms = settings.get("permissions", {})
    shared_perms = project_shared.get("permissions", {})
    local_perms = project_local.get("permissions", {})

    merged_allow = list(dict.fromkeys(
        global_perms.get("allow", [])
        + shared_perms.get("allow", [])
        + local_perms.get("allow", [])
    ))
    merged_deny = list(dict.fromkeys(
        global_perms.get("deny", [])
        + shared_perms.get("deny", [])
        + local_perms.get("deny", [])
    ))

    settings.setdefault("permissions", {})
    settings["permissions"]["allow"] = merged_allow
    settings["permissions"]["deny"] = merged_deny

    return settings


def parse_bash_patterns(patterns):
    """Extract command prefixes from Bash(...) permission patterns.

    "Bash(git status:*)" -> "git status"
    "Bash(rm:*)"         -> "rm"
    Non-Bash patterns are skipped.

    Returns a list of (prefix_string, glob_pattern) tuples.
    The glob_pattern is what fnmatch should match against.
    """
    result = []
    for pat in patterns:
        m = re.match(r'^Bash\((.+)\)$', pat)
        if not m:
            continue
        inner = m.group(1)
        # inner is like "git status:*" or "rm:*" or "/Users/yair/...adb*"
        # Split on first ':'
        colon_idx = inner.find(':')
        if colon_idx == -1:
            # Pattern like "Bash(something)" with no colon — treat as exact prefix
            result.append((inner, inner))
        else:
            prefix = inner[:colon_idx]
            suffix = inner[colon_idx + 1:]
            # The glob pattern is prefix + ' ' + suffix (for matching with args)
            # But we also want bare prefix to match (no args)
            glob_pat = prefix + ' ' + suffix if suffix else prefix
            result.append((prefix, glob_pat))
    return result


def command_matches_pattern(cmd, patterns):
    """Check if a command matches any of the parsed Bash patterns.

    Each pattern is (prefix, glob_pattern).
    A command matches if:
      - It equals the prefix exactly (bare command, no args), OR
      - fnmatch(cmd, glob_pattern) is True
    """
    for prefix, glob_pat in patterns:
        if cmd == prefix:
            return True
        if fnmatch.fnmatch(cmd, glob_pat):
            return True
    return False


def extract_subshells(command):
    """Extract contents of $() and backtick subshells, recursively.

    Returns a list of subshell content strings.
    """
    subshells = []

    # Extract $(...) — handle nested parens, but skip $((...)) arithmetic
    i = 0
    while i < len(command):
        if command[i] == '$' and i + 1 < len(command) and command[i + 1] == '(' \
                and not (i + 2 < len(command) and command[i + 2] == '('):
            # Find matching closing paren
            depth = 0
            start = i + 2
            j = i + 1
            while j < len(command):
                if command[j] == '(':
                    depth += 1
                elif command[j] == ')':
                    depth -= 1
                    if depth == 0:
                        content = command[start:j]
                        subshells.append(content)
                        # Recurse into content for nested subshells
                        subshells.extend(extract_subshells(content))
                        break
                j += 1
            i = j + 1
        else:
            i += 1

    # Extract backtick subshells (no nesting)
    parts = command.split('`')
    # Odd-indexed parts are inside backticks
    for idx in range(1, len(parts), 2):
        content = parts[idx]
        if content.strip():
            subshells.append(content)
            subshells.extend(extract_subshells(content))

    return subshells


def strip_heredocs(command):
    """Strip heredoc bodies from a command, leaving just the <<DELIM marker.

    Heredocs like <<'EOF'\\n...\\nEOF are replaced with the marker only
    (body removed).  This prevents heredoc content lines from being treated
    as sub-commands when we split on newlines.
    """
    lines = command.split('\n')
    result = []
    heredoc_delim = None
    i = 0

    while i < len(lines):
        if heredoc_delim is not None:
            # Inside heredoc body — look for the terminator line
            if lines[i].strip() == heredoc_delim:
                heredoc_delim = None
            i += 1
            continue

        # Check for heredoc marker: <<[-]?['"]?WORD['"]?
        m = re.search(r'<<-?\s*[\'"]?(\w+)[\'"]?', lines[i])
        if m:
            heredoc_delim = m.group(1)

        result.append(lines[i])
        i += 1

    return '\n'.join(result)


def split_on_operators(command):
    """Split a command string on &&, ||, ;, |, and newlines.

    Respects quoted strings and $() subshells (doesn't split inside them).
    Returns the top-level command segments.
    """
    # Strip heredoc bodies so their lines aren't treated as commands
    command = strip_heredocs(command)
    # Collapse backslash-newline continuations before parsing
    command = command.replace('\\\n', ' ')

    segments = []
    current = []
    i = 0
    in_single_quote = False
    in_double_quote = False
    paren_depth = 0

    while i < len(command):
        ch = command[i]

        # Handle backslash escaping (not inside single quotes, where \ is literal)
        if ch == '\\' and not in_single_quote and i + 1 < len(command):
            current.append(ch)
            current.append(command[i + 1])
            i += 2
            continue

        # Track quoting
        if ch == "'" and not in_double_quote and paren_depth == 0:
            in_single_quote = not in_single_quote
            current.append(ch)
            i += 1
            continue
        if ch == '"' and not in_single_quote and paren_depth == 0:
            in_double_quote = not in_double_quote
            current.append(ch)
            i += 1
            continue

        if in_single_quote or in_double_quote:
            current.append(ch)
            i += 1
            continue

        # Track $() subshell depth — consume $( as a single token
        if ch == '$' and i + 1 < len(command) and command[i + 1] == '(':
            paren_depth += 1
            current.append('$')
            current.append('(')
            i += 2
            continue
        if ch == '(' and paren_depth > 0:
            paren_depth += 1
            current.append(ch)
            i += 1
            continue
        if ch == ')' and paren_depth > 0:
            paren_depth -= 1
            current.append(ch)
            i += 1
            continue

        if paren_depth > 0:
            current.append(ch)
            i += 1
            continue

        # Split on operators at top level
        if ch == '&' and i + 1 < len(command) and command[i + 1] == '&':
            segments.append(''.join(current))
            current = []
            i += 2
            continue
        if ch == '|' and i + 1 < len(command) and command[i + 1] == '|':
            segments.append(''.join(current))
            current = []
            i += 2
            continue
        if ch == ';':
            segments.append(''.join(current))
            current = []
            i += 1
            continue
        if ch == '|':
            segments.append(''.join(current))
            current = []
            i += 1
            continue
        if ch == '\n':
            segments.append(''.join(current))
            current = []
            i += 1
            continue

        current.append(ch)
        i += 1

    segments.append(''.join(current))
    return [s.strip() for s in segments if s.strip()]


def _skip_shell_value(cmd, i):
    """Skip past one shell 'word' value starting at position i.

    Handles quoted strings, $() subshells (tracking paren depth), and
    bare non-whitespace runs.  Returns the index just past the value.
    """
    if i >= len(cmd):
        return i

    # Quoted value
    if cmd[i] == '"':
        i += 1
        while i < len(cmd) and cmd[i] != '"':
            if cmd[i] == '\\' and i + 1 < len(cmd):
                i += 2
            else:
                i += 1
        if i < len(cmd):
            i += 1  # skip closing quote
        return i
    if cmd[i] == "'":
        i += 1
        while i < len(cmd) and cmd[i] != "'":
            i += 1
        if i < len(cmd):
            i += 1  # skip closing quote
        return i

    # Unquoted value — consume non-whitespace, tracking $() depth
    paren_depth = 0
    while i < len(cmd):
        ch = cmd[i]
        if ch == '$' and i + 1 < len(cmd) and cmd[i + 1] == '(':
            paren_depth += 1
            i += 2
            continue
        if ch == '(' and paren_depth > 0:
            paren_depth += 1
            i += 1
            continue
        if ch == ')' and paren_depth > 0:
            paren_depth -= 1
            i += 1
            continue
        if paren_depth > 0:
            i += 1
            continue
        if ch in (' ', '\t'):
            break
        i += 1
    return i


def strip_env_vars(cmd):
    """Strip leading environment variable assignments (FOO=bar cmd ...).

    Returns the command with env var prefixes removed.
    Correctly handles values containing $() subshells.
    """
    while True:
        m = re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', cmd)
        if not m:
            break
        # Find end of value (respecting quotes and $() depth)
        i = _skip_shell_value(cmd, m.end())
        # If nothing follows the assignment, this IS the command — keep it
        rest = cmd[i:].lstrip()
        if not rest:
            break
        cmd = rest
    return cmd


# Global flags that appear BETWEEN the verb and its subcommand/target and
# don't change what the command fundamentally does. Prefix-style allow
# patterns like "git status:*" never match "git -C /path status", so these
# are stripped before matching. 'with_arg' flags consume a following value
# (unless given as --flag=value); 'bare' flags stand alone.
_GLOBAL_FLAGS = {
    'git': {
        'with_arg': {'-C', '-c', '--git-dir', '--work-tree'},
        'bare': {'--no-pager', '-P', '-p', '--paginate'},
    },
    'make': {
        'with_arg': {'-C', '--directory'},
        'bare': set(),
    },
    'npm': {
        'with_arg': {'--prefix'},
        'bare': set(),
    },
    'gh': {
        'with_arg': {'-R', '--repo'},
        'bare': set(),
    },
    'terraform': {
        'with_arg': {'-chdir'},
        'bare': set(),
    },
}

_GLOBAL_FLAG_VERB_RE = re.compile(r'^(git|make|npm|gh|terraform)\s+')


def strip_global_flags(cmd):
    """Strip leading global flags from git/make commands.

    "git -C /path status --short" -> "git status --short"
    "git --no-pager log -5"       -> "git log -5"
    "make -C /path test"          -> "make test"

    Stops at the first token that isn't a recognized global flag, so
    subcommand flags (e.g. "git log --oneline") are untouched.
    """
    m = _GLOBAL_FLAG_VERB_RE.match(cmd)
    if not m:
        return cmd
    verb = m.group(1)
    spec = _GLOBAL_FLAGS[verb]
    rest = cmd[m.end():]

    while rest.startswith('-'):
        fm = re.match(r'(\S+)\s*', rest)
        flag = fm.group(1)
        base = flag.split('=', 1)[0]
        if base in spec['bare'] and '=' not in flag:
            rest = rest[fm.end():]
        elif base in spec['with_arg']:
            rest = rest[fm.end():]
            if '=' not in flag:
                # Flag takes a separate argument (possibly quoted) — skip it
                end = _skip_shell_value(rest, 0)
                rest = rest[end:].lstrip()
        else:
            break

    if rest == cmd[m.end():]:
        return cmd
    return f"{verb} {rest}".strip()


def strip_redirections(cmd):
    """Strip output/input redirections from a command.

    Removes patterns like >file, >>file, 2>&1, <file, etc.
    """
    # Remove redirections: N>file, N>>file, N>&N, <file, <<word, <<<word
    cmd = re.sub(r'\d*>>?\s*&?\d*\S*', '', cmd)
    cmd = re.sub(r'<<<?\s*\S+', '', cmd)
    # Simple input redirection: < file
    cmd = re.sub(r'<\s*\S+', '', cmd)
    return cmd.strip()


# Shell keywords that are structural, not commands to approve/deny.
# These appear as segments after splitting on ;/newlines in for/while/if blocks.
SHELL_KEYWORDS = frozenset({
    'do', 'done', 'then', 'else', 'elif', 'fi', 'esac', '{', '}',
    'break', 'continue',
})

# Keywords that can prefix a command when joined by ; (e.g. "do echo hello").
# These should be stripped to expose the real command underneath.
_KEYWORD_PREFIX_RE = re.compile(
    r'^(do|then|else|elif)\s+'
)

# Patterns for shell compound statement headers (for, while, until, if, case).
# These introduce control flow but aren't executable commands themselves.
_COMPOUND_HEADER_RE = re.compile(
    r'^(for|while|until|if|case|select)\b'
)


def strip_keyword_prefix(cmd):
    """Strip leading shell keyword prefix from a command.

    "do echo hello" -> "echo hello"
    "then git status" -> "git status"
    """
    m = _KEYWORD_PREFIX_RE.match(cmd)
    if m:
        return cmd[m.end():]
    return cmd


def is_shell_structural(cmd):
    """Return True if cmd is a shell keyword or compound-statement header."""
    if cmd in SHELL_KEYWORDS:
        return True
    if _COMPOUND_HEADER_RE.match(cmd):
        return True
    return False


def is_standalone_assignment(cmd):
    """Return True if cmd is purely a variable assignment (no following command).

    e.g. "result=$(curl ...)" or "FOO=bar" — these are not commands to check.
    The subshell contents, if any, are extracted and checked separately.
    """
    m = re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', cmd)
    if not m:
        return False
    # Check if the entire string is consumed by the assignment value
    end = _skip_shell_value(cmd, m.end())
    rest = cmd[end:].strip()
    return rest == ''


def normalize_command(cmd):
    """Normalize a command by stripping env vars, redirections, and whitespace."""
    cmd = cmd.strip()
    if not cmd:
        return cmd
    cmd = strip_keyword_prefix(cmd)
    cmd = strip_env_vars(cmd)
    cmd = strip_global_flags(cmd)
    cmd = strip_redirections(cmd)
    # Collapse multiple spaces
    cmd = re.sub(r'\s+', ' ', cmd)
    return cmd.strip()


def decompose_command(command):
    """Decompose a compound command into all individual sub-commands.

    Splits on operators, extracts subshell contents, normalizes each.
    Filters out shell structural keywords (for/do/done/etc.) and
    standalone variable assignments (whose subshell contents are checked
    separately).
    Returns a list of normalized command strings.
    """
    all_commands = []

    # Get top-level segments
    segments = split_on_operators(command)

    for seg in segments:
        # Also decompose any subshells found in this segment
        subshells = extract_subshells(seg)
        for sub in subshells:
            sub_segments = split_on_operators(sub)
            for ss in sub_segments:
                normalized = normalize_command(ss)
                if normalized:
                    all_commands.append(normalized)

        # Normalize the top-level segment itself
        normalized = normalize_command(seg)
        if normalized:
            all_commands.append(normalized)

    # Filter out shell structural keywords and standalone assignments
    return [
        cmd for cmd in all_commands
        if not is_shell_structural(cmd) and not is_standalone_assignment(cmd)
    ]


# Safe verbs whose every positional argument is a filesystem path. For these
# we require every non-flag argument to be an absolute path under /tmp.
SAFE_TMP_FILE_VERBS = frozenset({
    "cat", "ls", "head", "tail", "wc", "stat", "file", "cp", "mv", "rm",
    "rmdir", "touch", "mkdir", "tee", "diff", "cmp", "realpath", "dirname",
    "basename", "du", "truncate", "readlink", "ln",
})

# Verbs whose positional args are literal data, not paths (so only their
# redirect target matters for /tmp scoping).
SAFE_TMP_LITERAL_VERBS = frozenset({"echo", "printf"})

# Network / code-execution verbs are explicitly NOT here — they must always
# fall through to a prompt even when a /tmp path appears in their arguments.

# Matches a redirection operator followed by its file target. fd-duplication
# targets (>&2, >&1) start with '&' and are excluded by the target char class.
_REDIR_TARGET_RE = re.compile(r'(?:\d*>>?|<)\s*("[^"]*"|\'[^\']*\'|[^\s|&;<>]+)')


def is_tmp_safe(raw_segment):
    """Return True only if raw_segment is a safe command scoped entirely to a
    safe scratch root (/tmp or the scratchpad).

    Operates on the RAW (un-normalized) segment so that redirect targets — which
    normalize_command strips away — are still inspected. Conservative by design:
    any ambiguity (unknown verb, relative path, '..', subshell, path outside
    /tmp) returns False so the command falls through to a normal prompt rather
    than being auto-approved.
    """
    s = raw_segment.strip()
    if not s:
        return False
    # Subshells / command substitution can smuggle arbitrary commands.
    if '$(' in s or '`' in s or '${' in s:
        return False

    s = strip_keyword_prefix(s)
    s = strip_env_vars(s)

    # Every redirection target must itself be under /tmp (catches `> /etc/passwd`).
    for m in _REDIR_TARGET_RE.finditer(s):
        tgt = m.group(1).strip('"\'')
        if tgt.startswith('&'):
            continue
        if '..' in tgt or not is_within_safe_root(tgt):
            return False

    cleaned = strip_redirections(s)
    try:
        tokens = shlex.split(cleaned)
    except ValueError:
        return False
    if not tokens:
        return False

    verb = tokens[0]
    if '/' in verb:  # absolute/explicit binary path — don't auto-approve exec
        return False

    is_literal = verb in SAFE_TMP_LITERAL_VERBS
    if not is_literal and verb not in SAFE_TMP_FILE_VERBS:
        return False

    has_tmp_path = False
    for tok in tokens[1:]:
        if tok.startswith('-'):
            continue  # flag
        if '..' in tok:
            return False
        if is_literal:
            continue  # args are data, not paths
        if tok.startswith('/') or tok.startswith('~'):
            if is_within_safe_root(tok):
                has_tmp_path = True
                continue
            return False  # absolute path outside the safe roots
        # Relative path for a file verb — cwd is unknown to the hook, can't
        # prove it's under a safe root, so refuse to auto-approve.
        return False

    if not has_tmp_path:
        # Literal verbs (echo/printf) only "operate on /tmp" via a redirect.
        for m in _REDIR_TARGET_RE.finditer(s):
            tgt = m.group(1).strip('"\'')
            if not tgt.startswith('&') and is_within_safe_root(tgt):
                has_tmp_path = True
                break

    return has_tmp_path


def decompose_pairs(command):
    """Like decompose_command, but return (raw_segment, normalized) pairs.

    The raw segment is needed for is_tmp_safe (redirect targets survive only in
    the raw form); the normalized form is used for allow/deny pattern matching.
    """
    pairs = []
    for seg in split_on_operators(command):
        for sub in extract_subshells(seg):
            for ss in split_on_operators(sub):
                norm = normalize_command(ss)
                if norm:
                    pairs.append((ss, norm))
        norm = normalize_command(seg)
        if norm:
            pairs.append((seg, norm))
    return [
        (raw, norm) for (raw, norm) in pairs
        if not is_shell_structural(norm) and not is_standalone_assignment(norm)
    ]


# Side-effect-free shell builtins/tests that are safe as segments of a
# compound command (poll loops like `until [ -s f ]; do sleep 3; done`).
# `[`/`test` only evaluate conditions; `true`/`:` do nothing. Allowlist
# patterns can't express `[` reliably (glob bracket semantics), so these
# are recognized here instead.
_SAFE_BUILTIN_RE = re.compile(r'^(true|:)$|^(\[|test)\s')


def is_safe_builtin(cmd):
    """Return True for side-effect-free condition/no-op segments.

    Rejects any command substitution inside the test expression, since
    that could smuggle arbitrary execution.
    """
    if '$(' in cmd or '`' in cmd:
        return False
    return bool(_SAFE_BUILTIN_RE.match(cmd))


def decide(command, settings):
    """Make a permission decision for a compound command.

    Returns:
        ("allow", reason) if all sub-commands match allow patterns
        ("deny", reason) if any sub-command matches a deny pattern
        (None, None) if we should fall through to normal prompting
    """
    if not command or not command.strip():
        return None, None

    permissions = settings.get("permissions", {})
    allow_patterns = parse_bash_patterns(permissions.get("allow", []))
    deny_patterns = parse_bash_patterns(permissions.get("deny", []))

    sub_pairs = decompose_pairs(command)
    if not sub_pairs:
        return None, None

    # Check deny first — deny always wins, even for /tmp-scoped commands.
    for raw, cmd in sub_pairs:
        if command_matches_pattern(cmd, deny_patterns):
            return "deny", f"Sub-command '{cmd}' matches deny pattern"

    # Allow only if EVERY sub-command is either an allow-pattern match or a
    # safe command scoped entirely to /tmp.
    all_allowed = True
    for raw, cmd in sub_pairs:
        if command_matches_pattern(cmd, allow_patterns):
            continue
        if is_safe_builtin(cmd):
            continue
        if is_tmp_safe(raw):
            continue
        all_allowed = False
        break

    if all_allowed:
        return "allow", "All sub-commands match allow patterns or are /tmp-scoped"

    return None, None


_log_lines = []


def _verbose_enabled():
    """Check if verbose logging is enabled.

    Controlled by SMART_APPROVE_VERBOSE env var:
      "1", "true", "yes" → enabled
      "0", "false", "no", unset → disabled
    """
    return os.environ.get("SMART_APPROVE_VERBOSE", "").lower() in ("1", "true", "yes")


def log(msg):
    """Collect verbose log line when enabled."""
    if _verbose_enabled():
        _log_lines.append(msg)


def _build_reason(reason):
    """Build the permissionDecisionReason, appending verbose logs if any."""
    if not _log_lines:
        return reason
    verbose = " | ".join(_log_lines)
    if reason:
        return f"{reason} | {verbose}"
    return verbose


def is_within_tmp(file_path):
    """Return True if file_path resolves to a location inside /tmp.

    Uses realpath so that symlinks and ".." traversal cannot smuggle a path
    that looks like /tmp/... but actually points elsewhere.
    """
    try:
        resolved = os.path.realpath(os.path.expanduser(file_path))
    except (OSError, ValueError):
        return False
    tmp_root = os.path.realpath("/tmp")
    return resolved == tmp_root or resolved.startswith(tmp_root + os.sep)


def scratchpad_root():
    """Return the resolved scratchpad root (honors SCRATCHPAD_ROOT env)."""
    root = os.environ.get("SCRATCHPAD_ROOT") or os.path.expanduser(
        "~/.claude/scratchpad"
    )
    return os.path.realpath(root)


def is_within_scratchpad(file_path):
    """Return True if file_path resolves to a location inside the scratchpad.

    The scratchpad exists precisely so work can be offloaded out of the
    context window; prompting for its reads/writes defeats that purpose.
    Same realpath discipline as is_within_tmp.
    """
    try:
        resolved = os.path.realpath(os.path.expanduser(file_path))
    except (OSError, ValueError):
        return False
    root = scratchpad_root()
    return resolved == root or resolved.startswith(root + os.sep)


def is_within_safe_root(file_path):
    """Return True if file_path is inside any auto-approved scratch area."""
    return is_within_tmp(file_path) or is_within_scratchpad(file_path)


def main():
    try:
        input_data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        log("no valid JSON on stdin, skipping")
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")

    # Auto-allow Read/Write/Edit operations inside /tmp or the scratchpad.
    # These are scratch files with no security impact — the scratchpad exists
    # to offload work out of the context window, so prompting for it defeats
    # its purpose.
    if tool_name in ("Read", "Write", "Edit", "MultiEdit", "NotebookEdit"):
        file_path = input_data.get("tool_input", {}).get("file_path", "")
        if file_path and is_within_safe_root(file_path):
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": _build_reason(
                        f"{tool_name} target is inside /tmp or the scratchpad"
                    ),
                }
            }
            json.dump(output, sys.stdout)
            sys.stdout.write("\n")
        # else: silent exit — fall through to normal prompting
        sys.exit(0)

    if tool_name != "Bash":
        log(f"tool={tool_name}, not Bash — skipping")
        sys.exit(0)

    command = input_data.get("tool_input", {}).get("command", "")
    if not command:
        log("empty command, skipping")
        sys.exit(0)

    cmd_preview = command[:80].replace('\n', '\\n')
    log(f"checking: {cmd_preview}{'...' if len(command) > 80 else ''}")

    settings_path = os.environ.get("CLAUDE_SETTINGS_PATH")
    settings = load_merged_settings(settings_path)

    sub_commands = decompose_command(command)
    log(f"sub-commands: {sub_commands[:5]}{'...' if len(sub_commands) > 5 else ''}")

    decision, reason = decide(command, settings)

    log(f"decision={decision or 'passthrough'} reason={reason or 'no pattern matched'}")

    if decision is not None:
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": _build_reason(reason),
            }
        }
        json.dump(output, sys.stdout)
        sys.stdout.write("\n")
    # else: silent exit — fall through to normal prompting


if __name__ == "__main__":
    main()
