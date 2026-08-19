#!/usr/bin/env bash
#
# docker-idle-reaper.sh — stop idle Docker Compose stacks in the shared Colima VM.
#
# WHY: all projects share one 12 GiB Colima VM with no per-project reservation.
# Containers left running after a test run hold their resident memory forever
# (MySQL InnoDB pool, V8 old-space, JVM emulators never return freed heap), and
# the VM dies with global_oom — killing an arbitrary victim rather than the hog.
# Per-container memory limits cannot prevent that; they are ceilings, not targets.
# See ~/projects/wiki/patterns/colima-vm-memory-pressure.md
#
# Idleness is measured as CONSECUTIVE IDLE TICKS, not a wall-clock timestamp. A
# single quiet sample never stops anything: at a 300s interval, a 30-minute window
# requires 6 consecutive idle observations. This is what keeps the reaper from
# killing a stack that is mid-migration or between phases of a long e2e run.
#
# Stops with `docker stop`, never `docker compose down`: volumes, networks and warm
# data dirs survive, so a restart costs seconds and no fixture data is lost.
#
# Usage:
#   docker-idle-reaper.sh [run] [--dry-run] [--json]   evaluate all stacks (default)
#   docker-idle-reaper.sh status [--json]              show tracked state, stop nothing
#   docker-idle-reaper.sh install                      register the LaunchAgent
#   docker-idle-reaper.sh uninstall                    remove the LaunchAgent
#
set -euo pipefail

readonly CONFIG_FILE="${HOME}/.claude/docker-idle-reaper.json"
readonly STATE_DIR="${HOME}/.claude/state/docker-idle-reaper"
readonly LOG_FILE="${HOME}/.claude/logs/docker-idle-reaper.log"
readonly PLIST="${HOME}/Library/LaunchAgents/com.eric.docker-idle-reaper.plist"
readonly LABEL="com.eric.docker-idle-reaper"

DRY_RUN=0
JSON_OUT=0
SUBCOMMAND="run"

# --- config -----------------------------------------------------------------

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    printf '{"status":"error","message":"missing config","details":"%s"}\n' "${CONFIG_FILE}"
    exit 1
  fi
  INTERVAL=$(jq -r '.interval_seconds // 300' "${CONFIG_FILE}")
  WORKTREE_MIN=$(jq -r '.worktree_idle_minutes // 30' "${CONFIG_FILE}")
  MAIN_MIN=$(jq -r '.main_idle_minutes // 90' "${CONFIG_FILE}")
  CPU_THRESHOLD=$(jq -r '.cpu_active_threshold // 2.0' "${CONFIG_FILE}")
  # Collapse the arrays into single anchored alternations so matching is one
  # [[ =~ ]] test per candidate rather than a nested loop.
  EXEMPT_CONTAINERS=$(jq -r '(.exempt_containers // []) | join("|")' "${CONFIG_FILE}")
  EXEMPT_PROJECTS=$(jq -r '(.exempt_projects // []) | join("|")' "${CONFIG_FILE}")

  # Ticks, rounded up: a window shorter than one interval still needs one tick.
  WORKTREE_TICKS=$(( (WORKTREE_MIN * 60 + INTERVAL - 1) / INTERVAL ))
  MAIN_TICKS=$(( (MAIN_MIN * 60 + INTERVAL - 1) / INTERVAL ))
  # `if` rather than `(( … )) && …`: a false arithmetic test exits 1, which under
  # set -e terminates the script whenever the clamp is NOT needed.
  if (( WORKTREE_TICKS < 1 )); then WORKTREE_TICKS=1; fi
  if (( MAIN_TICKS < 1 )); then MAIN_TICKS=1; fi
}

log() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >>"${LOG_FILE}"
}

is_exempt_container() {
  local name="$1"
  [[ -n "${EXEMPT_CONTAINERS}" ]] && [[ "${name}" =~ ^(${EXEMPT_CONTAINERS})$ ]]
}

is_exempt_project() {
  local name="$1"
  [[ -n "${EXEMPT_PROJECTS}" ]] && [[ "${name}" =~ ^(${EXEMPT_PROJECTS})$ ]]
}

# --- activity sampling ------------------------------------------------------

# One `docker stats` call for every container, cached for the whole tick.
# Per-container stats calls would take ~1s each and dominate runtime.
sample_cpu() {
  CPU_SAMPLE=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' 2>/dev/null || true)
}

cpu_for() {
  local name="$1" pct
  pct=$(printf '%s\n' "${CPU_SAMPLE}" | awk -v n="${name}" '$1 == n {gsub(/%/,"",$2); print $2; exit}')
  printf '%s' "${pct:-0}"
}

# Fingerprint of the newest log line across a stack's non-exempt containers.
# A change between ticks means the stack did something, which catches activity
# that finishes below the CPU threshold between samples (a served request, a
# completed query). Timestamps come from the daemon, so no clock skew.
log_fingerprint() {
  local cids="$1" cid out acc=""
  for cid in ${cids}; do
    out=$(docker logs --timestamps --tail 1 "${cid}" 2>&1 | tail -1 || true)
    acc="${acc}${out}"
  done
  printf '%s' "${acc}" | shasum -a 256 | cut -d' ' -f1
}

# --- state ------------------------------------------------------------------

read_state() {
  local project="$1" file="${STATE_DIR}/${1}.state"
  STATE_TICKS=0
  STATE_FP=""
  if [[ -f "${file}" ]]; then
    STATE_TICKS=$(cut -d' ' -f1 "${file}")
    STATE_FP=$(cut -d' ' -f2 "${file}")
  fi
  [[ "${STATE_TICKS}" =~ ^[0-9]+$ ]] || STATE_TICKS=0
}

write_state() {
  mkdir -p "${STATE_DIR}"
  printf '%s %s\n' "$2" "$3" >"${STATE_DIR}/${1}.state"
}

# --- main evaluation --------------------------------------------------------

evaluate() {
  local results="[]"
  sample_cpu

  local project config_files kind cids container_names cid name
  local active reason cpu fp limit stopped

  while IFS=$'\t' read -r project config_files; do
    [[ -z "${project}" ]] && continue

    if is_exempt_project "${project}"; then
      results=$(printf '%s' "${results}" | jq -c --arg p "${project}" \
        '. + [{project:$p, action:"skipped", reason:"exempt_project"}]')
      continue
    fi

    # Worktree classification is PATH-based, never name-based: the `medclear`
    # project runs out of medical-clearance/.worktrees/1BB3C5 despite having no
    # worktree suffix in its name, so a name heuristic misclassifies it as main.
    if [[ "${config_files}" == */.worktrees/* ]]; then
      kind="worktree"; limit="${WORKTREE_TICKS}"
    else
      kind="main"; limit="${MAIN_TICKS}"
    fi

    cids=$(docker ps -q --filter "label=com.docker.compose.project=${project}" || true)
    [[ -z "${cids}" ]] && continue

    # Drop exempt containers before any activity or stop decision, so a shared
    # service neither keeps a stack alive nor gets stopped with it.
    container_names=""
    local keep_cids=""
    for cid in ${cids}; do
      name=$(docker inspect --format '{{.Name}}' "${cid}" 2>/dev/null | sed 's|^/||')
      [[ -z "${name}" ]] && continue
      if is_exempt_container "${name}"; then
        continue
      fi
      if [[ "$(docker inspect --format '{{index .Config.Labels "dev.reaper.exempt"}}' "${cid}" 2>/dev/null)" == "true" ]]; then
        continue
      fi
      keep_cids="${keep_cids} ${cid}"
      container_names="${container_names} ${name}"
    done

    if [[ -z "${keep_cids// /}" ]]; then
      results=$(printf '%s' "${results}" | jq -c --arg p "${project}" --arg k "${kind}" \
        '. + [{project:$p, kind:$k, action:"skipped", reason:"all_containers_exempt"}]')
      continue
    fi

    # A container still starting or restart-looping is never idle — stopping it
    # mid-boot looks like a crash and hides the real failure.
    active=0; reason="idle"
    for cid in ${keep_cids}; do
      local health
      health=$(docker inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null || echo unknown)
      if [[ "${health}" == "restarting" || "${health}" == "created" ]]; then
        active=1; reason="container_${health}"; break
      fi
    done

    if (( active == 0 )); then
      for name in ${container_names}; do
        cpu=$(cpu_for "${name}")
        if awk -v c="${cpu}" -v t="${CPU_THRESHOLD}" 'BEGIN{exit !(c>t)}'; then
          active=1; reason="cpu_${cpu}"; break
        fi
      done
    fi

    read_state "${project}"
    fp=$(log_fingerprint "${keep_cids}")
    if (( active == 0 )) && [[ -n "${STATE_FP}" ]] && [[ "${fp}" != "${STATE_FP}" ]]; then
      active=1; reason="new_log_output"
    fi

    if (( active == 1 )); then
      write_state "${project}" 0 "${fp}"
      results=$(printf '%s' "${results}" | jq -c --arg p "${project}" --arg k "${kind}" --arg r "${reason}" \
        '. + [{project:$p, kind:$k, action:"active", reason:$r, idle_ticks:0}]')
      continue
    fi

    local ticks=$(( STATE_TICKS + 1 ))
    if (( ticks >= limit )); then
      stopped="${container_names# }"
      if (( DRY_RUN == 1 )); then
        results=$(printf '%s' "${results}" | jq -c --arg p "${project}" --arg k "${kind}" --arg c "${stopped}" \
          '. + [{project:$p, kind:$k, action:"would_stop", containers:($c|split(" "))}]')
        write_state "${project}" "${ticks}" "${fp}"
      else
        # shellcheck disable=SC2086
        docker stop ${keep_cids} >/dev/null 2>&1 || true
        log "stopped ${kind} stack ${project}: ${stopped}"
        write_state "${project}" 0 "${fp}"
        results=$(printf '%s' "${results}" | jq -c --arg p "${project}" --arg k "${kind}" --arg c "${stopped}" \
          '. + [{project:$p, kind:$k, action:"stopped", containers:($c|split(" "))}]')
      fi
    else
      write_state "${project}" "${ticks}" "${fp}"
      local remaining=$(( (limit - ticks) * INTERVAL / 60 ))
      results=$(printf '%s' "${results}" | jq -c \
        --arg p "${project}" --arg k "${kind}" \
        --argjson t "${ticks}" --argjson l "${limit}" --argjson m "${remaining}" \
        '. + [{project:$p, kind:$k, action:"idle", idle_ticks:$t, ticks_until_stop:$l, minutes_until_stop:$m}]')
    fi
  done < <(docker compose ls --format json 2>/dev/null | jq -r '.[] | [.Name, .ConfigFiles] | @tsv')

  RESULTS="${results}"
}

cmd_run() {
  load_config
  evaluate
  local stopped_count
  stopped_count=$(printf '%s' "${RESULTS}" | jq '[.[] | select(.action=="stopped")] | length')
  if (( JSON_OUT == 1 )) || (( DRY_RUN == 1 )); then
    printf '%s' "${RESULTS}" | jq --argjson s "${stopped_count}" \
      '{status:"ok", dry_run:'"${DRY_RUN}"', stopped:$s, stacks:.}'
  else
    if (( stopped_count > 0 )); then
      printf '%s' "${RESULTS}" | jq -r \
        '.[] | select(.action=="stopped") | "reaped \(.kind) stack \(.project): \(.containers|join(", "))"'
    fi
  fi
}

cmd_status() {
  load_config
  DRY_RUN=1
  evaluate
  if (( JSON_OUT == 1 )); then
    printf '%s' "${RESULTS}" | jq \
      '{status:"ok", worktree_window_minutes:'"${WORKTREE_MIN}"', main_window_minutes:'"${MAIN_MIN}"', stacks:.}'
  else
    printf 'worktree window: %s min · main window: %s min · interval: %ss\n\n' \
      "${WORKTREE_MIN}" "${MAIN_MIN}" "${INTERVAL}"
    printf '%s' "${RESULTS}" | jq -r \
      '.[] | "\(.project)\t\(.kind // "-")\t\(.action)\t\(.reason // (.minutes_until_stop|tostring) + " min left")"' \
      | column -t -s$'\t'
  fi
}

cmd_install() {
  mkdir -p "$(dirname "${PLIST}")" "$(dirname "${LOG_FILE}")"
  load_config
  cat >"${PLIST}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${HOME}/.claude/scripts/docker-idle-reaper.sh</string>
    <string>run</string>
    <string>--json</string>
  </array>
  <key>StartInterval</key><integer>${INTERVAL}</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${LOG_FILE}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST_EOF
  launchctl unload "${PLIST}" 2>/dev/null || true
  launchctl load "${PLIST}"
  printf '{"status":"ok","message":"LaunchAgent installed","details":{"plist":"%s","interval_seconds":%s,"log":"%s"}}\n' \
    "${PLIST}" "${INTERVAL}" "${LOG_FILE}"
}

cmd_uninstall() {
  launchctl unload "${PLIST}" 2>/dev/null || true
  rm -f "${PLIST}"
  printf '{"status":"ok","message":"LaunchAgent removed"}\n'
}

# --- arg parsing ------------------------------------------------------------

for arg in "$@"; do
  case "${arg}" in
    run|status|install|uninstall) SUBCOMMAND="${arg}" ;;
    --dry-run) DRY_RUN=1 ;;
    --json) JSON_OUT=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) printf '{"status":"error","message":"unknown argument","details":"%s"}\n' "${arg}"; exit 1 ;;
  esac
done

case "${SUBCOMMAND}" in
  run) cmd_run ;;
  status) cmd_status ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
esac
