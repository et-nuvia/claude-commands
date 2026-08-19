#!/usr/bin/env bash
set -euo pipefail

# Clean docker ps output: container id, name, uptime, host ports only
# Uses docker inspect for ports (docker ps {{.Ports}} is extremely slow)
# Usage: docker-ps.sh [docker ps flags, e.g. -a, --filter]

# Requires bash >= 4 (mapfile, declare -A). macOS ships bash 3.2 by default.
if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: docker-ps.sh requires bash >= 4 (brew install bash)" >&2
  exit 1
fi

fmt="%-14s %-30s %-40s %s\n"
printf "${fmt}" "CONTAINER ID" "NAME" "STATUS" "HOST PORTS"

# Get container IDs matching the filter
mapfile -t ids < <(docker ps "$@" --format '{{.ID}}')
[[ ${#ids[@]} -eq 0 ]] && exit 0

# Bulk inspect for ports (sub-second vs 60s with docker ps .Ports)
declare -A port_map
while IFS=$'\t' read -r cid ports_json; do
  short_id="${cid:0:12}"
  host_ports=""
  if [[ "${ports_json}" != "null" && "${ports_json}" != "{}" ]]; then
    declare -A seen=()
    remainder="${ports_json}"
    while [[ "${remainder}" =~ \"HostPort\":\"([0-9]+)\" ]]; do
      port="${BASH_REMATCH[1]}"
      if [[ -z "${seen[${port}]+x}" ]]; then
        seen[${port}]=1
        host_ports="${host_ports:+${host_ports},}${port}"
      fi
      remainder="${remainder#*"${BASH_REMATCH[0]}"}"
    done
    unset seen
  fi
  port_map[${short_id}]="${host_ports:--}"
done < <(docker inspect --format '{{.Id}}'$'\t''{{json .NetworkSettings.Ports}}' "${ids[@]}")

# Output using docker ps for status (already fast without .Ports)
docker ps "$@" --format '{{.ID}}\t{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r id name status; do
  printf "${fmt}" "${id}" "${name}" "${status}" "${port_map[${id}]:--}"
done
