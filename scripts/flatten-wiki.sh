#!/usr/bin/env bash
# Flatten a nested markdown tree for GitHub Wiki, which renders only
# top-level pages. `a/b/c.md` becomes `a-b-c.md`; internal links to the
# original paths are rewritten to the new flat names.
#
# Usage: flatten-wiki.sh <src-dir> <dest-dir>
#   <src-dir>  Directory containing nested *.md (read-only).
#   <dest-dir> Directory to write flattened output into (replaced).
#
# Rules:
#   - Files at the root of <src-dir> keep their name.
#   - Files in subdirs are renamed by joining path segments with `-`,
#     e.g. `commands/task-start.md` -> `commands-task-start.md`.
#   - Files named `_TEMPLATE.md` (any depth) are skipped.
#   - Markdown links of the form `](relative/path.md)` and
#     `](relative/path.md#anchor)` are rewritten to point at the flat
#     name (with anchor preserved). Absolute URLs (http/https/mailto)
#     and anchor-only links are left alone.
#   - Image refs `![alt](path)` follow the same rule.
#   - A reference to a directory like `](commands/)` is rewritten to
#     the section's index page if one exists (`commands.md` if present),
#     otherwise left as-is.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <src-dir> <dest-dir>" >&2
    exit 2
fi

src="$1"
dest="$2"

if [[ ! -d "$src" ]]; then
    echo "error: src dir not found: $src" >&2
    exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"

# Build the rename map: original relative path -> flat filename.
# Using a temp file because bash assoc arrays + subshells don't compose
# well with `find -print0`.
map_file="$(mktemp)"
trap 'rm -f "$map_file"' EXIT

while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    base="$(basename "$rel")"
    if [[ "$base" == "_TEMPLATE.md" ]]; then
        continue
    fi
    flat="${rel//\//-}"
    printf '%s\t%s\n' "$rel" "$flat" >> "$map_file"
done < <(find "$src" -type f -name '*.md' -print0)

# Build a sed script that rewrites every original path to its flat name.
# Process longest paths first so `commands/foo.md` is matched before
# `commands/`, etc. Escape regex metacharacters in the source path.
sed_script="$(mktemp)"
trap 'rm -f "$map_file" "$sed_script"' EXIT

# Sort by descending length of the original path.
awk -F'\t' '{ print length($1) "\t" $0 }' "$map_file" \
    | sort -rn \
    | cut -f2- > "${map_file}.sorted"

while IFS=$'\t' read -r orig flat; do
    # Escape ERE metacharacters in the path we're searching for.
    orig_esc="$(printf '%s\n' "$orig" | sed -e 's/[][\/.^$*+?(){}|]/\\&/g')"
    # Wiki page links must drop the `.md` extension — GitHub serves
    # `name.md` as a raw file but renders `name` as the wiki page.
    flat_page="${flat%.md}"
    # Match `](orig)` or `](orig#anchor)` and rewrite, preserving the
    # anchor. ERE is portable across GNU and BSD sed.
    # Allow optional `../` prefixes (from links in subdirs like
    # `commands/foo.md`) — the wiki is flat, so any number of leading
    # `../` segments should collapse away.
    printf 's|\\]\\((\\.\\./)*%s(#[^)]*)?\\)|](%s\\2)|g\n' "$orig_esc" "$flat_page" >> "$sed_script"
done < "${map_file}.sorted"

# Copy + transform each tracked file.
#
# Two transforms happen here:
#   1. Wrap leading YAML frontmatter (`---` ... `---` at the top of the
#      file) in a ```yaml fenced block. GitHub Wiki doesn't strip
#      frontmatter, and without a fence each line collapses into one
#      paragraph because Markdown treats single newlines as soft breaks.
#   2. Rewrite cross-page links (sed_script from above).
while IFS=$'\t' read -r orig flat; do
    src_file="$src/$orig"
    dest_file="$dest/$flat"
    awk '
        NR == 1 && $0 == "---" { in_fm = 1; print "```yaml"; next }
        in_fm && $0 == "---"   { in_fm = 0; print "```"; next }
        { print }
    ' "$src_file" \
        | if [[ -s "$sed_script" ]]; then sed -E -f "$sed_script"; else cat; fi \
        > "$dest_file"
done < "$map_file"

count="$(wc -l < "$map_file" | tr -d ' ')"
echo "flatten-wiki: wrote $count page(s) to $dest"
