#!/usr/bin/env bash
#
# transcript-archive.sh — compress Claude Code conversation transcripts into
# solid weekly archives so history survives instead of being pruned.
#
# WHY: Claude Code deletes transcripts older than settings.json
# `cleanupPeriodDays` (default 30). Months of history are lost silently, which
# also breaks any retrospective analysis (see make-target-scan.sh). This keeps a
# permanent compressed copy while letting Claude Code manage the live directory.
#
# WHY SOLID PER-BUCKET TARS: transcripts are extremely repetitive both internally
# and across sessions (same system prompt, same CLAUDE.md, same file contents
# re-read). Compressing them TOGETHER in one stream lets the compressor match
# across files, which is where nearly all of the win comes from — one archive per
# bucket, not per file. Per-file compression would give a fraction of this.
# Measured on the real corpus, monthly: 606 MB -> 68 MB (8.9x).
#
# WHY WEEKLY AND NOT MONTHLY: bucket size is a tradeoff, not a free choice. A
# smaller bucket means less to recompress each night (the current bucket always
# goes dirty), but fewer files to match against, so the ratio drops. Weekly keeps
# the nightly rebuild bounded — a month reached 580 MB and 5.5 min by month end.
#
# WHY zstd --ultra -22 --long=31 AND NOT xz -9e: at small sizes xz wins slightly
# (47 MB -> 6.74 MB vs zstd's 6.92 MB), but xz's dictionary caps at 64 MB, so on
# a realistic multi-hundred-MB archive it can no longer match between distant
# files. At 168 MB zstd's 2 GB window overtakes it (23.7 MB vs 24.2 MB) and the
# gap widens with size. zstd also decompresses ~10x faster.
#
# NOTE: a 2 GB window means `zstd -d` refuses the frame under its default 128 MB
# memory limit — decompression MUST pass --long=31. The restore/verify
# subcommands here do that; if you ever unpack one by hand, remember it.
#
# Buckets are ISO weeks, named like 2026-W31.
#
# Subcommands:
#   run [--age-days N] [--dry-run]  archive settled transcripts (default: run)
#   status                          what is archived, sizes, ratios, live usage
#   verify [BUCKET]                 test archive integrity (all, or 2026-W31)
#   restore BUCKET [DEST]           unpack one bucket's archive
#   rebucket                        rewrite existing archives into current buckets
#   prune --yes [--age-days N]      DELETE live originals already safely archived
#   install-cron                    install the nightly cron entry
#
set -euo pipefail

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
ARCHIVE_DIR="${CLAUDE_ARCHIVE_DIR:-${HOME}/.claude/archive/transcripts}"
INDEX="${ARCHIVE_DIR}/index.tsv"
# Files still being appended to would be archived mid-session and re-archived
# later; waiting until a transcript has been idle this long avoids the churn.
AGE_DAYS=2
DRY_RUN=0
ASSUME_YES=0
DEEP=0
PROJECT_FILTER_FIND=''
ZSTD_OPTS=(--ultra -22 --long=31 -T0)
ZSTD_DOPTS=(--long=31 --memory=2048MB)

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)]" "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v zstd >/dev/null || die "zstd not found (brew install zstd)"

SUB='run'
if [[ $# -gt 0 && "$1" != -* ]]; then SUB="$1"; shift; fi
MONTH_ARG=''
DEST_ARG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --age-days) AGE_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --deep) DEEP=1; shift ;;
    --project) PROJECT_FILTER_FIND="$2"; shift 2 ;;
    -h|--help) sed -n '3,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) if [[ -z "${MONTH_ARG}" ]]; then MONTH_ARG="$1"; else DEST_ARG="$1"; fi; shift ;;
  esac
done

mkdir -p "${ARCHIVE_DIR}"
touch "${INDEX}"

# index format: <relpath>\t<size>\t<mtime-epoch>\t<month>
indexed_key() { awk -F'\t' -v p="$1" '$1 == p { print $2"\t"$3 }' "${INDEX}"; }

archive_path() { printf '%s/%s.tar.zst' "${ARCHIVE_DIR}" "$1"; }

# Bucket by ISO week (%G-W%V), not month. Solid compression means the whole
# bucket is rewritten whenever anything lands in it, and the CURRENT bucket goes
# dirty on every run — so bucket size sets the recurring cost. A month grows to
# ~600 MB and 5.5 min of recompression by month end; a week stays bounded at
# roughly a seventh of that. Past buckets never go dirty either way.
# A transcript resumed in a later week is re-archived under the new week and the
# stale copy drops out of the old one when that bucket is next rebuilt.
file_bucket() { stat -f '%Sm' -t '%G-W%V' "$1"; }
file_size()  { stat -f '%z' "$1"; }
file_mtime() { stat -f '%m' "$1"; }

cmd_run() {
  local cutoff pending=() dirty_buckets=() relpath size mtime month key
  cutoff=$(( $(date +%s) - AGE_DAYS * 86400 ))

  while IFS= read -r f; do
    relpath="${f#"${PROJECTS_DIR}"/}"
    mtime="$(file_mtime "${f}")"
    [[ "${mtime}" -gt "${cutoff}" ]] && continue   # still hot, leave it
    size="$(file_size "${f}")"
    key="$(indexed_key "${relpath}")"
    [[ "${key}" == "${size}"$'\t'"${mtime}" ]] && continue   # unchanged
    pending+=("${relpath}")
    month="$(file_bucket "${f}")"
    dirty_buckets+=("${month}")
  done < <(find "${PROJECTS_DIR}" -name '*.jsonl' -type f)

  if [[ ${#pending[@]} -eq 0 ]]; then
    log "nothing to archive (all transcripts older than ${AGE_DAYS}d already archived)"
    return 0
  fi

  # shellcheck disable=SC2207
  dirty_buckets=($(printf '%s\n' "${dirty_buckets[@]}" | sort -u))
  log "${#pending[@]} transcript(s) to archive across ${#dirty_buckets[@]} bucket(s): ${dirty_buckets[*]}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '%s\n' "${pending[@]}"
    return 0
  fi

  local work
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN

  for month in "${dirty_buckets[@]}"; do
    local stage="${work}/${month}"
    mkdir -p "${stage}"
    local existing
    existing="$(archive_path "${month}")"

    # Rebuild the month from scratch: solid compression means the whole stream is
    # rewritten anyway, and unpacking first is what lets new files match against
    # the old ones. Old months never go dirty, so this cost is paid once.
    if [[ -f "${existing}" ]]; then
      log "${month}: unpacking existing archive to merge"
      zstd -d "${ZSTD_DOPTS[@]}" -c "${existing}" | tar -xf - -C "${stage}"
    fi

    local n=0
    for relpath in "${pending[@]}"; do
      [[ "$(file_bucket "${PROJECTS_DIR}/${relpath}")" == "${month}" ]] || continue
      # Project dirs start with "-Users-..." — every path-munging tool needs `--`
      # or it reads the leading dash as an option flag.
      mkdir -p "${stage}/$(dirname -- "${relpath}")"
      cp -p "${PROJECTS_DIR}/${relpath}" "${stage}/${relpath}"
      n=$(( n + 1 ))
    done

    log "${month}: compressing $(find "${stage}" -name '*.jsonl' | grep -c '') file(s) (${n} new)"
    local tmp_archive="${work}/${month}.tar.zst"
    # Sort members so byte-identical inputs produce a byte-identical archive,
    # and so same-project sessions land adjacent for better matching.
    ( cd "${stage}" && find . -name '*.jsonl' -type f | sort | tar -cf - -T - ) \
      | zstd "${ZSTD_OPTS[@]}" -q -o "${tmp_archive}"
    mv "${tmp_archive}" "$(archive_path "${month}")"

    # Only record the index once the archive is safely in place.
    for relpath in "${pending[@]}"; do
      local f="${PROJECTS_DIR}/${relpath}"
      [[ -f "${f}" ]] || continue
      [[ "$(file_bucket "${f}")" == "${month}" ]] || continue
      grep -v -F "${relpath}"$'\t' "${INDEX}" >"${INDEX}.new" 2>/dev/null || true
      mv "${INDEX}.new" "${INDEX}"
      printf '%s\t%s\t%s\t%s\n' "${relpath}" "$(file_size "${f}")" "$(file_mtime "${f}")" "${month}" >>"${INDEX}"
    done
  done
  log "done — see: $0 status"
}

cmd_status() {
  local live_bytes arch_bytes=0
  live_bytes="$(find "${PROJECTS_DIR}" -name '*.jsonl' -type f -exec stat -f '%z' {} + | awk '{s+=$1} END {print s+0}')"
  printf '%-10s %7s %12s %12s %7s\n' BUCKET FILES RAW_MB ARCHIVE_MB RATIO
  local a month files raw comp
  for a in "${ARCHIVE_DIR}"/*.tar.zst; do
    [[ -f "${a}" ]] || continue
    month="$(basename "${a}" .tar.zst)"
    files="$(awk -F'\t' -v m="${month}" '$4 == m' "${INDEX}" | grep -c '' || true)"
    raw="$(awk -F'\t' -v m="${month}" '$4 == m {s+=$2} END {print s+0}' "${INDEX}")"
    comp="$(stat -f '%z' "${a}")"
    arch_bytes=$(( arch_bytes + comp ))
    awk -v m="${month}" -v f="${files}" -v r="${raw}" -v c="${comp}" \
      'BEGIN { printf "%-10s %7s %12.1f %12.1f %6.1fx\n", m, f, r/1048576, c/1048576, (c>0 ? r/c : 0) }'
  done
  awk -v l="${live_bytes}" -v a="${arch_bytes}" \
    'BEGIN { printf "\nlive %s: %.0f MB\narchived total: %.0f MB\n", "'"${PROJECTS_DIR}"'", l/1048576, a/1048576 }'
  local unarchived
  unarchived="$(awk -F'\t' '{print $1}' "${INDEX}" | sort >"/tmp/.ta_idx.$$"; \
    find "${PROJECTS_DIR}" -name '*.jsonl' -type f | sed "s|^${PROJECTS_DIR}/||" | sort \
    | comm -23 - "/tmp/.ta_idx.$$" | grep -c '' || true)"
  rm -f "/tmp/.ta_idx.$$"
  printf 'live files not yet archived: %s (expected: those newer than --age-days)\n' "${unarchived}"
}

cmd_verify() {
  local rc=0 a month
  [[ -n "${MONTH_ARG}" ]] && MONTH_ARG="$(resolve_bucket "${MONTH_ARG}")"
  for a in "${ARCHIVE_DIR}"/*.tar.zst; do
    [[ -f "${a}" ]] || continue
    month="$(basename "${a}" .tar.zst)"
    [[ -n "${MONTH_ARG}" && "${month}" != "${MONTH_ARG}" ]] && continue
    if zstd -t "${ZSTD_DOPTS[@]}" -q "${a}" \
       && zstd -d "${ZSTD_DOPTS[@]}" -c "${a}" | tar -tf - >/dev/null; then
      printf 'ok   %s (%s files)\n' "${month}" \
        "$(zstd -d "${ZSTD_DOPTS[@]}" -c "${a}" | tar -tf - | grep -c '\.jsonl$' || true)"
    else
      printf 'FAIL %s\n' "${month}"; rc=1
    fi
  done
  return "${rc}"
}

cmd_restore() {
  [[ -n "${MONTH_ARG}" ]] || die "usage: $0 restore <YYYY-MM-DD|YYYY-W##> [dest]"
  local a dest bucket
  bucket="$(resolve_bucket "${MONTH_ARG}")"
  a="$(archive_path "${bucket}")"
  [[ -f "${a}" ]] || die "no archive for ${bucket} (resolved from '${MONTH_ARG}') — try: $0 find ${MONTH_ARG}"
  MONTH_ARG="${bucket}"
  dest="${DEST_ARG:-${PWD}/restored-${bucket}}"
  mkdir -p "${dest}"
  zstd -d "${ZSTD_DOPTS[@]}" -c "${a}" | tar -xf - -C "${dest}"
  log "restored ${MONTH_ARG} to ${dest}"
}

# Deleting live transcripts is what actually reclaims disk, but it is
# irreversible, so it never runs implicitly: an explicit subcommand, an explicit
# --yes, and every file re-verified present in its archive at the recorded size.
cmd_prune() {
  [[ "${ASSUME_YES}" -eq 1 ]] || die "prune deletes live transcripts — re-run with --yes"
  local cutoff deleted=0 freed=0 relpath month a members
  cutoff=$(( $(date +%s) - AGE_DAYS * 86400 ))
  declare -A month_members=()
  while IFS=$'\t' read -r relpath size mtime month; do
    local f="${PROJECTS_DIR}/${relpath}"
    [[ -f "${f}" ]] || continue
    [[ "$(file_mtime "${f}")" -le "${cutoff}" ]] || continue
    [[ "$(file_size "${f}")" == "${size}" ]] || { log "skip (changed since archive): ${relpath}"; continue; }
    a="$(archive_path "${month}")"
    [[ -f "${a}" ]] || { log "skip (no archive): ${relpath}"; continue; }
    if [[ -z "${month_members[${month}]:-}" ]]; then
      month_members[${month}]="$(zstd -d "${ZSTD_DOPTS[@]}" -c "${a}" | tar -tf -)"
    fi
    members="${month_members[${month}]}"
    if ! grep -qxF "./${relpath}" <<<"${members}"; then
      log "skip (not in archive): ${relpath}"; continue
    fi
    rm -f "${f}"
    deleted=$(( deleted + 1 )); freed=$(( freed + size ))
  done <"${INDEX}"
  awk -v d="${deleted}" -v f="${freed}" \
    'BEGIN { printf "pruned %d live transcript(s), freed %.0f MB\n", d, f/1048576 }'
}

# Resolve whatever the user typed into a bucket name. Accepts a bucket verbatim
# (2026-W31), an ISO date (2026-07-14), or a loose date the platform's `date` can
# parse; a bare YYYY-MM is rejected because a month spans 4-5 buckets.
resolve_bucket() {
  local input="$1"
  case "${input}" in
    [0-9][0-9][0-9][0-9]-W[0-9][0-9]) printf '%s' "${input}"; return 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]) die "'${input}' is a month, which spans several weekly buckets — pass a full date (YYYY-MM-DD) or a bucket (YYYY-W##)" ;;
  esac
  local out
  # BSD date needs the input format up front; GNU date takes -d. Try both so the
  # script behaves the same on macOS and Linux.
  out="$(date -j -f '%Y-%m-%d' "${input}" '+%G-W%V' 2>/dev/null)" \
    || out="$(date -d "${input}" '+%G-W%V' 2>/dev/null)" \
    || die "cannot parse date: ${input}"
  printf '%s' "${out}"
}

# Which archive holds the transcripts for a given day?
#
# The index records each file's mtime — its LAST write — so a session that began
# on the 14th but continued into the 20th sits in the later bucket. A naive
# date -> bucket mapping would report "not found" for it. So the lookup covers the
# resolved bucket plus the following LOOKAHEAD buckets, and --deep confirms by
# reading the actual "timestamp" entries inside the archives.
LOOKAHEAD=2
cmd_find() {
  [[ -n "${MONTH_ARG}" ]] || die "usage: $0 find <YYYY-MM-DD|YYYY-W##> [--deep] [--project NAME]"
  local bucket target_date candidates=() b a n
  bucket="$(resolve_bucket "${MONTH_ARG}")"

  # Only a full date can be matched against file contents; a bucket argument is
  # already the answer to "which archive".
  if [[ "${MONTH_ARG}" == *W* ]]; then target_date=''; else
    target_date="$(date -j -f '%Y-%m-%d' "${MONTH_ARG}" '+%Y-%m-%d' 2>/dev/null \
      || date -d "${MONTH_ARG}" '+%Y-%m-%d')"
  fi

  candidates=("${bucket}")
  local year="${bucket%%-W*}" week="${bucket##*-W}"
  for (( n = 1; n <= LOOKAHEAD; n++ )); do
    candidates+=("$(printf '%s-W%02d' "${year}" "$(( 10#${week} + n ))")")
  done

  printf 'date %s -> bucket %s\n\n' "${MONTH_ARG:-?}" "${bucket}"
  for b in "${candidates[@]}"; do
    a="$(archive_path "${b}")"
    if [[ ! -f "${a}" ]]; then
      printf '%-12s (no archive)\n' "${b}"
      continue
    fi
    n="$(awk -F'\t' -v m="${b}" '$4 == m' "${INDEX}" | grep -c '' || true)"
    printf '%-12s %s  (%s files, %s)\n' "${b}" "${a}" "${n}" \
      "$(awk -v c="$(file_size "${a}")" 'BEGIN { printf "%.1f MB", c/1048576 }')"
    if [[ -n "${target_date}" ]]; then
      # Index mtimes give a cheap first answer: files last written that day.
      # Roll subagent transcripts up into their parent session — a single session
      # can own 40+ of them, which otherwise drowns the output.
      awk -F'\t' -v m="${b}" -v d="${target_date}" \
        '$4 == m { cmd = "date -r " $3 " +%Y-%m-%d"; cmd | getline day; close(cmd);
                   if (day == d) print $1 }' "${INDEX}" \
        | { if [[ -n "${PROJECT_FILTER_FIND}" ]]; then grep -F "${PROJECT_FILTER_FIND}"; else cat; fi; } \
        | sed -e 's|/subagents/.*$||' -e 's|\.jsonl$||' \
        | sort | uniq -c \
        | awk '{ n = $1; $1 = ""; sub(/^ /, "");
                 printf "    %s  (%d file%s)\n", $0, n, (n == 1 ? "" : "s") }' \
        || true
    fi
  done

  [[ "${DEEP}" -eq 1 && -n "${target_date}" ]] || return 0

  # --deep: a conversation on date D leaves entries stamped D regardless of when
  # the file was last written, so this is the authoritative answer.
  printf '\ndeep scan for entries stamped %s:\n' "${target_date}"
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN
  for b in "${candidates[@]}"; do
    a="$(archive_path "${b}")"
    [[ -f "${a}" ]] || continue
    rm -rf "${work}/x"; mkdir -p "${work}/x"
    zstd -d "${ZSTD_DOPTS[@]}" -c "${a}" | tar -xf - -C "${work}/x"
    grep -rl "\"timestamp\":\"${target_date}T" "${work}/x" 2>/dev/null \
      | sed "s|^${work}/x/||" \
      | { if [[ -n "${PROJECT_FILTER_FIND}" ]]; then grep -F "${PROJECT_FILTER_FIND}"; else cat; fi; } \
      | sed -e 's|/subagents/.*$||' -e 's|\.jsonl$||' \
      | sort | uniq -c \
      | awk -v b="${b}" '{ n = $1; $1 = ""; sub(/^ /, "");
                           printf "    %-12s %s  (%d file%s)\n", b, $0, n, (n == 1 ? "" : "s") }' \
      || true
  done
}

# Re-bucket every existing archive into the CURRENT bucketing scheme (weekly).
# Needed once, to convert archives written while this script bucketed by month.
# It works from the archives themselves rather than from live files, so anything
# already pruned from ~/.claude/projects still survives the conversion. tar
# restores mtimes, which is what the bucket is derived from.
cmd_rebucket() {
  local work stage a old_bucket new_bucket f relpath
  shopt -s nullglob
  local archives=("${ARCHIVE_DIR}"/*.tar.zst)
  shopt -u nullglob
  [[ ${#archives[@]} -gt 0 ]] || { log "no archives to re-bucket"; return 0; }

  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN
  stage="${work}/all"
  mkdir -p "${stage}"

  for a in "${archives[@]}"; do
    old_bucket="$(basename -- "${a}" .tar.zst)"
    log "unpacking ${old_bucket}"
    zstd -d "${ZSTD_DOPTS[@]}" -c "${a}" | tar -xf - -C "${stage}"
  done

  # Group the unpacked members by the bucket their mtime now maps to.
  local -a buckets=()
  while IFS= read -r f; do
    new_bucket="$(file_bucket "${f}")"
    mkdir -p "${work}/by/${new_bucket}/$(dirname -- "${f#"${stage}"/}")"
    mv "${f}" "${work}/by/${new_bucket}/${f#"${stage}"/}"
    buckets+=("${new_bucket}")
  done < <(find "${stage}" -name '*.jsonl' -type f)

  # shellcheck disable=SC2207
  buckets=($(printf '%s\n' "${buckets[@]}" | sort -u))
  log "re-bucketing into ${#buckets[@]}: ${buckets[*]}"

  # Rebuild the index from scratch so its bucket column matches the new archives.
  : >"${INDEX}.new"
  for new_bucket in "${buckets[@]}"; do
    local src="${work}/by/${new_bucket}"
    log "${new_bucket}: compressing $(find "${src}" -name '*.jsonl' | grep -c '') file(s)"
    ( cd "${src}" && find . -name '*.jsonl' -type f | sort | tar -cf - -T - ) \
      | zstd "${ZSTD_OPTS[@]}" -q -o "${work}/${new_bucket}.tar.zst"
    mv "${work}/${new_bucket}.tar.zst" "$(archive_path "${new_bucket}")"
    while IFS= read -r f; do
      # Members were moved into ${src}/<relpath> with no "./" segment — stripping
      # "${src}/./" here silently left the absolute temp path in the index.
      relpath="${f#"${src}"/}"
      printf '%s\t%s\t%s\t%s\n' "${relpath}" "$(file_size "${f}")" \
        "$(file_mtime "${f}")" "${new_bucket}" >>"${INDEX}.new"
    done < <(find "${src}" -name '*.jsonl' -type f)
  done
  mv "${INDEX}.new" "${INDEX}"

  # Drop archives whose bucket name is no longer produced (the old monthly ones).
  for a in "${archives[@]}"; do
    old_bucket="$(basename -- "${a}" .tar.zst)"
    if ! printf '%s\n' "${buckets[@]}" | grep -qxF "${old_bucket}"; then
      rm -f "${a}"
      log "removed superseded archive ${old_bucket}"
    fi
  done
  log "done — see: $0 status"
}

# Rebuild index.tsv from the archives' own member lists, cross-referencing live
# files for size/mtime. Repairs a damaged index without recompressing anything.
# A member that is no longer live keeps whatever row it had (or is recorded with
# size 0 / mtime 0), so it is never mistaken for "unarchived" and re-added.
cmd_reindex() {
  local a bucket member relpath live rows=0
  : >"${INDEX}.new"
  shopt -s nullglob
  for a in "${ARCHIVE_DIR}"/*.tar.zst; do
    bucket="$(basename -- "${a}" .tar.zst)"
    log "reading members of ${bucket}"
    while IFS= read -r member; do
      relpath="${member#./}"
      live="${PROJECTS_DIR}/${relpath}"
      if [[ -f "${live}" ]]; then
        printf '%s\t%s\t%s\t%s\n' "${relpath}" "$(file_size "${live}")" \
          "$(file_mtime "${live}")" "${bucket}" >>"${INDEX}.new"
      else
        printf '%s\t0\t0\t%s\n' "${relpath}" "${bucket}" >>"${INDEX}.new"
      fi
      rows=$(( rows + 1 ))
    done < <(zstd -d "${ZSTD_DOPTS[@]}" -c "${a}" | tar -tf - | grep '\.jsonl$')
  done
  shopt -u nullglob
  mv "${INDEX}.new" "${INDEX}"
  log "reindexed ${rows} member(s)"
}

cmd_install_cron() {
  local entry="30 2 * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ${HOME}/.claude/scripts/transcript-archive.sh run >> ${HOME}/.claude/logs/transcript-archive.log 2>&1"
  if crontab -l 2>/dev/null | grep -qF 'transcript-archive.sh'; then
    log "cron entry already installed"
    crontab -l 2>/dev/null | grep -F 'transcript-archive.sh'
    return 0
  fi
  mkdir -p "${HOME}/.claude/logs"
  { crontab -l 2>/dev/null; echo "# Transcript archive: nightly 2:30am — solid monthly zstd -22 archives"; echo "${entry}"; } | crontab -
  log "installed: ${entry}"
}

case "${SUB}" in
  run) cmd_run ;;
  rebucket) cmd_rebucket ;;
  reindex) cmd_reindex ;;
  find) cmd_find ;;
  status) cmd_status ;;
  verify) cmd_verify ;;
  restore) cmd_restore ;;
  prune) cmd_prune ;;
  install-cron) cmd_install_cron ;;
  *) die "unknown subcommand: ${SUB}" ;;
esac
