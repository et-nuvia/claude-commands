#!/usr/bin/env bash
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/release-notes-standardize.sh [--json|--raw] [--version <vX.Y.Z>] [--all]
#
# Gathers everything needed to rewrite a release-notes file in the house
# non-technical format, then hands it to the LLM to write the prose. The script
# does the deterministic half: pick the version, resolve its commit range, map
# every commit to its GITHUB USERNAME (not the git author name), and read the
# current file.
#
# WHY GITHUB USERNAMES: a git author name is whatever the contributor set
# locally, and one person routinely has several (a personal name for local
# commits, a bot-style name for GitHub squash merges — same email). The GitHub login
# is the single stable identity, so it is resolved from the API per commit and
# only falls back to the git name when the API cannot answer (unpushed commit,
# no `gh` auth, or a commit with no linked GitHub account).
#
# Default with no flags: the MOST RECENT version only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output-framework.sh
source "${SCRIPT_DIR}/lib/output-framework.sh"

OUTPUT_MODE="json"
SECTION="release-notes-standardize"
REQ_VERSION=""
DO_ALL=false
NOTES_DIR="docs/release_notes"

log() { [[ "$OUTPUT_MODE" == "raw" ]] && echo "$@" >&2 || true; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
        --toon) OUTPUT_MODE="json"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --version) REQ_VERSION="${2:-}"; shift 2 ;;
        --all) DO_ALL=true; shift ;;
        --notes-dir) NOTES_DIR="${2:-}"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--json|--raw] [--version <vX.Y.Z>] [--all] [--notes-dir <path>]" >&2
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || \
    exit_with_json "error" "Not a git repository — run from a project checkout" ""

[[ -d "$NOTES_DIR" ]] || \
    exit_with_json "error" "No ${NOTES_DIR}/ directory in this repository" \
        "Pass --notes-dir if this project keeps release notes elsewhere"

# ---------------------------------------------------------------- pick version
# Order by semver so "most recent" means highest version, not newest mtime — a
# rewritten older file must not be mistaken for the latest release.
mapfile -t ALL_VERSIONS < <(
    find "$NOTES_DIR" -maxdepth 1 -name 'v*.md' -exec basename {} .md \; 2>/dev/null \
        | sort -V
)

[[ ${#ALL_VERSIONS[@]} -gt 0 ]] || \
    exit_with_json "error" "No release-notes files found in ${NOTES_DIR}/" ""

TARGETS=()
if [[ "$DO_ALL" == "true" ]]; then
    TARGETS=("${ALL_VERSIONS[@]}")
elif [[ -n "$REQ_VERSION" ]]; then
    # Accept both "0.3.0" and "v0.3.0".
    [[ "$REQ_VERSION" == v* ]] || REQ_VERSION="v${REQ_VERSION}"
    if [[ ! -f "${NOTES_DIR}/${REQ_VERSION}.md" ]]; then
        exit_with_json "error" "No notes file ${NOTES_DIR}/${REQ_VERSION}.md" \
            "Available: ${ALL_VERSIONS[*]}"
    fi
    TARGETS=("$REQ_VERSION")
else
    TARGETS=("${ALL_VERSIONS[-1]}")
fi

# ------------------------------------------------------- github username lookup
# Cache by SHA so a range with repeated authors costs one API call each.
declare -A GH_LOGIN_CACHE=()
HAVE_GH=false
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && HAVE_GH=true

github_login_for() {
    local sha="$1" login=""
    if [[ -n "${GH_LOGIN_CACHE[$sha]:-}" ]]; then
        printf '%s' "${GH_LOGIN_CACHE[$sha]}"; return
    fi
    if [[ "$HAVE_GH" == "true" ]]; then
        # .author.login is the GitHub account linked to the commit; it is null
        # for commits whose email matches no account.
        login=$(gh api "repos/{owner}/{repo}/commits/${sha}" \
                    --jq '.author.login // empty' 2>/dev/null || true)
    fi
    if [[ -z "$login" ]]; then
        # Fall back to the git author name, flagged so the LLM can tell the
        # difference rather than silently presenting it as a GitHub handle.
        login="$(git log -1 --format='%an' "$sha" 2>/dev/null)"
        [[ -n "$login" ]] && login="${login} (git name — no GitHub account resolved)"
    fi
    GH_LOGIN_CACHE[$sha]="$login"
    printf '%s' "$login"
}

# ------------------------------------------------------------------ build output
json_str() { printf '%s' "$1" | jq -Rs .; }

versions_json="["
first_v=true
SHA_CHECKED=0
UNRESOLVED_SHAS=()
for ver in "${TARGETS[@]}"; do
    file="${NOTES_DIR}/${ver}.md"
    log "Processing ${ver} (${file})"

    # Commit range: previous tag (by semver) .. this tag. Falls back to the
    # whole history for the earliest release.
    prev_ver=""
    for candidate in "${ALL_VERSIONS[@]}"; do
        [[ "$candidate" == "$ver" ]] && break
        prev_ver="$candidate"
    done

    range=""
    if git rev-parse -q --verify "refs/tags/${ver}" >/dev/null 2>&1; then
        if [[ -n "$prev_ver" ]] && git rev-parse -q --verify "refs/tags/${prev_ver}" >/dev/null 2>&1; then
            range="${prev_ver}..${ver}"
        else
            range="$ver"
        fi
    fi

    commits_json="[]"
    if [[ -n "$range" ]]; then
        commits_json="["
        first_c=true
        while IFS='|' read -r sha subject; do
            [[ -z "$sha" ]] && continue
            # Drop commits that ONLY touch release notes, whatever their subject
            # prefix. The `^docs(release)` grep below catches the conventional
            # ones, but a release-notes edit committed under any other prefix
            # would otherwise reach the caller and get written up as a change --
            # a release-notes file must never describe edits to release notes.
            if ! git show --name-only --format= "$sha" 2>/dev/null \
                | grep -qv -e '^docs/release_notes/' -e '^[[:space:]]*$'; then
                continue
            fi
            gh_login="$(github_login_for "$sha")"
            git_name="$(git log -1 --format='%an' "$sha")"
            pr=$(printf '%s' "$subject" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
            # Resolve-check every sha HERE so the caller never has to shell out to
            # verify hashes it is about to transcribe. A per-batch `for sha in ...;
            # do git cat-file -e ...; done` loop in the caller can never be
            # auto-approved (loops defeat static safety analysis), so it produced a
            # permission prompt for every batch. Doing it in-script makes the whole
            # verification a side effect of the one allowlisted invocation.
            sha_verified=true
            git cat-file -e "${sha}^{commit}" 2>/dev/null || {
                sha_verified=false
                UNRESOLVED_SHAS+=("${ver}:${sha}")
            }
            SHA_CHECKED=$((SHA_CHECKED + 1))
            [[ "$first_c" == "true" ]] && first_c=false || commits_json+=","
            commits_json+=$(cat <<EOF
{"sha": $(json_str "$sha"), "sha_verified": ${sha_verified}, "github_username": $(json_str "$gh_login"), "git_author_name": $(json_str "$git_name"), "subject": $(json_str "$subject"), "pr": $(json_str "$pr")}
EOF
)
            # NOTE: no %b — a multi-line commit body would spill across lines and
            # corrupt this IFS read loop. The subject carries what the notes need.
            #
            # docs(release) commits are excluded: "release notes were generated" is
            # self-evident in a release-notes file and only adds noise.
        done < <(git log "$range" --no-merges --invert-grep --grep='^docs(release)' --format='%h|%s' 2>/dev/null)
        commits_json+="]"
    fi

    current="$(cat "$file" 2>/dev/null || true)"
    rel_date="$(grep -m1 -oE '\*\*Release Date:\*\* *[0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
    [[ -n "$rel_date" ]] || rel_date="$(git log -1 --format=%cs "refs/tags/${ver}" 2>/dev/null || true)"

    [[ "$first_v" == "true" ]] && first_v=false || versions_json+=","
    versions_json+=$(cat <<EOF
{"version": $(json_str "$ver"), "filepath": $(json_str "$file"), "release_date": $(json_str "$rel_date"), "commit_range": $(json_str "$range"), "commits": ${commits_json}, "current_content": $(json_str "$current")}
EOF
)
done
versions_json+="]"

selection="most_recent"
[[ "$DO_ALL" == "true" ]] && selection="all"
[[ -n "$REQ_VERSION" ]] && selection="explicit"

exit_with_json "success" "Release-notes data collected for ${#TARGETS[@]} version(s)" \
    "Rewrite each file in the house non-technical format, then commit" \
    "\"selection\": $(json_str "$selection")," \
    "\"github_lookup_available\": ${HAVE_GH}," \
    "\"notes_dir\": $(json_str "$NOTES_DIR")," \
    "\"shas_verified\": ${SHA_CHECKED}," \
    "\"shas_unresolved\": $(printf '%s\n' "${UNRESOLVED_SHAS[@]+"${UNRESOLVED_SHAS[@]}"}" | jq -Rs 'split("\n") | map(select(length>0))')," \
    "\"available_versions\": $(printf '%s\n' "${ALL_VERSIONS[@]}" | jq -Rs 'split("\n") | map(select(length>0))')," \
    "\"versions\": ${versions_json}"
