#!/usr/bin/env bash
# asana.sh — Asana REST API shim (replaces the asana-mcp container)
#
# Drop-in replacement for the mcp__asana__* tools: each subcommand mirrors an
# MCP tool and prints the raw Asana `.data` payload as JSON (same contract the
# MCP server returned). Errors print a JSON object to stderr and exit non-zero.
#
# Auth:      ASANA_ACCESS_TOKEN env var, else ~/.asana-token
# Workspace: --workspace arg → PROJECT.yaml .task_management.asana.workspace_id
#            → ~/.asana-workspace → ASANA_WORKSPACE_GID env var
#
# Names vs GIDs: anywhere a workspace/project/section/custom-field accepts a
# value, an all-digits string is treated as a GID; anything else is fuzzy
# matched by name (exact match first, then substring), same as the MCP server.
#
# Usage: asana.sh <command> [options]
#
# Commands (MCP tool equivalents):
#   list-workspaces
#   list-projects        [--workspace W] [--archived true|false]
#   list-tasks           [--assignee A] [--project P] [--workspace W]
#                        [--completed-since TS] [--modified-since TS] [--limit N]
#   get-task             <task_gid> [--raw]
#   list-sections        --project P
#   create-task          --name N [--notes T] [--assignee A] [--due-on D]
#                        [--due-at TS] [--project P]... [--workspace W]
#                        [--section S] [--tag GID]...
#   update-task          <task_gid> [--name N] [--notes T] [--assignee A]
#                        [--due-on D] [--due-at TS] [--completed true|false]
#   complete-task        <task_gid>
#   add-comment          <task_gid> --text T
#   list-comments        <task_gid>
#   search-tasks         [--workspace W] [--text T] [--completed true|false]
#                        [--assignee A] [--project P]...
#   get-current-user
#   get-user             <user_gid>
#   get-custom-fields    --project P
#   update-custom-field  <task_gid> --field F --value V [--project P]
#                        [--if-supported]
#   check-fields         [--project P]
#
# Project structure (sections and which custom fields a project carries):
#   list-section-tasks   --section S [--project P] [--completed true|false]
#                        [--with-fields]
#   create-section       --project P --name N [--before S] [--after S]
#   delete-section       --section S [--project P]
#   list-workspace-fields [--workspace W] [--name N]
#   add-project-field    --project P --field F [--important true|false]
#   remove-project-field --project P --field F
#
# Custom fields: --field accepts a PROJECT.yaml logical key (status, priority,
# requesting_user, ...), a display name, or a GID. Configured keys resolve via
# .task_management.asana.custom_fields.<key>.gid, so per-project name drift
# ("Status" vs "Status Dev") and trailing spaces ("Priority ") do not matter.
# Enum values likewise resolve through the configured options map
# (hold, in_progress, high, ...) before falling back to name matching.
# Pass --if-supported to turn an unsupported field/value into a skipped no-op
# (exit 0) instead of an error. Run check-fields to see what a project can set
# and to surface config drift.
#   move-task-to-section <task_gid> --section S [--project P]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_BASE="https://app.asana.com/api/1.0"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() {
    jq -n --arg msg "$1" '{error: $msg}' >&2
    exit 1
}

load_token() {
    if [[ -n "${ASANA_ACCESS_TOKEN:-}" ]]; then
        TOKEN="${ASANA_ACCESS_TOKEN}"
    elif [[ -f "${HOME}/.asana-token" ]]; then
        TOKEN="$(<"${HOME}/.asana-token")"
    else
        die "No Asana token: set ASANA_ACCESS_TOKEN or create ~/.asana-token"
    fi
}

# api METHOD PATH [JSON_BODY] — prints response body, dies on HTTP >= 400
api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "$method" -H "Authorization: Bearer ${TOKEN}" -w $'\n%{http_code}')
    if [[ -n "$body" ]]; then
        args+=(-H "Content-Type: application/json" -d "$body")
    fi
    local resp code json
    resp="$(curl "${args[@]}" "${API_BASE}${path}")" || die "curl failed for ${method} ${path}"
    code="${resp##*$'\n'}"
    json="${resp%$'\n'*}"
    if [[ "$code" -ge 400 ]]; then
        echo "$json" | jq --arg code "$code" --arg path "$path" \
            '{error: (.errors[0].message // "HTTP \($code)"), http_status: ($code | tonumber), path: $path, errors: (.errors // [])}' >&2
        exit 1
    fi
    echo "$json"
}

# fuzzy_pick NEEDLE — stdin: JSON array of {gid, name}; prints gid or empty.
# Priority mirrors the MCP server's fuzzyMatch: exact (ci) > contains (ci).
fuzzy_pick() {
    jq -r --arg n "$1" '
        ($n | ascii_downcase) as $needle
        | ([.[] | select(((.name // "") | ascii_downcase) == $needle)]
           + [.[] | select(((.name // "") | ascii_downcase) | contains($needle))])
        | (first // empty) | .gid'
}

is_gid() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ---------------------------------------------------------------------------
# PROJECT.yaml custom-field configuration
#
# Custom fields differ per project: names drift ("Status" in config vs
# "Status Dev" in Asana), carry trailing spaces ("Priority "), or the field
# simply does not exist in that project. Matching by NAME against the live API
# is therefore unreliable and was the main source of hard failures.
#
# PROJECT.yaml records the authoritative GIDs under
# .task_management.asana.custom_fields.<key>.{gid,name,type,options}, so a
# configured project resolves logical key -> GID -> enum option GID with no
# name matching at all. Name/API matching remains as the fallback for projects
# that have no config.
# ---------------------------------------------------------------------------

PROJECT_YAML=""
_PROJECT_YAML_SEARCHED=false

# find_project_yaml — walk up from cwd; PROJECT.yaml is not always in cwd
# (worktrees, backend/ subdirs). Sets PROJECT_YAML to a path or empty.
find_project_yaml() {
    if ${_PROJECT_YAML_SEARCHED}; then return 0; fi
    _PROJECT_YAML_SEARCHED=true
    local dir; dir="$(pwd)"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "${dir}/PROJECT.yaml" ]]; then
            PROJECT_YAML="${dir}/PROJECT.yaml"
            break
        fi
        dir="$(dirname "$dir")"
    done
    if [[ -n "$PROJECT_YAML" && -f "${SCRIPT_DIR}/lib/yaml.sh" ]]; then
        # shellcheck source=lib/yaml.sh
        source "${SCRIPT_DIR}/lib/yaml.sh" 2>/dev/null || true
    fi
}

cfg() {
    find_project_yaml
    [[ -n "$PROJECT_YAML" ]] || return 0
    yaml_get "$1" "$PROJECT_YAML" 2>/dev/null || true
}

# normalize_key VALUE — "In progress" -> "in_progress", "HIGH" -> "high".
# Matches the option-key style used in PROJECT.yaml.
normalize_key() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' -' '__' | tr -cd 'a-z0-9_'
}

# config_field_keys — logical keys configured for this project, one per line.
# go-yq reproduces a key's head comment in `keys` output, so any commented
# block inside custom_fields would otherwise surface as bogus field keys.
config_field_keys() {
    cfg '.task_management.asana.custom_fields | keys | .[]' | grep -v '^[[:space:]]*#' || true
}

# config_field_key FIELD — resolve user input (logical key, display name, or
# GID) to the logical config key. Empty if unconfigured.
config_field_key() {
    local want; want="$(normalize_key "$1")"
    local key name gid
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        [[ "$(normalize_key "$key")" == "$want" ]] && { echo "$key"; return 0; }
        name="$(cfg ".task_management.asana.custom_fields.${key}.name")"
        # Trailing/leading spaces in configured names are common — normalize_key
        # strips them, so "Priority " and "Priority" compare equal.
        [[ -n "$name" && "$(normalize_key "$name")" == "$want" ]] && { echo "$key"; return 0; }
        gid="$(cfg ".task_management.asana.custom_fields.${key}.gid")"
        [[ -n "$gid" && "$gid" == "$1" ]] && { echo "$key"; return 0; }
    done < <(config_field_keys)
    # No match is a normal outcome (unconfigured project / unknown field), so
    # return success — a non-zero here would trip `set -e` in the caller's
    # command substitution and abort before the fallback path runs.
    return 0
}

config_field_gid()  { cfg ".task_management.asana.custom_fields.${1}.gid"; }
config_field_type() { cfg ".task_management.asana.custom_fields.${1}.type"; }

# config_option_gid KEY VALUE — enum option GID from config, or empty.
# The option key is bracket-quoted: numeric option names (the Score field's
# fibonacci values "1", "2", "5", ...) are legal YAML keys but produce an
# invalid filter as a bare `.options.1`, so they must be indexed as a string.
config_option_gid() {
    local key="$1" opt; opt="$(normalize_key "$2")"
    [[ -n "$opt" ]] || return 0
    cfg ".task_management.asana.custom_fields.${key}.options[\"${opt}\"]"
}

config_option_keys() {
    cfg ".task_management.asana.custom_fields.${1}.options | keys | .[]"
}

# default_workspace — PROJECT.yaml → ~/.asana-workspace → env
default_workspace() {
    local ws=""
    if [[ -f "PROJECT.yaml" && -f "${SCRIPT_DIR}/lib/yaml.sh" ]]; then
        # shellcheck source=lib/yaml.sh
        source "${SCRIPT_DIR}/lib/yaml.sh" 2>/dev/null || true
        ws="$(yaml_get '.task_management.asana.workspace_id' PROJECT.yaml 2>/dev/null || true)"
    fi
    if [[ -z "$ws" && -f "${HOME}/.asana-workspace" ]]; then
        ws="$(<"${HOME}/.asana-workspace")"
    fi
    if [[ -z "$ws" ]]; then
        ws="${ASANA_WORKSPACE_GID:-}"
    fi
    [[ -n "$ws" ]] || die "No workspace: pass --workspace, set PROJECT.yaml task_management.asana.workspace_id, or create ~/.asana-workspace"
    echo "$ws"
}

resolve_workspace() {
    local w="${1:-}"
    if [[ -z "$w" ]]; then default_workspace; return; fi
    if is_gid "$w"; then echo "$w"; return; fi
    local gid
    gid="$(api GET "/workspaces" | jq '.data' | fuzzy_pick "$w")"
    [[ -n "$gid" ]] || die "Workspace not found: ${w}"
    echo "$gid"
}

resolve_project() {
    local p="$1"
    if is_gid "$p"; then echo "$p"; return; fi
    local ws gid
    ws="$(default_workspace)"
    gid="$(api GET "/projects?workspace=${ws}" | jq '.data' | fuzzy_pick "$p")"
    [[ -n "$gid" ]] || die "Project not found: ${p}"
    echo "$gid"
}

# resolve_section PROJECT_GID NAME_OR_GID
resolve_section() {
    local project_gid="$1" s="$2"
    if is_gid "$s"; then echo "$s"; return; fi
    local gid
    gid="$(api GET "/projects/${project_gid}/sections" | jq '.data' | fuzzy_pick "$s")"
    [[ -n "$gid" ]] || die "Section not found in project ${project_gid}: ${s}"
    echo "$gid"
}

# task_project TASK_GID — first project from memberships, else projects[0]
task_project() {
    local gid
    gid="$(api GET "/tasks/$1" | jq -r '.data | (.memberships[0].project.gid // .projects[0].gid // empty)')"
    [[ -n "$gid" ]] || die "Task $1 has no project; pass --project explicitly"
    echo "$gid"
}

usage() {
    # Print the whole leading comment block, so added subcommands show up in
    # --help without anyone having to re-count line numbers here.
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
    exit 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_list_workspaces() {
    api GET "/workspaces" | jq '.data'
}

cmd_list_projects() {
    local workspace="" archived=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) workspace="$2"; shift 2 ;;
            --archived)  archived="$2"; shift 2 ;;
            *) die "Unknown option for list-projects: $1" ;;
        esac
    done
    local ws qs
    ws="$(resolve_workspace "$workspace")"
    qs="workspace=${ws}"
    [[ -n "$archived" ]] && qs+="&archived=${archived}"
    api GET "/projects?${qs}" | jq '.data'
}

cmd_list_tasks() {
    local assignee="" workspace="" project="" completed_since="" modified_since="" limit=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --assignee)        assignee="$2"; shift 2 ;;
            --workspace)       workspace="$2"; shift 2 ;;
            --project)         project="$2"; shift 2 ;;
            --completed-since) completed_since="$2"; shift 2 ;;
            --modified-since)  modified_since="$2"; shift 2 ;;
            --limit)           limit="$2"; shift 2 ;;
            *) die "Unknown option for list-tasks: $1" ;;
        esac
    done
    local qs=""
    # Asana requires project OR workspace+assignee — never both (MCP parity)
    if [[ -n "$project" ]]; then
        qs="project=$(resolve_project "$project")"
        [[ -n "$assignee" ]] && qs+="&assignee=${assignee}"
    else
        qs="workspace=$(resolve_workspace "$workspace")"
        qs+="&assignee=${assignee:-me}"
    fi
    [[ -n "$completed_since" ]] && qs+="&completed_since=${completed_since}"
    [[ -n "$modified_since" ]] && qs+="&modified_since=${modified_since}"
    [[ -n "$limit" ]] && qs+="&limit=${limit}"
    api GET "/tasks?${qs}" | jq '.data'
}

cmd_get_task() {
    local gid="" raw=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --raw) raw=true; shift ;;
            *) [[ -n "$gid" ]] && die "Unknown option for get-task: $1"; gid="$1"; shift ;;
        esac
    done
    [[ -n "$gid" ]] || die "Usage: asana.sh get-task <task_gid> [--raw]"

    if [[ "$raw" == "true" ]]; then
        api GET "/tasks/${gid}" | jq '.data'
        return
    fi

    # Projected fields only — trims the full task payload (which includes
    # dozens of internal fields the LLM never needs) down to what task-capture
    # actually consumes.
    local opt_fields="name,notes,html_notes,assignee.name,due_on,projects.name,permalink_url,completed,custom_fields.name,custom_fields.display_value"
    api GET "/tasks/${gid}?opt_fields=${opt_fields}" | jq '.data
        | {
            name, notes, html_notes,
            assignee: (.assignee.name // null),
            due_on, completed, permalink_url,
            projects: [(.projects // [])[].name],
            custom_fields: [(.custom_fields // [])[] | {name, display_value}]
          }'
}

cmd_list_sections() {
    local project=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            *) die "Unknown option for list-sections: $1" ;;
        esac
    done
    [[ -n "$project" ]] || die "Usage: asana.sh list-sections --project <name|gid>"
    api GET "/projects/$(resolve_project "$project")/sections" | jq '.data'
}

cmd_create_task() {
    local name="" notes="" assignee="" due_on="" due_at="" workspace="" section=""
    local projects=() tags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)      name="$2"; shift 2 ;;
            --notes)     notes="$2"; shift 2 ;;
            --assignee)  assignee="$2"; shift 2 ;;
            --due-on)    due_on="$2"; shift 2 ;;
            --due-at)    due_at="$2"; shift 2 ;;
            --project)   projects+=("$2"); shift 2 ;;
            --workspace) workspace="$2"; shift 2 ;;
            --section)   section="$2"; shift 2 ;;
            --tag)       tags+=("$2"); shift 2 ;;
            *) die "Unknown option for create-task: $1" ;;
        esac
    done
    [[ -n "$name" ]] || die "Usage: asana.sh create-task --name <name> [options]"

    local project_gids=()
    local p
    for p in "${projects[@]+"${projects[@]}"}"; do
        project_gids+=("$(resolve_project "$p")")
    done

    local body
    body="$(jq -n --arg name "$name" '{data: {name: $name}}')"
    [[ -n "$notes" ]]    && body="$(echo "$body" | jq --arg v "$notes" '.data.notes = $v')"
    [[ -n "$assignee" ]] && body="$(echo "$body" | jq --arg v "$assignee" '.data.assignee = $v')"
    [[ -n "$due_on" ]]   && body="$(echo "$body" | jq --arg v "$due_on" '.data.due_on = $v')"
    [[ -n "$due_at" ]]   && body="$(echo "$body" | jq --arg v "$due_at" '.data.due_at = $v')"

    if [[ ${#project_gids[@]} -gt 0 ]]; then
        body="$(echo "$body" | jq --argjson v "$(printf '%s\n' "${project_gids[@]}" | jq -R . | jq -s .)" '.data.projects = $v')"
        if [[ -n "$section" ]]; then
            # Section placement requires a memberships entry (MCP parity)
            local section_gid
            section_gid="$(resolve_section "${project_gids[0]}" "$section")"
            body="$(echo "$body" | jq --arg p "${project_gids[0]}" --arg s "$section_gid" \
                '.data.memberships = [{project: $p, section: $s}]')"
        fi
    else
        body="$(echo "$body" | jq --arg v "$(resolve_workspace "$workspace")" '.data.workspace = $v')"
        [[ -n "$section" ]] && die "create-task --section requires at least one --project"
    fi
    if [[ ${#tags[@]} -gt 0 ]]; then
        body="$(echo "$body" | jq --argjson v "$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)" '.data.tags = $v')"
    fi
    # opt_fields ensures permalink_url is present for External Tracking sections
    api POST "/tasks?opt_fields=gid,name,permalink_url,notes,assignee.name,due_on,due_at,completed,projects.name,memberships.section.name" "$body" | jq '.data'
}

cmd_update_task() {
    local gid="${1:-}"
    [[ -n "$gid" && "$gid" != --* ]] || die "Usage: asana.sh update-task <task_gid> [options]"
    shift
    local body='{"data":{}}'
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)      body="$(echo "$body" | jq --arg v "$2" '.data.name = $v')"; shift 2 ;;
            --notes)     body="$(echo "$body" | jq --arg v "$2" '.data.notes = $v')"; shift 2 ;;
            --assignee)  body="$(echo "$body" | jq --arg v "$2" '.data.assignee = $v')"; shift 2 ;;
            --due-on)    body="$(echo "$body" | jq --arg v "$2" '.data.due_on = $v')"; shift 2 ;;
            --due-at)    body="$(echo "$body" | jq --arg v "$2" '.data.due_at = $v')"; shift 2 ;;
            --completed) body="$(echo "$body" | jq --argjson v "$2" '.data.completed = $v')"; shift 2 ;;
            *) die "Unknown option for update-task: $1" ;;
        esac
    done
    [[ "$(echo "$body" | jq '.data | length')" -gt 0 ]] || die "update-task: no fields to update"
    api PUT "/tasks/${gid}" "$body" | jq '.data'
}

cmd_complete_task() {
    local gid="${1:-}"
    [[ -n "$gid" ]] || die "Usage: asana.sh complete-task <task_gid>"
    api PUT "/tasks/${gid}" '{"data":{"completed":true}}' | jq '.data'
}

cmd_add_comment() {
    local gid="${1:-}" text=""
    [[ -n "$gid" && "$gid" != --* ]] || die "Usage: asana.sh add-comment <task_gid> --text <text>"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --text) text="$2"; shift 2 ;;
            *) die "Unknown option for add-comment: $1" ;;
        esac
    done
    [[ -n "$text" ]] || die "add-comment: --text is required"
    api POST "/tasks/${gid}/stories" "$(jq -n --arg t "$text" '{data: {text: $t}}')" | jq '.data'
}

cmd_list_comments() {
    local gid="${1:-}"
    [[ -n "$gid" ]] || die "Usage: asana.sh list-comments <task_gid>"
    api GET "/tasks/${gid}/stories" | jq '.data'
}

cmd_search_tasks() {
    local workspace="" text="" completed="" assignee=""
    local projects=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) workspace="$2"; shift 2 ;;
            --text)      text="$2"; shift 2 ;;
            --completed) completed="$2"; shift 2 ;;
            --assignee)  assignee="$2"; shift 2 ;;
            --project)   projects+=("$2"); shift 2 ;;
            *) die "Unknown option for search-tasks: $1" ;;
        esac
    done
    local ws qs
    ws="$(resolve_workspace "$workspace")"
    qs=""
    if [[ -n "$text" ]]; then
        qs+="&text=$(jq -rn --arg v "$text" '$v | @uri')"
    fi
    [[ -n "$completed" ]] && qs+="&completed=${completed}"
    [[ -n "$assignee" ]] && qs+="&assignee.any=${assignee}"
    local p
    for p in "${projects[@]+"${projects[@]}"}"; do
        qs+="&projects.any=$(resolve_project "$p")"
    done
    api GET "/workspaces/${ws}/tasks/search?${qs#&}" | jq '.data'
}

cmd_get_current_user() {
    api GET "/users/me" | jq '.data'
}

cmd_get_user() {
    local gid="${1:-}"
    [[ -n "$gid" ]] || die "Usage: asana.sh get-user <user_gid>"
    api GET "/users/${gid}" | jq '.data'
}

cmd_get_custom_fields() {
    local project=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            *) die "Unknown option for get-custom-fields: $1" ;;
        esac
    done
    [[ -n "$project" ]] || die "Usage: asana.sh get-custom-fields --project <name|gid>"
    api GET "/projects/$(resolve_project "$project")/custom_field_settings" | jq '.data'
}

cmd_update_custom_field() {
    local gid="${1:-}" field="" value="" project="" if_supported=false
    [[ -n "$gid" && "$gid" != --* ]] || die "Usage: asana.sh update-custom-field <task_gid> --field <key|name|gid> --value <value> [--project <name|gid>] [--if-supported]"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --field)        field="$2"; shift 2 ;;
            --value)        value="$2"; shift 2 ;;
            --project)      project="$2"; shift 2 ;;
            --if-supported) if_supported=true; shift ;;
            *) die "Unknown option for update-custom-field: $1" ;;
        esac
    done
    [[ -n "$field" && -n "$value" ]] || die "update-custom-field: --field and --value are required"

    # skip_or_die — with --if-supported an unsupported field/value is a normal
    # no-op, so callers that sync several fields across differently-configured
    # projects don't abort partway through.
    skip_or_die() {
        if ${if_supported}; then
            jq -n --arg f "$field" --arg v "$value" --arg r "$1" \
                '{status: "skipped", field: $f, value: $v, reason: $r}'
            exit 0
        fi
        die "$1"
    }

    local project_gid
    if [[ -n "$project" ]]; then
        project_gid="$(resolve_project "$project")"
    else
        project_gid="$(task_project "$gid")"
    fi

    local settings field_json field_gid field_type cfg_key=""
    settings="$(api GET "/projects/${project_gid}/custom_field_settings")"

    # Resolution order: explicit GID → PROJECT.yaml config → live-API name match.
    if is_gid "$field"; then
        field_gid="$field"
    else
        cfg_key="$(config_field_key "$field")"
        if [[ -n "$cfg_key" ]]; then
            field_gid="$(config_field_gid "$cfg_key")"
        fi
        if [[ -z "${field_gid:-}" ]]; then
            field_gid="$(echo "$settings" | jq '[.data[].custom_field]' | fuzzy_pick "$field")"
        fi
    fi
    [[ -n "${field_gid:-}" ]] || skip_or_die "Custom field not found in project ${project_gid}: ${field}"

    field_json="$(echo "$settings" | jq --arg g "$field_gid" '[.data[].custom_field | select(.gid == $g)] | first // empty')"
    # A configured GID that the project does not actually carry is a config
    # error, not a transient one — report it as such rather than 400ing later.
    if [[ -z "$field_json" ]]; then
        if [[ -n "$cfg_key" ]]; then
            skip_or_die "Field '${cfg_key}' (gid ${field_gid}) from PROJECT.yaml is not attached to project ${project_gid}. Run: asana.sh check-fields"
        fi
        skip_or_die "Custom field gid ${field_gid} is not attached to project ${project_gid}"
    fi

    field_type="$(echo "$field_json" | jq -r '.resource_subtype // empty')"

    # Enum values: config option map → live enum_options fuzzy match.
    #
    # An all-digits value is NOT assumed to be a GID here: the Score field's
    # option names are fibonacci numbers ("1", "2", "5", ...), so is_gid() is
    # true for a plain option name and would send it as an option GID —
    # producing "enum_value: Unknown object: 5". Only a value that actually
    # matches one of this field's option GIDs is passed through verbatim.
    local resolved="$value"
    if [[ "$field_type" == "enum" ]] \
        && ! echo "$field_json" | jq -e --arg o "$value" 'any(.enum_options[]?; .gid == $o)' >/dev/null; then
        resolved=""
        if [[ -n "$cfg_key" ]]; then
            resolved="$(config_option_gid "$cfg_key" "$value")"
            # Guard against a stale option GID lingering in PROJECT.yaml.
            if [[ -n "$resolved" ]] && ! echo "$field_json" | jq -e --arg o "$resolved" '.enum_options[]? | select(.gid == $o)' >/dev/null; then
                resolved=""
            fi
        fi
        if [[ -z "$resolved" ]]; then
            resolved="$(echo "$field_json" | jq '.enum_options // []' | fuzzy_pick "$value")"
        fi
        if [[ -z "$resolved" ]]; then
            local allowed; allowed="$(echo "$field_json" | jq -r '[.enum_options[]?.name] | join(", ")')"
            skip_or_die "Enum option not found for field '${field}': '${value}'. Allowed: ${allowed}"
        fi
    fi

    local body
    if [[ "$field_type" == "number" ]]; then
        body="$(jq -n --arg f "$field_gid" --argjson v "$resolved" '{data: {custom_fields: {($f): $v}}}')"
    else
        body="$(jq -n --arg f "$field_gid" --arg v "$resolved" '{data: {custom_fields: {($f): $v}}}')"
    fi
    api PUT "/tasks/${gid}" "$body" | jq '.data'
}

# check-fields — reconcile PROJECT.yaml custom_fields against what the project
# actually carries. Answers "what can and cannot be set here" without a task,
# and surfaces config drift (renamed fields, stale option GIDs, detached
# fields) before a sync fails mid-workflow.
cmd_check_fields() {
    local project=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            *) die "Unknown option for check-fields: $1" ;;
        esac
    done

    find_project_yaml
    local project_gid
    if [[ -n "$project" ]]; then
        project_gid="$(resolve_project "$project")"
    else
        project_gid="$(cfg '.task_management.asana.project_id')"
        [[ -n "$project_gid" ]] || die "check-fields: pass --project, or set task_management.asana.project_id in PROJECT.yaml"
    fi

    local settings live
    settings="$(api GET "/projects/${project_gid}/custom_field_settings")"
    live="$(echo "$settings" | jq '[.data[].custom_field]')"

    local out='[]' key gid name cfg_type actual entry opts
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        gid="$(config_field_gid "$key")"
        name="$(cfg ".task_management.asana.custom_fields.${key}.name")"
        cfg_type="$(config_field_type "$key")"
        actual="$(echo "$live" | jq --arg g "$gid" '[.[] | select(.gid == $g)] | first // empty')"

        if [[ -z "$actual" ]]; then
            entry="$(jq -n --arg k "$key" --arg g "$gid" --arg n "$name" \
                '{key: $k, gid: $g, configured_name: $n, settable: false,
                  problem: "gid in PROJECT.yaml is not attached to this project"}')"
        else
            # Report each configured enum option that no longer exists upstream.
            opts='[]'
            while IFS= read -r o; do
                [[ -n "$o" ]] || continue
                local ogid ovalid
                ogid="$(config_option_gid "$key" "$o")"
                ovalid=$(echo "$actual" | jq --arg g "$ogid" 'any(.enum_options[]?; .gid == $g)')
                opts="$(echo "$opts" | jq --arg o "$o" --arg g "$ogid" --argjson v "$ovalid" \
                    '. + [{option: $o, gid: $g, valid: $v}]')"
            done < <(config_option_keys "$key")

            entry="$(jq -n --arg k "$key" --arg g "$gid" --arg n "$name" --arg t "$cfg_type" \
                --argjson a "$actual" --argjson o "$opts" \
                '{key: $k, gid: $g, settable: true,
                  configured_name: $n, actual_name: ($a.name // ""),
                  name_matches: (($n | ascii_downcase | gsub("^\\s+|\\s+$"; "")) == (($a.name // "") | ascii_downcase | gsub("^\\s+|\\s+$"; ""))),
                  configured_type: $t, actual_type: ($a.resource_subtype // ""),
                  read_only: ($a.is_value_read_only // false),
                  options: $o,
                  allowed_values: [$a.enum_options[]?.name]}')"
        fi
        out="$(echo "$out" | jq --argjson e "$entry" '. + [$e]')"
    done < <(config_field_keys)

    # Fields the project has but PROJECT.yaml never declared — settable only by
    # name/GID, and candidates for adding to config.
    local unconfigured='[]' cfg_gids
    cfg_gids="$(config_field_keys | while IFS= read -r k; do [[ -n "$k" ]] && config_field_gid "$k"; done | jq -R . | jq -s .)"
    [[ -n "$cfg_gids" ]] || cfg_gids='[]'
    unconfigured="$(echo "$live" | jq --argjson known "$cfg_gids" \
        '[.[] | select(.gid as $g | ($known | index($g)) | not)
              | {gid, name, type: .resource_subtype, allowed_values: [.enum_options[]?.name]}]')"

    jq -n --arg p "$project_gid" --arg y "${PROJECT_YAML:-}" \
        --argjson c "$out" --argjson u "$unconfigured" \
        '{project_gid: $p, project_yaml: $y, configured: $c, unconfigured_in_project_yaml: $u,
          problems: [$c[] | select(.settable == false or .name_matches == false or (.options // [] | any(.valid == false)))]}'
}

cmd_move_task_to_section() {
    local gid="${1:-}" section="" project=""
    [[ -n "$gid" && "$gid" != --* ]] || die "Usage: asana.sh move-task-to-section <task_gid> --section <name|gid> [--project <name|gid>]"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --section) section="$2"; shift 2 ;;
            --project) project="$2"; shift 2 ;;
            *) die "Unknown option for move-task-to-section: $1" ;;
        esac
    done
    [[ -n "$section" ]] || die "move-task-to-section: --section is required"

    local project_gid section_gid
    if [[ -n "$project" ]]; then
        project_gid="$(resolve_project "$project")"
    else
        project_gid="$(task_project "$gid")"
    fi
    section_gid="$(resolve_section "$project_gid" "$section")"
    api POST "/sections/${section_gid}/addTask" "$(jq -n --arg t "$gid" '{data: {task: $t}}')" | jq '.'
}

# ---------------------------------------------------------------------------
# Project structure
#
# Sections and custom-field attachment are project *structure*, not task data.
# They are what makes one project match the standard layout (Current Sprint /
# Bugs / Backlog + Status Dev / Complexity / Sprint / Score), so onboarding a
# new project — or reconciling an old one — is scriptable instead of manual
# clicking in the Asana UI.
# ---------------------------------------------------------------------------

cmd_list_section_tasks() {
    local section="" project="" completed="" with_fields=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --section)     section="$2"; shift 2 ;;
            --project)     project="$2"; shift 2 ;;
            --completed)   completed="$2"; shift 2 ;;
            --with-fields) with_fields=true; shift ;;
            *) die "Unknown option for list-section-tasks: $1" ;;
        esac
    done
    [[ -n "$section" ]] || die "Usage: asana.sh list-section-tasks --section <name|gid> [--project P] [--completed true|false] [--with-fields]"

    local section_gid
    if is_gid "$section"; then
        section_gid="$section"
    else
        [[ -n "$project" ]] || die "list-section-tasks: --project is required when --section is a name"
        section_gid="$(resolve_section "$(resolve_project "$project")" "$section")"
    fi

    # --with-fields folds each task's custom fields into the listing. Sprint
    # planning needs Score/Sprint for every backlog item at once; without this
    # the caller has to issue one get-task per task just to read two fields.
    local opt_fields="name,completed"
    local tasks
    if [[ "$with_fields" == "true" ]]; then
        opt_fields+=",custom_fields.name,custom_fields.display_value"
        tasks="$(api GET "/sections/${section_gid}/tasks?opt_fields=${opt_fields}" \
            | jq '[.data[] | {gid, name, completed,
                              custom_fields: [(.custom_fields // [])[] | {name, display_value}]}]')"
    else
        tasks="$(api GET "/sections/${section_gid}/tasks?opt_fields=${opt_fields}" | jq '.data')"
    fi
    case "$completed" in
        true)  echo "$tasks" | jq '[.[] | select(.completed == true)]' ;;
        false) echo "$tasks" | jq '[.[] | select(.completed != true)]' ;;
        "")    echo "$tasks" ;;
        *) die "list-section-tasks: --completed must be true or false" ;;
    esac
}

cmd_create_section() {
    local project="" name="" before="" after=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            --name)    name="$2"; shift 2 ;;
            --before)  before="$2"; shift 2 ;;
            --after)   after="$2"; shift 2 ;;
            *) die "Unknown option for create-section: $1" ;;
        esac
    done
    [[ -n "$project" && -n "$name" ]] || die "Usage: asana.sh create-section --project <name|gid> --name <name> [--before S] [--after S]"
    [[ -z "$before" || -z "$after" ]] || die "create-section: pass only one of --before / --after"

    local project_gid body
    project_gid="$(resolve_project "$project")"

    # Creating a section that already exists silently yields a duplicate with
    # the same name, which then makes every later name lookup ambiguous — so
    # this is idempotent by name instead.
    local existing
    existing="$(api GET "/projects/${project_gid}/sections" \
        | jq -r --arg n "$name" '[.data[] | select(.name == $n)] | first // empty | .gid')"
    if [[ -n "$existing" ]]; then
        jq -n --arg g "$existing" --arg n "$name" '{gid: $g, name: $n, status: "exists"}'
        return
    fi

    body="$(jq -n --arg n "$name" '{data: {name: $n}}')"
    [[ -n "$before" ]] && body="$(echo "$body" | jq --arg v "$(resolve_section "$project_gid" "$before")" '.data.insert_before = $v')"
    [[ -n "$after" ]]  && body="$(echo "$body" | jq --arg v "$(resolve_section "$project_gid" "$after")"  '.data.insert_after = $v')"
    api POST "/projects/${project_gid}/sections" "$body" | jq '.data + {status: "created"}'
}

cmd_delete_section() {
    local section="" project=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --section) section="$2"; shift 2 ;;
            --project) project="$2"; shift 2 ;;
            *) die "Unknown option for delete-section: $1" ;;
        esac
    done
    [[ -n "$section" ]] || die "Usage: asana.sh delete-section --section <name|gid> [--project P]"

    local section_gid
    if is_gid "$section"; then
        section_gid="$section"
    else
        [[ -n "$project" ]] || die "delete-section: --project is required when --section is a name"
        section_gid="$(resolve_section "$(resolve_project "$project")" "$section")"
    fi

    # Asana refuses to delete a non-empty section. Say so plainly, with the
    # count, rather than surfacing a bare 400 — the fix is always to move the
    # tasks out first (move-task-to-section).
    local remaining
    remaining="$(api GET "/sections/${section_gid}/tasks?opt_fields=name" | jq '.data | length')"
    if [[ "$remaining" -gt 0 ]]; then
        die "Section ${section_gid} still holds ${remaining} task(s); move them out before deleting"
    fi
    api DELETE "/sections/${section_gid}" >/dev/null
    jq -n --arg g "$section_gid" '{gid: $g, status: "deleted"}'
}

cmd_list_workspace_fields() {
    local workspace="" name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) workspace="$2"; shift 2 ;;
            --name)      name="$2"; shift 2 ;;
            *) die "Unknown option for list-workspace-fields: $1" ;;
        esac
    done
    local ws fields
    ws="$(resolve_workspace "$workspace")"
    fields="$(api GET "/workspaces/${ws}/custom_fields?opt_fields=name,resource_subtype,description,enum_options.name,enum_options.color,enum_options.enabled" | jq '.data')"
    if [[ -n "$name" ]]; then
        fields="$(echo "$fields" | jq --arg n "$(echo "$name" | tr '[:upper:]' '[:lower:]')" \
            '[.[] | select(((.name // "") | ascii_downcase) | contains($n))]')"
    fi
    echo "$fields"
}

# resolve_workspace_field WORKSPACE_GID NAME_OR_GID — a workspace-global field
# by name; used so add-project-field can take "Complexity" instead of a GID.
resolve_workspace_field() {
    local ws="$1" f="$2"
    if is_gid "$f"; then echo "$f"; return; fi
    local gid
    gid="$(api GET "/workspaces/${ws}/custom_fields?opt_fields=name" | jq '.data' | fuzzy_pick "$f")"
    [[ -n "$gid" ]] || die "Custom field not found in workspace ${ws}: ${f}"
    echo "$gid"
}

cmd_add_project_field() {
    local project="" field="" important="true" workspace=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)   project="$2"; shift 2 ;;
            --field)     field="$2"; shift 2 ;;
            --important) important="$2"; shift 2 ;;
            --workspace) workspace="$2"; shift 2 ;;
            *) die "Unknown option for add-project-field: $1" ;;
        esac
    done
    [[ -n "$project" && -n "$field" ]] || die "Usage: asana.sh add-project-field --project <name|gid> --field <name|gid> [--important true|false]"

    local project_gid field_gid
    project_gid="$(resolve_project "$project")"
    field_gid="$(resolve_workspace_field "$(resolve_workspace "$workspace")" "$field")"

    # Already attached → report it instead of re-POSTing, so this is safe to
    # re-run over a project that is partway conformant.
    if api GET "/projects/${project_gid}/custom_field_settings" \
        | jq -e --arg g "$field_gid" 'any(.data[]; .custom_field.gid == $g)' >/dev/null; then
        jq -n --arg g "$field_gid" '{custom_field: $g, status: "exists"}'
        return
    fi

    api POST "/projects/${project_gid}/addCustomFieldSetting" \
        "$(jq -n --arg f "$field_gid" --argjson i "$important" '{data: {custom_field: $f, is_important: $i}}')" \
        | jq '.data + {status: "added"}'
}

cmd_remove_project_field() {
    local project="" field="" workspace=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)   project="$2"; shift 2 ;;
            --field)     field="$2"; shift 2 ;;
            --workspace) workspace="$2"; shift 2 ;;
            *) die "Unknown option for remove-project-field: $1" ;;
        esac
    done
    [[ -n "$project" && -n "$field" ]] || die "Usage: asana.sh remove-project-field --project <name|gid> --field <name|gid>"

    local project_gid field_gid
    project_gid="$(resolve_project "$project")"
    if is_gid "$field"; then
        field_gid="$field"
    else
        # Prefer the project's own attached fields — a project-local field may
        # not be visible in the workspace-wide field list.
        field_gid="$(api GET "/projects/${project_gid}/custom_field_settings" | jq '[.data[].custom_field]' | fuzzy_pick "$field")"
        [[ -n "$field_gid" ]] || field_gid="$(resolve_workspace_field "$(resolve_workspace "$workspace")" "$field")"
    fi

    api POST "/projects/${project_gid}/removeCustomFieldSetting" \
        "$(jq -n --arg f "$field_gid" '{data: {custom_field: $f}}')" >/dev/null
    jq -n --arg g "$field_gid" '{custom_field: $g, status: "removed"}'
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

main() {
    [[ $# -ge 1 ]] || usage
    local cmd="$1"
    shift
    case "$cmd" in
        -h|--help|help)       usage ;;
    esac
    load_token
    case "$cmd" in
        list-workspaces)      cmd_list_workspaces "$@" ;;
        list-projects)        cmd_list_projects "$@" ;;
        list-tasks)           cmd_list_tasks "$@" ;;
        get-task)             cmd_get_task "$@" ;;
        list-sections)        cmd_list_sections "$@" ;;
        create-task)          cmd_create_task "$@" ;;
        update-task)          cmd_update_task "$@" ;;
        complete-task)        cmd_complete_task "$@" ;;
        add-comment)          cmd_add_comment "$@" ;;
        list-comments)        cmd_list_comments "$@" ;;
        search-tasks)         cmd_search_tasks "$@" ;;
        get-current-user)     cmd_get_current_user "$@" ;;
        get-user)             cmd_get_user "$@" ;;
        get-custom-fields)    cmd_get_custom_fields "$@" ;;
        update-custom-field)  cmd_update_custom_field "$@" ;;
        check-fields)         cmd_check_fields "$@" ;;
        move-task-to-section) cmd_move_task_to_section "$@" ;;
        list-section-tasks)   cmd_list_section_tasks "$@" ;;
        create-section)       cmd_create_section "$@" ;;
        delete-section)       cmd_delete_section "$@" ;;
        list-workspace-fields) cmd_list_workspace_fields "$@" ;;
        add-project-field)    cmd_add_project_field "$@" ;;
        remove-project-field) cmd_remove_project_field "$@" ;;
        *) die "Unknown command: ${cmd} (run 'asana.sh help')" ;;
    esac
}

main "$@"
