#!/usr/bin/env bash
# schedule-job.sh — register ~/.claude maintenance jobs with the platform scheduler.
#
# Cross-platform: macOS (launchd LaunchAgent) and Linux/WSL Debian (systemd user
# timer). Jobs are declared once in ~/.claude/scheduled-jobs.json and rendered to
# whichever mechanism the machine actually has, so the registry syncs across
# machines while the units stay platform-native.
#
# This generalises the scheduler install logic proven in docker-idle-reaper.sh
# (see ~/projects/wiki/patterns/docker-idle-stack-reaping.md) and adds calendar
# cadence, which cron on macOS cannot do reliably: a cron job scheduled while the
# Mac is asleep is simply skipped, which silently killed three nightly jobs here.
# launchd runs a missed StartCalendarInterval job once on wake, and systemd's
# Persistent=true does the same after downtime — one catch-up run, never a backlog.
#
# Usage:
#   schedule-job.sh list                  # every registered job + live install state
#   schedule-job.sh status                # alias for list
#   schedule-job.sh install --all         # install every job this script manages
#   schedule-job.sh install <name>        # install one job
#   schedule-job.sh uninstall --all       # remove all managed units
#   schedule-job.sh uninstall <name>
#   schedule-job.sh --json list           # machine-readable output
#
# Jobs marked "external" in the registry (docker-idle-reaper) own their installer
# because their cadence comes from their own config. They are listed for a complete
# picture of the machine but skipped by install/uninstall.
#
# Idempotent: installing over an existing unit rewrites and reloads it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
REGISTRY="${CLAUDE_DIR}/scheduled-jobs.json"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
LAUNCH_DIR="${HOME}/Library/LaunchAgents"
# PLATFORM axis: launchd vs systemd-user is an OS capability, not a policy.
source "${SCRIPT_DIR}/lib/platform.sh"
OS="$(env_platform)"

JSON_OUT=0
[[ -n "${CLAUDECODE:-}" ]] && JSON_OUT=1
SUBCOMMAND="list"
TARGET=""

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; DIM=''; NC=''
fi

die() {
  if [[ "${JSON_OUT}" -eq 1 ]]; then
    printf '{"status":"error","message":"%s"}\n' "$1"
  else
    printf "${RED}error: %s${NC}\n" "$1" >&2
  fi
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required (ensure-dependencies.sh --group core)"
[[ -f "${REGISTRY}" ]] || die "registry not found: ${REGISTRY}"

# --- registry access --------------------------------------------------------

job_names() { jq -r '.jobs[].name' "${REGISTRY}"; }

# Emit one job's fields as shell-eval-able assignments. Every value is quoted by jq
# so a description containing spaces or quotes cannot break the eval.
job_fields() {
  jq -r --arg n "$1" '
    .jobs[] | select(.name == $n) |
    "J_LABEL=\(.label|@sh) J_SCRIPT=\(.script|@sh) J_LOG=\(.log|@sh)",
    "J_DESC=\(.description|@sh) J_EXTERNAL=\((.external // "")|@sh)",
    "J_TYPE=\(.schedule.type|@sh) J_HOUR=\((.schedule.hour // 0)|@sh)",
    "J_MIN=\((.schedule.minute // 0)|@sh) J_SECONDS=\((.schedule.seconds // 0)|@sh)",
    "J_ARGS=(\([.args[]|@sh] | join(" ")))"
  ' "${REGISTRY}"
}

load_job() {
  local n="$1" defs
  defs="$(job_fields "${n}")" || die "job not found: ${n}"
  [[ -n "${defs}" ]] || die "job not found: ${n}"
  J_LABEL=""; J_SCRIPT=""; J_LOG=""; J_DESC=""; J_EXTERNAL=""
  J_TYPE=""; J_HOUR=0; J_MIN=0; J_SECONDS=0; J_ARGS=()
  eval "${defs}"
  J_NAME="${n}"
  J_SCRIPT_ABS="${CLAUDE_DIR}/${J_SCRIPT}"
  J_LOG_ABS="${CLAUDE_DIR}/${J_LOG}"
  J_UNIT="${J_NAME}"
}

# Human-readable cadence, e.g. "daily 02:30" or "every 300s".
schedule_desc() {
  if [[ "${J_TYPE}" == "calendar" ]]; then
    printf 'daily %02d:%02d' "${J_HOUR}" "${J_MIN}"
  else
    printf 'every %ss' "${J_SECONDS}"
  fi
}

# --- install state probing --------------------------------------------------

# "installed" = a unit file exists AND the scheduler has it loaded/enabled. Both
# are checked because a stale plist on disk that launchd never loaded is the exact
# failure this tool exists to catch.
is_installed() {
  case "${OS}" in
    darwin)
      [[ -f "${LAUNCH_DIR}/${J_LABEL}.plist" ]] || return 1
      launchctl list "${J_LABEL}" >/dev/null 2>&1
      ;;
    linux|wsl)
      [[ -f "${SYSTEMD_DIR}/${J_UNIT}.timer" ]] || return 1
      systemctl --user is-enabled "${J_UNIT}.timer" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# mtime of the job's log, as a proxy for "when did this last actually run".
last_run() {
  [[ -f "${J_LOG_ABS}" ]] || { echo "never"; return; }
  local m
  m=$(stat -c %Y "${J_LOG_ABS}" 2>/dev/null || stat -f %m "${J_LOG_ABS}" 2>/dev/null || echo 0)
  [[ "${m}" == "0" ]] && { echo "unknown"; return; }
  date -r "${m}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@${m}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown
}

# --- macOS: launchd LaunchAgent ---------------------------------------------
#
# An explicit PATH is required: launchd does not source a shell, so a job that
# shells out to git/docker/jq finds nothing without it.
install_launchd() {
  local plist="${LAUNCH_DIR}/${J_LABEL}.plist" cadence arg
  mkdir -p "${LAUNCH_DIR}"

  if [[ "${J_TYPE}" == "calendar" ]]; then
    cadence=$(printf '  <key>StartCalendarInterval</key>\n  <dict>\n    <key>Hour</key><integer>%d</integer>\n    <key>Minute</key><integer>%d</integer>\n  </dict>' "${J_HOUR}" "${J_MIN}")
  else
    cadence=$(printf '  <key>StartInterval</key><integer>%d</integer>' "${J_SECONDS}")
  fi

  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "${J_LABEL}"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    # Exec the script directly so its own shebang picks the interpreter. Hardcoding
    # /bin/bash here would pin macOS's bash 3.2, which lacks mapfile and other
    # bash-4+ builtins these scripts use; `#!/usr/bin/env bash` finds 5.x on PATH.
    printf '    <string>%s</string>\n' "${J_SCRIPT_ABS}"
    for arg in ${J_ARGS[@]+"${J_ARGS[@]}"}; do
      printf '    <string>%s</string>\n' "${arg}"
    done
    printf '  </array>\n'
    printf '%s\n' "${cadence}"
    printf '  <key>RunAtLoad</key><false/>\n'
    printf '  <key>StandardOutPath</key><string>%s</string>\n' "${J_LOG_ABS}"
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' "${J_LOG_ABS}"
    printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>PATH</key><string>%s</string>\n' "${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    printf '    <key>HOME</key><string>%s</string>\n' "${HOME}"
    printf '  </dict>\n</dict>\n</plist>\n'
  } >"${plist}"

  launchctl unload "${plist}" 2>/dev/null || true
  launchctl load "${plist}"
}

# --- Linux / WSL Debian: systemd user timer ---------------------------------
#
# A user timer, not a system unit: no root, and it inherits the user's docker
# group access. WSL needs [boot] systemd=true in /etc/wsl.conf — without it
# `systemctl --user` is unavailable, and we refuse rather than install a timer
# that never fires.
install_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    local cronline
    if [[ "${J_TYPE}" == "calendar" ]]; then
      cronline=$(printf '%d %d * * * %s %s' "${J_MIN}" "${J_HOUR}" "${J_SCRIPT_ABS}" "${J_ARGS[*]-}")
    else
      cronline=$(printf '*/%d * * * * %s %s' $(( J_SECONDS / 60 )) "${J_SCRIPT_ABS}" "${J_ARGS[*]-}")
    fi
    die "systemd user session unavailable. On WSL set [boot] systemd=true in /etc/wsl.conf and run 'wsl --shutdown'. Until then use cron: ${cronline}"
  fi

  mkdir -p "${SYSTEMD_DIR}" "$(dirname "${J_LOG_ABS}")"

  {
    printf '[Unit]\nDescription=%s\n\n' "${J_DESC}"
    printf '[Service]\nType=oneshot\n'
    printf 'ExecStart=%s %s\n' "${J_SCRIPT_ABS}" "${J_ARGS[*]-}"
    printf 'Environment=PATH=%s/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n' "${HOME}"
    printf 'StandardOutput=append:%s\nStandardError=append:%s\n' "${J_LOG_ABS}" "${J_LOG_ABS}"
  } >"${SYSTEMD_DIR}/${J_UNIT}.service"

  {
    printf '[Unit]\nDescription=%s (timer)\n\n[Timer]\n' "${J_DESC}"
    if [[ "${J_TYPE}" == "calendar" ]]; then
      # Persistent=true mirrors launchd: one catch-up run after downtime, not a
      # replay of every missed occurrence.
      printf 'OnCalendar=*-*-* %02d:%02d:00\nPersistent=true\n' "${J_HOUR}" "${J_MIN}"
    else
      printf 'OnBootSec=%d\nOnUnitInactiveSec=%d\nAccuracySec=30s\n' "${J_SECONDS}" "${J_SECONDS}"
    fi
    printf 'Unit=%s.service\n\n[Install]\nWantedBy=timers.target\n' "${J_UNIT}"
  } >"${SYSTEMD_DIR}/${J_UNIT}.timer"

  systemctl --user daemon-reload
  systemctl --user enable --now "${J_UNIT}.timer"
  # Without lingering the timer stops when the last session closes.
  loginctl enable-linger "${USER}" 2>/dev/null || true
}

uninstall_one() {
  case "${OS}" in
    darwin)
      launchctl unload "${LAUNCH_DIR}/${J_LABEL}.plist" 2>/dev/null || true
      rm -f "${LAUNCH_DIR}/${J_LABEL}.plist"
      ;;
    linux|wsl)
      systemctl --user disable --now "${J_UNIT}.timer" 2>/dev/null || true
      rm -f "${SYSTEMD_DIR}/${J_UNIT}.timer" "${SYSTEMD_DIR}/${J_UNIT}.service"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
    *) die "unsupported platform: ${OS}" ;;
  esac
}

install_one() {
  [[ -f "${J_SCRIPT_ABS}" ]] || die "job '${J_NAME}' points at a missing script: ${J_SCRIPT_ABS}"
  # The unit execs the script directly, so the exec bit is load-bearing, not cosmetic.
  [[ -x "${J_SCRIPT_ABS}" ]] || chmod +x "${J_SCRIPT_ABS}"
  mkdir -p "$(dirname "${J_LOG_ABS}")"
  case "${OS}" in
    darwin)     install_launchd ;;
    linux|wsl) install_systemd ;;
    *) die "unsupported platform: ${OS}" ;;
  esac
}

# --- subcommands ------------------------------------------------------------

# Names this script manages — everything except externally-installed jobs.
managed_names() {
  jq -r '.jobs[] | select((.external // "") == "") | .name' "${REGISTRY}"
}

cmd_install() {
  local names=() n installed=()
  if [[ "${TARGET}" == "--all" || -z "${TARGET}" ]]; then
    while IFS= read -r n; do names+=("${n}"); done < <(managed_names)
  else
    names=("${TARGET}")
  fi
  for n in "${names[@]}"; do
    load_job "${n}"
    [[ -n "${J_EXTERNAL}" ]] && continue
    install_one
    installed+=("${n}")
  done
  if [[ "${JSON_OUT}" -eq 1 ]]; then
    printf '{"status":"ok","message":"jobs installed","details":{"platform":"%s","installed":%s}}\n' \
      "${OS}" "$(printf '%s\n' "${installed[@]}" | jq -R . | jq -sc .)"
  else
    for n in "${installed[@]}"; do printf "${GREEN}✓ installed %s${NC}\n" "${n}"; done
  fi
}

cmd_uninstall() {
  local names=() n removed=()
  if [[ "${TARGET}" == "--all" ]]; then
    while IFS= read -r n; do names+=("${n}"); done < <(managed_names)
  elif [[ -z "${TARGET}" ]]; then
    die "uninstall needs a job name or --all"
  else
    names=("${TARGET}")
  fi
  for n in "${names[@]}"; do
    load_job "${n}"
    [[ -n "${J_EXTERNAL}" ]] && continue
    uninstall_one
    removed+=("${n}")
  done
  if [[ "${JSON_OUT}" -eq 1 ]]; then
    printf '{"status":"ok","message":"jobs removed","details":{"platform":"%s","removed":%s}}\n' \
      "${OS}" "$(printf '%s\n' "${removed[@]}" | jq -R . | jq -sc .)"
  else
    for n in "${removed[@]}"; do printf "${YELLOW}removed %s${NC}\n" "${n}"; done
  fi
}

cmd_list() {
  local n state owner
  if [[ "${JSON_OUT}" -eq 1 ]]; then
    local first=1
    printf '{"status":"ok","message":"scheduled jobs","details":{"platform":"%s","mechanism":"%s","jobs":[' \
      "${OS}" "$([[ "${OS}" == "darwin" ]] && echo launchd || echo "systemd-user")"
    while IFS= read -r n; do
      load_job "${n}"
      is_installed && state="installed" || state="missing"
      [[ -n "${J_EXTERNAL}" ]] && owner="${J_EXTERNAL}" || owner="schedule-job.sh"
      [[ "${first}" -eq 0 ]] && printf ','
      first=0
      printf '{"name":"%s","label":"%s","schedule":"%s","state":"%s","managed_by":"%s","last_run":"%s"}' \
        "${J_NAME}" "${J_LABEL}" "$(schedule_desc)" "${state}" "${owner}" "$(last_run)"
    done < <(job_names)
    printf ']}}\n'
    return
  fi

  printf "${DIM}platform: %s · mechanism: %s${NC}\n\n" "${OS}" \
    "$([[ "${OS}" == "darwin" ]] && echo "launchd LaunchAgent" || echo "systemd user timer")"
  while IFS= read -r n; do
    load_job "${n}"
    if is_installed; then
      state="${GREEN}installed${NC}"
    else
      state="${RED}MISSING${NC}"
    fi
    [[ -n "${J_EXTERNAL}" ]] && owner=" ${DIM}(via ${J_EXTERNAL})${NC}" || owner=""
    printf "%-22s %-16s %b%b  ${DIM}last run: %s${NC}\n" \
      "${J_NAME}" "$(schedule_desc)" "${state}" "${owner}" "$(last_run)"
  done < <(job_names)
}

# --- arg parsing ------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    list|status|install|uninstall) SUBCOMMAND="$1" ;;
    --json) JSON_OUT=1 ;;
    --no-json) JSON_OUT=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --all) TARGET="--all" ;;
    -*) die "unknown option: $1" ;;
    *) TARGET="$1" ;;
  esac
  shift
done

case "${SUBCOMMAND}" in
  list|status) cmd_list ;;
  install)     cmd_install ;;
  uninstall)   cmd_uninstall ;;
esac
