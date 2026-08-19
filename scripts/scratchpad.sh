#!/usr/bin/env bash
# scratchpad.sh — session-local tiered-memory scratchpad for long-running agents.
#
# Implements the "Wiki-Backed Tiered Agent Memory" decision:
#   ~/projects/wiki/decisions/wiki-backed-agent-memory.md
#
# Purpose: offload conversation detail out of resident context so it survives
# compaction. Each note keeps a one-line summary (the pointer the compaction
# summary should carry); the body is recalled on demand. Bounded growth via prune.
#
# Notes live under:  ~/.claude/scratchpad/<session-id>/
#   <id>.md        one note (frontmatter + body); one detail per file
#   MANIFEST.md    one line per note ("<id> — <summary>"); the only thing
#                  resident context needs to hold
#
# Commands (all emit JSON on stdout):
#   write   --summary "<line>" [--tags "a,b"] [--body "<text>" | --file <path>]
#   list                                   # dump the manifest as JSON
#   recall  --id <id>                      # pull one note's full body back
#   promote --id <id>                      # copy to wiki staging/ (graduation)
#   prune   [--dry-run] [--ttl-days N] [--max-notes N] [--max-sessions N]
#
# Session id: --session <id> overrides; else $CLAUDE_SESSION_ID; else "default".

set -euo pipefail

ROOT="${SCRATCHPAD_ROOT:-${HOME}/.claude/scratchpad}"
WIKI_STAGING="${WIKI_STAGING:-${HOME}/projects/wiki/staging}"

TTL_DAYS_DEFAULT=7
MAX_NOTES_DEFAULT=200
MAX_SESSIONS_DEFAULT=50

# ---- arg parsing -----------------------------------------------------------
cmd="${1:-}"; shift || true
# Session resolution: --session flag (parsed below) > $CLAUDE_SESSION_ID >
# .current-session (written by the SessionStart hook) > "default".
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
  session="${CLAUDE_SESSION_ID}"
elif [[ -f "${ROOT}/.current-session" ]]; then
  session="$(cat "${ROOT}/.current-session")"
else
  session="default"
fi
summary="" ; tags="" ; body="" ; file="" ; id=""
dry_run=0
ttl_days="${TTL_DAYS_DEFAULT}"
max_notes="${MAX_NOTES_DEFAULT}"
max_sessions="${MAX_SESSIONS_DEFAULT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) session="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --tags) tags="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --id) id="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --ttl-days) ttl_days="$2"; shift 2 ;;
    --max-notes) max_notes="$2"; shift 2 ;;
    --max-sessions) max_sessions="$2"; shift 2 ;;
    *) shift ;;
  esac
done

sdir="${ROOT}/${session}"
manifest="${sdir}/MANIFEST.md"

json_err() { printf '{"ok":false,"error":%s}\n' "$(json_str "$1")"; exit 1; }
# minimal JSON string escaper (quotes, backslashes, newlines, tabs)
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "${cmd}" in
  write)
    [[ -n "${summary}" ]] || json_err "write requires --summary"
    mkdir -p "${sdir}"
    if [[ -n "${file}" ]]; then
      [[ -f "${file}" ]] || json_err "file not found: ${file}"
      body="$(cat "${file}")"
    fi
    id="n$(now_epoch)$$"
    note="${sdir}/${id}.md"
    {
      printf -- '---\n'
      printf 'id: %s\n' "${id}"
      printf 'created: %s\n' "$(now_iso)"
      printf 'summary: %s\n' "${summary}"
      printf 'tags: [%s]\n' "${tags}"
      printf 'graduated: false\n'
      printf -- '---\n\n'
      printf '%s\n' "${body}"
    } > "${note}"
    printf -- '- %s — %s\n' "${id}" "${summary}" >> "${manifest}"
    printf '{"ok":true,"id":%s,"session":%s,"summary":%s,"path":%s,"hint":"carry this summary into the compaction summary; recall with: scratchpad.sh recall --id %s"}\n' \
      "$(json_str "${id}")" "$(json_str "${session}")" "$(json_str "${summary}")" "$(json_str "${note}")" "${id}"
    ;;

  list)
    if [[ ! -f "${manifest}" ]]; then
      printf '{"ok":true,"session":%s,"count":0,"notes":[]}\n' "$(json_str "${session}")"; exit 0
    fi
    # emit manifest lines as a JSON array of {id,summary}
    printf '{"ok":true,"session":%s,"notes":[' "$(json_str "${session}")"
    first=1
    while IFS= read -r line; do
      [[ "${line}" =~ ^-\ (n[0-9]+.*)\ —\ (.*)$ ]] || continue
      nid="${BASH_REMATCH[1]}"; nsum="${BASH_REMATCH[2]}"
      [[ ${first} -eq 1 ]] || printf ','
      printf '{"id":%s,"summary":%s}' "$(json_str "${nid}")" "$(json_str "${nsum}")"
      first=0
    done < "${manifest}"
    printf ']}\n'
    ;;

  recall)
    [[ -n "${id}" ]] || json_err "recall requires --id"
    note="${sdir}/${id}.md"
    [[ -f "${note}" ]] || json_err "note not found: ${id}"
    touch "${note}"   # bump access time (LRU signal for prune)
    printf '{"ok":true,"id":%s,"body":%s}\n' "$(json_str "${id}")" "$(json_str "$(cat "${note}")")"
    ;;

  promote)
    [[ -n "${id}" ]] || json_err "promote requires --id"
    note="${sdir}/${id}.md"
    [[ -f "${note}" ]] || json_err "note not found: ${id}"
    mkdir -p "${WIKI_STAGING}/scratchpad"
    dest="${WIKI_STAGING}/scratchpad/${session}-${id}.md"
    cp "${note}" "${dest}"
    # mark graduated so prune leaves the local copy alone until TTL
    sed -i.bak 's/^graduated: false/graduated: true/' "${note}" && rm -f "${note}.bak"
    printf '{"ok":true,"id":%s,"staged":%s,"note":"review + promote via scripts/wiki-staging.py"}\n' \
      "$(json_str "${id}")" "$(json_str "${dest}")"
    ;;

  prune)
    [[ -d "${ROOT}" ]] || { printf '{"ok":true,"removed_sessions":[],"removed_notes":[],"dry_run":%s}\n' "${dry_run}"; exit 0; }
    cutoff=$(( $(now_epoch) - ttl_days*86400 ))
    removed_sessions=""; removed_notes=""
    # 1. TTL: whole session dirs older than cutoff (by mtime)
    for d in "${ROOT}"/*/; do
      [[ -d "${d}" ]] || continue
      mt=$(stat -f %m "${d}" 2>/dev/null || stat -c %Y "${d}")
      if [[ "${mt}" -lt "${cutoff}" ]]; then
        removed_sessions="${removed_sessions} ${d}"
        [[ ${dry_run} -eq 1 ]] || rm -rf "${d}"
      fi
    done
    # 2. Per-session count cap: evict oldest-accessed notes beyond max_notes
    for d in "${ROOT}"/*/; do
      [[ -d "${d}" ]] || continue
      # list notes oldest-access-first
      mapfile -t notes < <(ls -tur "${d}"*.md 2>/dev/null || true)
      cnt=${#notes[@]}
      if [[ ${cnt} -gt ${max_notes} ]]; then
        evict=$(( cnt - max_notes ))
        for ((i=0; i<evict; i++)); do
          removed_notes="${removed_notes} ${notes[$i]}"
          [[ ${dry_run} -eq 1 ]] || rm -f "${notes[$i]}"
        done
      fi
    done
    # 3. Global session-dir cap: keep newest max_sessions, drop the rest
    mapfile -t sdirs < <(ls -dt "${ROOT}"/*/ 2>/dev/null || true)
    if [[ ${#sdirs[@]} -gt ${max_sessions} ]]; then
      for ((i=max_sessions; i<${#sdirs[@]}; i++)); do
        removed_sessions="${removed_sessions} ${sdirs[$i]}"
        [[ ${dry_run} -eq 1 ]] || rm -rf "${sdirs[$i]}"
      done
    fi
    to_json_arr() { local out="" x; for x in $1; do out="${out},$(json_str "${x}")"; done; printf '[%s]' "${out#,}"; }
    printf '{"ok":true,"dry_run":%s,"ttl_days":%s,"max_notes":%s,"max_sessions":%s,"removed_sessions":%s,"removed_notes":%s}\n' \
      "${dry_run}" "${ttl_days}" "${max_notes}" "${max_sessions}" \
      "$(to_json_arr "${removed_sessions}")" "$(to_json_arr "${removed_notes}")"
    ;;

  *)
    json_err "usage: scratchpad.sh {write|list|recall|promote|prune} [opts]"
    ;;
esac
