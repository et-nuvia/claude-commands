#!/usr/bin/env bash
set -euo pipefail

# migration-timestamp.sh - Generate, verify, and repair migration timestamps
#
# WHY THIS EXISTS:
# Migration filenames are timestamp-prefixed, and the timestamp is what orders
# them. Hand-picking round numbers (1756800000000, 1757300000000) puts branches
# out of order the moment two of them are open at once: whichever branch merges
# second carries a timestamp BELOW an already-applied migration, so a fresh
# database and an existing database apply them in different relative orders.
# A real current-epoch-milliseconds value is monotonic by construction and
# cannot collide across branches.
#
# CROSS-PLATFORM: macOS/BSD `date` has no %N, so `date +%s%3N` yields a literal
# trailing "N" (e.g. 17853592873N) rather than milliseconds. That silently
# produces a garbage timestamp. This script probes for a working millisecond
# source and never emits a value it has not validated as all-digits.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  cat << EOF
Usage: ${SCRIPT_NAME} [COMMAND] [OPTIONS]

Generate, verify, and repair timestamp-prefixed database migration filenames.
Works identically on macOS (BSD date) and WSL/Debian (GNU date).

COMMANDS:
  --now                    Print current epoch milliseconds (default)
  --name CLASS             Print the filename + class name for a new migration
  --rename FILE            Rewrite an existing migration to the current timestamp
                           (renames the file, its .spec.ts sibling, the exported
                           class, the \`name\` property, and all references)
  --verify                 Check a migrations directory for ordering problems
  -h, --help               Show this help

OPTIONS:
  -d, --dir PATH           Migrations directory
                           (default: auto-detected from PROJECT.yaml, else
                            backend/src/database/migrations)
  --ext EXT                Migration file extension (default: ts)
  -n, --dry-run            With --rename: report what would change, change nothing
  --json                   Force JSON output
  -q, --quiet              Suppress human-readable commentary

EXAMPLES:
  ${SCRIPT_NAME}                              # 1785359302000
  ${SCRIPT_NAME} --name AddUserPreferences    # -> 1785359302000-AddUserPreferences.ts
  ${SCRIPT_NAME} --rename backend/src/database/migrations/1756800000000-Foo.ts
  ${SCRIPT_NAME} --verify                     # ordering + collision + round-number audit

WHAT --verify CHECKS:
  ISSUES (fail the check, exit 3):
    - duplicate timestamps — two migrations sharing one value have a
      non-deterministic relative order, which is the actual correctness bug
    - timestamps in the future (clock skew or a fabricated value)
    - timestamps before 2020 (implausible; usually seconds mistaken for ms)
    - filenames that do not start with <timestamp>-

  ADVISORY (reported, does NOT fail):
    - suspiciously round timestamps (>=6 trailing zeros = hand-picked). An
      existing repo has many of these historically; rewriting applied
      migrations is not safe, so this is informational. Reported as a single
      aggregate count, not one line per file.

EXIT CODES:
  0 - Success (no issues; advisories may still be reported)
  1 - Invalid usage or unreadable path
  2 - No working millisecond clock source found
  3 - --verify found one or more ISSUES
EOF
}

# ---------------------------------------------------------------------------
# Millisecond clock, probed rather than assumed.
# ---------------------------------------------------------------------------
is_all_digits() { [[ "$1" =~ ^[0-9]+$ ]]; }

epoch_ms() {
  local candidate

  # GNU date (Linux/WSL, or coreutils gdate on macOS via brew)
  if command -v gdate > /dev/null 2>&1; then
    candidate="$(gdate +%s%3N 2> /dev/null || true)"
    if is_all_digits "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi

  candidate="$(date +%s%3N 2> /dev/null || true)"
  if is_all_digits "${candidate}"; then
    printf '%s' "${candidate}"
    return 0
  fi

  # python3 is the most reliable fallback on macOS
  if command -v python3 > /dev/null 2>&1; then
    candidate="$(python3 -c 'import time; print(int(time.time()*1000))' 2> /dev/null || true)"
    if is_all_digits "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi

  if command -v perl > /dev/null 2>&1; then
    candidate="$(perl -MTime::HiRes -e 'print int(Time::HiRes::time()*1000)' 2> /dev/null || true)"
    if is_all_digits "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi

  if command -v node > /dev/null 2>&1; then
    candidate="$(node -e 'process.stdout.write(String(Date.now()))' 2> /dev/null || true)"
    if is_all_digits "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi

  # Last resort: whole seconds padded to milliseconds. Still monotonic and still
  # vastly better than a hand-picked constant; only loses sub-second resolution.
  candidate="$(date +%s 2> /dev/null || true)"
  if is_all_digits "${candidate}"; then
    printf '%s000' "${candidate}"
    return 0
  fi

  return 2
}

# ---------------------------------------------------------------------------
# Migrations directory resolution
# ---------------------------------------------------------------------------
default_migrations_dir() {
  # PROJECT.yaml: databases[].migrations.directory
  if [[ -f PROJECT.yaml ]]; then
    local from_yaml
    from_yaml="$(grep -A2 'migrations:' PROJECT.yaml 2> /dev/null | grep 'directory:' | head -1 | sed 's/.*directory:[[:space:]]*//' | tr -d '"'"'" || true)"
    if [[ -n "${from_yaml}" && -d "${from_yaml}" ]]; then
      printf '%s' "${from_yaml}"
      return 0
    fi
  fi

  local guess
  for guess in \
    backend/src/database/migrations \
    src/database/migrations \
    backend/migrations \
    migrations; do
    if [[ -d "${guess}" ]]; then
      printf '%s' "${guess}"
      return 0
    fi
  done

  printf 'backend/src/database/migrations'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_now() {
  local ts
  if ! ts="$(epoch_ms)"; then
    printf '{"status":"error","section":"now","message":"no working millisecond clock source found"}\n'
    exit 2
  fi

  if [[ "${OUTPUT_JSON}" == "true" ]]; then
    printf '{"status":"success","section":"now","timestamp":"%s"}\n' "${ts}"
  else
    printf '%s\n' "${ts}"
  fi
}

cmd_name() {
  local class_name="$1" ts
  if [[ -z "${class_name}" ]]; then
    printf '%b\n' "${RED}Error: --name requires a class name${NC}" >&2
    exit 1
  fi
  if ! ts="$(epoch_ms)"; then
    printf '{"status":"error","section":"name","message":"no working millisecond clock source found"}\n'
    exit 2
  fi

  local filename="${ts}-${class_name}.${MIGRATION_EXT}"
  local full_class="${class_name}${ts}"

  if [[ "${OUTPUT_JSON}" == "true" ]]; then
    printf '{"status":"success","section":"name","timestamp":"%s","filename":"%s","filepath":"%s","class_name":"%s","next_action":"create_migration"}\n' \
      "${ts}" "${filename}" "${MIGRATIONS_DIR}/${filename}" "${full_class}"
  else
    printf 'timestamp: %s\n' "${ts}"
    printf 'filename:  %s\n' "${filename}"
    printf 'filepath:  %s\n' "${MIGRATIONS_DIR}/${filename}"
    printf 'class:     %s\n' "${full_class}"
  fi
}

cmd_rename() {
  local src="$1"
  if [[ -z "${src}" ]]; then
    printf '%b\n' "${RED}Error: --rename requires a file path${NC}" >&2
    exit 1
  fi
  if [[ ! -f "${src}" ]]; then
    printf '%b\n' "${RED}Error: not a file: ${src}${NC}" >&2
    exit 1
  fi

  local dir base old_ts stem
  dir="$(dirname "${src}")"
  base="$(basename "${src}")"

  # Expect <digits>-<Stem>.<ext>
  if [[ ! "${base}" =~ ^([0-9]+)-(.+)\.([A-Za-z0-9]+)$ ]]; then
    printf '%b\n' "${RED}Error: filename is not <timestamp>-<Name>.<ext>: ${base}${NC}" >&2
    exit 1
  fi
  old_ts="${BASH_REMATCH[1]}"
  stem="${BASH_REMATCH[2]}"
  local ext="${BASH_REMATCH[3]}"

  local new_ts
  if ! new_ts="$(epoch_ms)"; then
    printf '{"status":"error","section":"rename","message":"no working millisecond clock source found"}\n'
    exit 2
  fi

  local new_base="${new_ts}-${stem}.${ext}"
  local src_spec="${dir}/${old_ts}-${stem}.spec.${ext}"
  local new_spec="${dir}/${new_ts}-${stem}.spec.${ext}"
  local has_spec="false"
  [[ -f "${src_spec}" ]] && has_spec="true"

  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ "${OUTPUT_JSON}" == "true" ]]; then
      printf '{"status":"success","section":"rename","dry_run":true,"old_timestamp":"%s","new_timestamp":"%s","file":"%s","new_file":"%s","spec_renamed":%s}\n' \
        "${old_ts}" "${new_ts}" "$(json_escape "${src}")" "$(json_escape "${dir}/${new_base}")" "${has_spec}"
    else
      printf 'would rename: %s -> %s\n' "${base}" "${new_base}"
      [[ "${has_spec}" == "true" ]] && printf 'would rename: %s-%s.spec.%s -> %s-%s.spec.%s\n' "${old_ts}" "${stem}" "${ext}" "${new_ts}" "${stem}" "${ext}"
      printf 'would rewrite class: %s%s -> %s%s\n' "${stem}" "${old_ts}" "${stem}" "${new_ts}"
    fi
    return 0
  fi

  # Prefer `git mv` so history follows the rename when inside a work tree.
  local mv_cmd=(mv)
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    mv_cmd=(git mv)
  fi

  "${mv_cmd[@]}" "${src}" "${dir}/${new_base}"
  if [[ "${has_spec}" == "true" ]]; then
    "${mv_cmd[@]}" "${src_spec}" "${new_spec}"
  fi

  # Rewrite the timestamp inside the renamed files (class name, `name` property,
  # relative import in the spec). sed -i differs between BSD and GNU: BSD needs
  # an explicit (possibly empty) suffix argument, GNU accepts none.
  local -a targets=("${dir}/${new_base}")
  [[ "${has_spec}" == "true" ]] && targets+=("${new_spec}")

  local t
  for t in "${targets[@]}"; do
    if sed --version > /dev/null 2>&1; then
      sed -i "s/${old_ts}/${new_ts}/g" "${t}"
    else
      sed -i '' "s/${old_ts}/${new_ts}/g" "${t}"
    fi
  done

  if [[ "${OUTPUT_JSON}" == "true" ]]; then
    printf '{"status":"success","section":"rename","old_timestamp":"%s","new_timestamp":"%s","file":"%s","spec_renamed":%s,"next_action":"verify_and_test"}\n' \
      "${old_ts}" "${new_ts}" "$(json_escape "${dir}/${new_base}")" "${has_spec}"
  else
    printf '%b\n' "${GREEN}renamed:${NC} ${base} -> ${new_base}"
    [[ "${has_spec}" == "true" ]] && printf '%b\n' "${GREEN}renamed:${NC} spec sibling"
    printf '%b\n' "${GREEN}rewrote:${NC} class ${stem}${old_ts} -> ${stem}${new_ts}"
    printf '%b\n' "${YELLOW}next:${NC} re-run typecheck and the migration spec"
  fi
}

cmd_verify() {
  if [[ ! -d "${MIGRATIONS_DIR}" ]]; then
    printf '%b\n' "${RED}Error: migrations directory not found: ${MIGRATIONS_DIR}${NC}" >&2
    exit 1
  fi

  local now_ms
  now_ms="$(epoch_ms)" || now_ms=""

  # 2020-01-01T00:00:00Z in ms — anything earlier is implausible for a real clock.
  local min_plausible=1577836800000

  local -a issues=()
  local -a timestamps=()
  local round_count=0
  local f base ts

  while IFS= read -r f; do
    base="$(basename "${f}")"
    [[ "${base}" == *.spec.* ]] && continue
    if [[ ! "${base}" =~ ^([0-9]+)- ]]; then
      issues+=("unparseable|${base}|filename does not start with <timestamp>-")
      continue
    fi
    ts="${BASH_REMATCH[1]}"
    timestamps+=("${ts}|${base}")

    # Advisory only: an existing repo legitimately has many historical
    # hand-picked timestamps, and rewriting an APPLIED migration is unsafe.
    if [[ "${ts}" =~ 000000$ ]]; then
      round_count=$((round_count + 1))
    fi
    if [[ ${#ts} -ge 13 && -n "${now_ms}" && "${ts}" -gt "${now_ms}" ]]; then
      issues+=("future|${base}|timestamp is in the future")
    fi
    if [[ ${#ts} -ge 13 && "${ts}" -lt "${min_plausible}" ]]; then
      issues+=("implausible|${base}|timestamp predates 2020")
    fi
  done < <(find "${MIGRATIONS_DIR}" -maxdepth 1 -type f -name "*.${MIGRATION_EXT}" | sort)

  # Duplicate timestamps
  local dupes
  dupes="$(printf '%s\n' "${timestamps[@]+"${timestamps[@]}"}" | cut -d'|' -f1 | sort | uniq -d || true)"
  if [[ -n "${dupes}" ]]; then
    while IFS= read -r ts; do
      [[ -z "${ts}" ]] && continue
      issues+=("duplicate|${ts}|two or more migrations share this timestamp")
    done <<< "${dupes}"
  fi

  local count="${#timestamps[@]}"
  local issue_count="${#issues[@]}"

  if [[ "${OUTPUT_JSON}" == "true" ]]; then
    printf '{"status":"%s","section":"verify","dir":"%s","migrations":%d,"issues_found":%d,"hand_picked_timestamps":%d,"issues":[' \
      "$([[ ${issue_count} -eq 0 ]] && echo success || echo issues_found)" \
      "$(json_escape "${MIGRATIONS_DIR}")" "${count}" "${issue_count}" "${round_count}"
    local first=true i kind subject msg
    for i in "${issues[@]+"${issues[@]}"}"; do
      kind="${i%%|*}"
      subject="$(printf '%s' "${i}" | cut -d'|' -f2)"
      msg="${i#*|*|}"
      [[ "${first}" == "true" ]] && first=false || printf ','
      printf '{"kind":"%s","subject":"%s","message":"%s"}' \
        "${kind}" "$(json_escape "${subject}")" "$(json_escape "${msg}")"
    done
    printf ']}\n'
  else
    printf 'migrations dir: %s\n' "${MIGRATIONS_DIR}"
    printf 'migrations:     %d\n' "${count}"
    if [[ ${round_count} -gt 0 ]]; then
      printf '%b\n' "${YELLOW}advisory:${NC} ${round_count} hand-picked (round) timestamp(s) — historical, not rewritten; use '${SCRIPT_NAME} --now' for new ones"
    fi
    if [[ ${issue_count} -eq 0 ]]; then
      printf '%b\n' "${GREEN}no ordering issues found${NC}"
    else
      printf '%b\n' "${RED}${issue_count} issue(s):${NC}"
      local i
      for i in "${issues[@]}"; do
        printf '  [%s] %s — %s\n' "${i%%|*}" "$(printf '%s' "${i}" | cut -d'|' -f2)" "${i#*|*|}"
      done
    fi
  fi

  [[ ${issue_count} -eq 0 ]] || exit 3
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
COMMAND="now"
CLASS_NAME=""
RENAME_TARGET=""
MIGRATIONS_DIR=""
MIGRATION_EXT="ts"
DRY_RUN="false"
QUIET="false"

# LLM callers get JSON; a human tty gets plain text unless --json is passed.
if [[ -t 1 ]]; then OUTPUT_JSON="false"; else OUTPUT_JSON="true"; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --now)
      COMMAND="now"
      shift
      ;;
    --name)
      COMMAND="name"
      CLASS_NAME="${2:-}"
      shift 2
      ;;
    --rename)
      COMMAND="rename"
      RENAME_TARGET="${2:-}"
      shift 2
      ;;
    --verify)
      COMMAND="verify"
      shift
      ;;
    -d | --dir)
      MIGRATIONS_DIR="${2:-}"
      shift 2
      ;;
    --ext)
      MIGRATION_EXT="${2:-}"
      shift 2
      ;;
    -n | --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --json)
      OUTPUT_JSON="true"
      shift
      ;;
    -q | --quiet)
      QUIET="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%b\n' "${RED}Unknown option: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "${MIGRATIONS_DIR}" ]] || MIGRATIONS_DIR="$(default_migrations_dir)"

case "${COMMAND}" in
  now) cmd_now ;;
  name) cmd_name "${CLASS_NAME}" ;;
  rename) cmd_rename "${RENAME_TARGET}" ;;
  verify) cmd_verify ;;
  *)
    printf '%b\n' "${RED}Unknown command: ${COMMAND}${NC}" >&2
    exit 1
    ;;
esac
