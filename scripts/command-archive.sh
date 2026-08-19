#!/usr/bin/env bash
# command-archive.sh — park rarely-used slash commands without deleting them.
#
# Every command's frontmatter loads into every session's context (~113 commands
# ≈ 3.6k tokens). Archiving moves a command's .md out of ~/.claude/commands/ into
# ~/.claude/commands-archive/ (preserving its subpath) so it stops loading; restore
# puts it back exactly where it was. Nothing is ever deleted.
#
# Usage:
#   command-archive.sh usage [--days N]   # rank commands by invocations (tracking data, default 90 days)
#   command-archive.sh archive <name>...  # move command(s) to the archive
#   command-archive.sh restore <name>...  # move command(s) back
#   command-archive.sh list               # what's currently archived

set -euo pipefail

CMD_DIR="${HOME}/.claude/commands"
ARCHIVE_DIR="${HOME}/.claude/commands-archive"
TRACKING_DIR="${HOME}/.claude/tracking"

mkdir -p "${ARCHIVE_DIR}"

find_command_file() {
  # $1 = command name, $2 = root dir. Prints the file path or nothing.
  local name="$1" root="$2"
  find "${root}" -name "${name}.md" -type f 2>/dev/null | head -1
}

case "${1:-}" in
  usage)
    days=90
    [[ "${2:-}" == "--days" && -n "${3:-}" ]] && days="$3"
    cutoff=$(date -v-"${days}"d +%Y-%m-%d 2>/dev/null || date -d "-${days} days" +%Y-%m-%d)

    # Invocation counts from daily tracking files within the window.
    counts_json=$(find "${TRACKING_DIR}" -maxdepth 1 -name '20*.json' -newermt "${cutoff}" -print0 2>/dev/null \
      | xargs -0 cat 2>/dev/null \
      | jq -s '[.[][] | select(.status=="started") | .command] | group_by(.) | map({command: .[0], count: length}) | sort_by(-.count)')

    # Commands with zero invocations in the window.
    used=$(printf '%s' "${counts_json}" | jq -r '.[].command')
    unused=()
    while IFS= read -r f; do
      name=$(basename "${f}" .md)
      grep -qxF "${name}" <<< "${used}" || unused+=("${name}")
    done < <(find "${CMD_DIR}" -name '*.md' -type f 2>/dev/null)

    jq -n --argjson used "${counts_json}" \
          --argjson unused "$(printf '%s\n' "${unused[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
          --arg days "${days}" \
      '{window_days: ($days|tonumber), used: $used, never_invoked: $unused,
        hint: "archive never_invoked candidates with: command-archive.sh archive <name>..."}'
    ;;

  archive)
    shift
    [[ $# -gt 0 ]] || { echo '{"status":"error","message":"no command names given"}'; exit 1; }
    results=()
    for name in "$@"; do
      src=$(find_command_file "${name}" "${CMD_DIR}")
      if [[ -z "${src}" ]]; then
        results+=("{\"command\":\"${name}\",\"status\":\"not_found\"}")
        continue
      fi
      rel="${src#"${CMD_DIR}"/}"
      dest="${ARCHIVE_DIR}/${rel}"
      mkdir -p "$(dirname "${dest}")"
      mv "${src}" "${dest}"
      results+=("{\"command\":\"${name}\",\"status\":\"archived\",\"path\":\"${dest}\"}")
    done
    printf '%s\n' "${results[@]}" | jq -s '{status:"ok", results:., note:"takes effect in NEW sessions; restore anytime with command-archive.sh restore <name>"}'
    ;;

  restore)
    shift
    [[ $# -gt 0 ]] || { echo '{"status":"error","message":"no command names given"}'; exit 1; }
    results=()
    for name in "$@"; do
      src=$(find_command_file "${name}" "${ARCHIVE_DIR}")
      if [[ -z "${src}" ]]; then
        results+=("{\"command\":\"${name}\",\"status\":\"not_in_archive\"}")
        continue
      fi
      rel="${src#"${ARCHIVE_DIR}"/}"
      dest="${CMD_DIR}/${rel}"
      mkdir -p "$(dirname "${dest}")"
      mv "${src}" "${dest}"
      results+=("{\"command\":\"${name}\",\"status\":\"restored\",\"path\":\"${dest}\"}")
    done
    printf '%s\n' "${results[@]}" | jq -s '{status:"ok", results:.}'
    ;;

  list)
    find "${ARCHIVE_DIR}" -name '*.md' -type f 2>/dev/null \
      | sed "s|^${ARCHIVE_DIR}/||" \
      | jq -R . | jq -s '{status:"ok", archived:., count:length}'
    ;;

  *)
    echo '{"status":"error","message":"usage: command-archive.sh usage [--days N] | archive <name>... | restore <name>... | list"}'
    exit 1
    ;;
esac
