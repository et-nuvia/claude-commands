#!/usr/bin/env bash
# sprint-plan.sh — lightweight two-week sprint planning against Asana
#
# Sections (run in order; --full stops at --inventory because the middle step
# needs LLM judgement):
#
#   --identify   verify the dev branch, load sprint config, resolve the Asana
#                project + standardized sections, resolve the direction/goal
#   --inventory  collect every unique work item from docs/active and the
#                worktrees of every repo feeding this Asana project, plus the
#                live Current Sprint / Bugs / Backlog contents; report which
#                local tasks have no Asana counterpart
#   --select     consume the LLM's decisions file (classification, relevance
#                1-10, Score estimates, carry-over calls) and compute the
#                sprint fill: carry-over first, then highest-relevance backlog
#                work up to the feature budget
#   --apply      execute the planned Asana mutations (dry-run unless --apply)
#
# The script owns everything deterministic — discovery, capacity arithmetic,
# section resolution, and the writes. The LLM owns only judgement: is this a
# feature or a bug, how relevant is it to the stated direction, what does it
# cost, and is in-flight work finishing before the sprint or carrying into it.
#
# Scoring rubric (shared with /task-capture): docs/reference/story-points.md
#
# Usage:
#   sprint-plan.sh --identify  [--goal TEXT] [--capacity N] [--sprint-label L]
#   sprint-plan.sh --inventory [--goal TEXT]
#   sprint-plan.sh --select --decisions FILE [--capacity N] [--sprint-label L]
#   sprint-plan.sh --apply  --plan FILE [--apply]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success)        echo "display_summary" ;;
        needs_llm)      echo "parse_content" ;;
        ready_for_sync) echo "confirm_action" ;;
        needs_decision) echo "confirm_action" ;;
        *)              _default_map_status_to_action "$1" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"

ASANA="${SCRIPT_DIR}/asana.sh"
SELECT_LIB="${SCRIPT_DIR}/lib/sprint_select.py"

# --- Flag parsing -----------------------------------------------------------
OUTPUT_MODE="json"
SECTION="full"
GOAL_OVERRIDE=""
CAPACITY_OVERRIDE=""
SPRINT_LABEL=""
DECISIONS_FILE=""
PLAN_FILE=""
DO_APPLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --json)         OUTPUT_MODE="json"; shift ;;
        --raw)          OUTPUT_MODE="raw"; shift ;;
        --identify)     SECTION="identify"; shift ;;
        --inventory)    SECTION="inventory"; shift ;;
        --select)       SECTION="select"; shift ;;
        --apply-plan)   SECTION="apply"; shift ;;
        --full)         SECTION="full"; shift ;;
        --goal)         GOAL_OVERRIDE="$2"; shift 2 ;;
        --capacity)     CAPACITY_OVERRIDE="$2"; shift 2 ;;
        --sprint-label) SPRINT_LABEL="$2"; shift 2 ;;
        --decisions)    DECISIONS_FILE="$2"; shift 2 ;;
        --plan)         PLAN_FILE="$2"; shift 2 ;;
        --apply)        DO_APPLY=true; shift ;;
        -h|--help)      sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) break ;;
    esac
done

# --- Config -----------------------------------------------------------------
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROJECT_YAML="${PROJECT_ROOT}/PROJECT.yaml"

if [[ ! -f "$PROJECT_YAML" ]]; then
    exit_with_json "error" "No PROJECT.yaml at ${PROJECT_ROOT}" \
        "Sprint planning needs the Asana project id and sprint config. Run /project-config init."
fi

PROJECT_NAME="$(yaml_get_default '.name' "$(basename "$PROJECT_ROOT")" "$PROJECT_YAML")"
BACKEND="$(yaml_get_default '.task_management.backend' 'asana' "$PROJECT_YAML")"
ASANA_PROJECT="$(yaml_get '.task_management.asana.project_id' "$PROJECT_YAML")"
[[ -n "$ASANA_PROJECT" ]] || ASANA_PROJECT="$(yaml_get '.task_management.asana.default_project_id' "$PROJECT_YAML")"
ASANA_PROJECT_NAME="$(yaml_get_default '.task_management.asana.project' \
    "$(yaml_get_default '.task_management.asana.default_project' 'unknown' "$PROJECT_YAML")" "$PROJECT_YAML")"

# Sections and custom fields have ONE source of truth:
# task_management.asana.{sections,custom_fields}, which is what asana.sh and the
# task lifecycle scripts read. The `sprint.*` keys stay as a per-project
# override for a project whose section/field names differ, but they are no
# longer where the standard layout is declared — otherwise the same section had
# to be named in two places and could silently disagree.
asana_section_name() { # LOGICAL DEFAULT
    yaml_get_default ".sprint.sections.${1}" \
        "$(yaml_get_default ".task_management.asana.sections.${1}.name" "$2" "$PROJECT_YAML")" \
        "$PROJECT_YAML"
}
asana_field_name() { # LOGICAL DEFAULT
    yaml_get_default ".sprint.fields.${1}" \
        "$(yaml_get_default ".task_management.asana.custom_fields.${1}.name" "$2" "$PROJECT_YAML")" \
        "$PROJECT_YAML"
}

SEC_SPRINT="$(asana_section_name current_sprint 'Current Sprint')"
SEC_BUGS="$(asana_section_name bugs 'Bugs')"
SEC_BACKLOG="$(asana_section_name backlog 'Backlog')"

SPRINT_DAYS="$(yaml_get_default '.sprint.length_days' '14' "$PROJECT_YAML")"
CAPACITY="${CAPACITY_OVERRIDE:-$(yaml_get_default '.sprint.capacity_points' '20' "$PROJECT_YAML")}"
FEATURE_RATIO="$(yaml_get_default '.sprint.feature_ratio' '0.8' "$PROJECT_YAML")"
DEFAULT_POINTS="$(yaml_get_default '.sprint.default_points' '3' "$PROJECT_YAML")"

FIELD_SCORE="$(asana_field_name score 'Score')"
FIELD_SPRINT="$(asana_field_name sprint 'Sprint')"
FIELD_RELEVANCE="$(yaml_get '.sprint.fields.relevance' "$PROJECT_YAML")"

DEV_BRANCH="$(yaml_get_default '.git.default' 'dev' "$PROJECT_YAML")"

if [[ -z "$SPRINT_LABEL" ]]; then
    SPRINT_LABEL="$(date +%Y)-S$(date +%V)"
fi

WORK_DIR="${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/sprint-plan-$$"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
# section: identify
# ---------------------------------------------------------------------------
REPOS=()
GOAL=""
GOAL_SOURCE=""

resolve_repos() {
    REPOS=("$PROJECT_ROOT")
    local extra
    while IFS= read -r extra; do
        [[ -n "$extra" ]] || continue
        # Relative entries resolve against the parent of this repo, so a shared
        # Asana project can list sibling repos as plain names.
        if [[ "$extra" != /* ]]; then
            extra="$(cd "$(dirname "$PROJECT_ROOT")" && cd "$extra" 2>/dev/null && pwd)" || continue
        fi
        [[ -d "$extra" ]] || continue
        [[ "$extra" == "$PROJECT_ROOT" ]] && continue
        REPOS+=("$extra")
    done < <(yaml_get_array '.sprint.repos' "$PROJECT_YAML" 2>/dev/null || true)
}

resolve_goal() {
    # Precedence: interactive override > goal_doc > PROJECT.yaml .sprint.goal
    if [[ -n "$GOAL_OVERRIDE" ]]; then
        GOAL="$GOAL_OVERRIDE"
        GOAL_SOURCE="override"
        return
    fi
    local doc
    doc="$(yaml_get '.sprint.goal_doc' "$PROJECT_YAML")"
    if [[ -n "$doc" && -f "${PROJECT_ROOT}/${doc}" ]]; then
        GOAL="$(<"${PROJECT_ROOT}/${doc}")"
        GOAL_SOURCE="doc:${doc}"
        return
    fi
    local cfg
    cfg="$(yaml_get '.sprint.goal' "$PROJECT_YAML")"
    if [[ -n "$cfg" ]]; then
        GOAL="$cfg"
        GOAL_SOURCE="project_yaml"
        return
    fi
    GOAL=""
    GOAL_SOURCE="none"
}

section_identify() {
    log "${BLUE}Validating sprint planning preconditions...${NC}"

    if [[ "$BACKEND" != "asana" ]]; then
        exit_with_json "error" "Sprint planning requires the asana backend (found: ${BACKEND})" \
            "Set task_management.backend: asana in PROJECT.yaml."
    fi
    [[ -n "$ASANA_PROJECT" ]] || exit_with_json "error" "No Asana project id in PROJECT.yaml" \
        "Set task_management.asana.project_id."

    local branch
    branch="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [[ "$branch" != "$DEV_BRANCH" ]]; then
        exit_with_json "blocked" "Not on ${DEV_BRANCH} (currently on '${branch:-detached}')" \
            "Sprint planning reads the ${DEV_BRANCH} view of docs/active. Run: git -C ${PROJECT_ROOT} checkout ${DEV_BRANCH}" \
            "\"current_branch\": $(jq -Rn --arg b "$branch" '$b'), \"required_branch\": \"${DEV_BRANCH}\""
    fi

    local dirty=false
    git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || dirty=true

    # Every standardized section must exist; a missing one means the project has
    # not been converted to the sprint layout and planning would silently guess.
    local sections_json missing=()
    sections_json="$("$ASANA" list-sections --project "$ASANA_PROJECT")" \
        || exit_with_json "error" "Could not list Asana sections for project ${ASANA_PROJECT}" \
            "Check ~/.asana-token and the project id."

    local s gid
    for s in "$SEC_SPRINT" "$SEC_BUGS" "$SEC_BACKLOG"; do
        gid="$(jq -r --arg n "$s" '[.[] | select((.name|ascii_downcase) == ($n|ascii_downcase))][0].gid // empty' <<<"$sections_json")"
        [[ -n "$gid" ]] || missing+=("$s")
    done

    if (( ${#missing[@]} > 0 )); then
        exit_with_json "blocked" "Asana project '${ASANA_PROJECT_NAME}' is missing sprint section(s): ${missing[*]}" \
            "Create them (asana.sh create-section --project ${ASANA_PROJECT} --name '<name>') or map existing names via sprint.sections in PROJECT.yaml." \
            "\"missing_sections\": $(printf '%s\n' "${missing[@]}" | jq -Rc . | jq -sc .)," \
            "\"existing_sections\": $(jq -c '[.[].name]' <<<"$sections_json")"
    fi

    resolve_repos
    resolve_goal

    printf '%s\n' "$sections_json" >"${WORK_DIR}/sections.json"

    local repos_json
    repos_json="$(printf '%s\n' "${REPOS[@]}" | jq -Rc . | jq -sc .)"

    if [[ "$SECTION" == "identify" ]]; then
        local goal_status="ok" status="success"
        if [[ "$GOAL_SOURCE" == "none" ]]; then
            goal_status="missing"
            status="needs_decision"
        fi
        exit_with_json "$status" \
            "Ready to plan ${SPRINT_LABEL} for '${ASANA_PROJECT_NAME}' (${CAPACITY} pts, ${SPRINT_DAYS}d)" \
            "" \
            "\"project\": $(jq -Rn --arg v "$PROJECT_NAME" '$v')," \
            "\"asana_project\": {\"gid\": \"${ASANA_PROJECT}\", \"name\": $(jq -Rn --arg v "$ASANA_PROJECT_NAME" '$v')}," \
            "\"sprint_label\": \"${SPRINT_LABEL}\", \"length_days\": ${SPRINT_DAYS}," \
            "\"capacity\": {\"total_points\": ${CAPACITY}, \"feature_ratio\": ${FEATURE_RATIO}, \"default_points\": ${DEFAULT_POINTS}}," \
            "\"sections\": {\"current_sprint\": $(jq -Rn --arg v "$SEC_SPRINT" '$v'), \"bugs\": $(jq -Rn --arg v "$SEC_BUGS" '$v'), \"backlog\": $(jq -Rn --arg v "$SEC_BACKLOG" '$v')}," \
            "\"fields\": {\"score\": $(jq -Rn --arg v "$FIELD_SCORE" '$v'), \"sprint\": $(jq -Rn --arg v "$FIELD_SPRINT" '$v'), \"relevance\": $(jq -Rn --arg v "$FIELD_RELEVANCE" '$v')}," \
            "\"repos\": ${repos_json}, \"branch\": \"${DEV_BRANCH}\", \"uncommitted_changes\": ${dirty}," \
            "\"goal\": {\"source\": \"${GOAL_SOURCE}\", \"status\": \"${goal_status}\", \"text\": $(jq -Rn --arg v "$GOAL" '$v')}," \
            "\"rubric\": \"~/.claude/docs/reference/story-points.md\""
    fi
}

# ---------------------------------------------------------------------------
# section: inventory
# ---------------------------------------------------------------------------

# Emit one JSON object per local work item found in a repo: id, title, whether a
# worktree is open for it, and any Asana gid already recorded in its docs.
collect_local_repo() {
    local repo="$1"
    local docs_dir="${repo}/docs/active"
    local worktrees_json="[]"

    if [[ -d "${repo}/.git" || -f "${repo}/.git" ]]; then
        worktrees_json="$(git -C "$repo" worktree list --porcelain 2>/dev/null \
            | awk '/^worktree /{wt=$2} /^branch /{print wt "\t" $2}' \
            | jq -Rc 'split("\t") | {path: .[0], branch: .[1]}' | jq -sc .)"
    fi

    [[ -d "$docs_dir" ]] || { echo '[]'; return; }

    # docs/active/<month>/<ID>-<datetime>-<TYPE>-slug.md
    find "$docs_dir" -name '*.md' -type f 2>/dev/null \
        | jq -Rc --arg repo "$repo" --argjson wts "$worktrees_json" '
            . as $path
            | ($path | split("/") | last) as $base
            | ($base | capture("^(?<id>[0-9A-Fa-f]{6})-(?<dt>[0-9]{10})-(?<type>[A-Z]{3})-(?<slug>.*)\\.md$")) as $m
            | select($m != null)
            | {id: ($m.id | ascii_upcase), type: $m.type, slug: $m.slug, path: $path, repo: $repo,
               worktree: ([$wts[] | select(.branch | test($m.id; "i"))][0].path // null)}
        ' 2>/dev/null | jq -sc '.' || echo '[]'
}

section_inventory() {
    log "${BLUE}Collecting local work items across ${#REPOS[@]} repo(s)...${NC}"

    local all='[]' repo repo_items
    for repo in "${REPOS[@]}"; do
        repo_items="$(collect_local_repo "$repo")"
        all="$(jq -c --argjson a "$all" --argjson b "$repo_items" -n '$a + $b')"
    done

    # Fold the per-doc rows into one row per work item. The TSK doc supplies the
    # title; a recorded Asana permalink in any of the item's docs supplies the
    # gid, which makes matching exact instead of fuzzy.
    local local_items
    local_items="$(jq -c '
        group_by(.id)
        | map({
            id: .[0].id,
            repo: .[0].repo,
            types: [.[].type] | unique,
            doc: ([.[] | select(.type == "TSK")][0].path // .[0].path),
            slug: ([.[] | select(.type == "TSK")][0].slug // .[0].slug),
            worktree: ([.[] | .worktree | select(. != null)][0] // null),
            docs: [.[].path]
          })
    ' <<<"$all")"

    # Titles + recorded Asana gids come from the docs themselves. Each item is
    # emitted as one NDJSON line and slurped once at the end — accumulating into
    # a growing JSON array instead re-parses the whole array every iteration and
    # makes a single malformed item corrupt the entire structure.
    local n ndjson="${WORK_DIR}/local_items.ndjson"
    : >"$ndjson"
    n="$(jq -r 'length' <<<"$local_items")"
    local i=0 item doc title gid
    while (( i < n )); do
        item="$(jq -c ".[$i]" <<<"$local_items")"
        doc="$(jq -r '.doc' <<<"$item")"
        title=""
        # Portable BRE only: `\?` is a GNU extension and matches a literal '?'
        # under BSD sed, which silently sent every title to the slug fallback.
        [[ -f "$doc" ]] && title="$(sed -n '/^# /{s/^# *//; s/^Task: *//; p; q;}' "$doc")"
        [[ -n "$title" ]] || title="$(jq -r '.slug' <<<"$item" | tr '-' ' ')"

        gid=""
        while IFS= read -r docpath; do
            [[ -f "$docpath" ]] || continue
            gid="$(grep -oE 'app\.asana\.com/[^ )]*/task/[0-9]+' "$docpath" 2>/dev/null \
                | grep -oE '[0-9]+$' | head -1 || true)"
            [[ -n "$gid" ]] && break
        done < <(jq -r '.docs[]' <<<"$item")

        jq -c --arg title "$title" --arg gid "$gid" \
            '. + {title: $title, asana_gid: (if $gid == "" then null else $gid end),
                  in_flight: (.worktree != null)}' <<<"$item" >>"$ndjson"
        i=$((i + 1))
    done

    local enriched
    enriched="$(jq -sc '.' <"$ndjson")"

    log "${BLUE}Reading Asana sections...${NC}"
    local sprint_tasks bug_tasks backlog_tasks
    sprint_tasks="$("$ASANA" list-section-tasks --section "${SECTION_GIDS_SPRINT}" --with-fields --completed false)"
    bug_tasks="$("$ASANA" list-section-tasks --section "${SECTION_GIDS_BUGS}" --with-fields --completed false)"
    backlog_tasks="$("$ASANA" list-section-tasks --section "${SECTION_GIDS_BACKLOG}" --with-fields --completed false)"

    # Flatten the custom fields the planner cares about onto each Asana task.
    local asana_all
    asana_all="$(jq -c -n \
        --argjson sprint "$sprint_tasks" --argjson bugs "$bug_tasks" --argjson backlog "$backlog_tasks" \
        --arg score "$FIELD_SCORE" --arg sprintf "$FIELD_SPRINT" \
        --arg s_sprint "$SEC_SPRINT" --arg s_bugs "$SEC_BUGS" --arg s_backlog "$SEC_BACKLOG" '
        def shape($sec): map({gid, name, section: $sec,
             score: ([.custom_fields[]? | select(.name == $score) | .display_value][0] // null),
             sprint: ([.custom_fields[]? | select(.name == $sprintf) | .display_value][0] // null),
             priority: ([.custom_fields[]? | select((.name|ascii_downcase|gsub("^ +| +$";"")) == "priority") | .display_value][0] // null),
             status: ([.custom_fields[]? | select(.name | test("^status"; "i")) | .display_value][0] // null)});
        ($sprint | shape($s_sprint)) + ($bugs | shape($s_bugs)) + ($backlog | shape($s_backlog))')"

    # Which local items have no Asana counterpart? An item with a recorded gid
    # that is present in Asana is matched outright; the rest are candidates for
    # title matching, which only the LLM can do reliably.
    # The item is bound to $it before the membership test: inside index(...) the
    # implicit `.` is the gid array being searched, not the item.
    local unmatched matched
    matched="$(jq -c --argjson a "$asana_all" '
        ([$a[].gid]) as $gids
        | [.[] | . as $it | select($it.asana_gid != null and ($gids | index($it.asana_gid) != null))]' <<<"$enriched")"
    unmatched="$(jq -c --argjson a "$asana_all" '
        ([$a[].gid]) as $gids
        | [.[] | . as $it | select($it.asana_gid == null or ($gids | index($it.asana_gid) == null))]' <<<"$enriched")"

    local payload
    payload="$(jq -c -n \
        --arg label "$SPRINT_LABEL" \
        --argjson cap "$CAPACITY" --argjson ratio "$FEATURE_RATIO" --argjson defpts "$DEFAULT_POINTS" \
        --arg goal "$GOAL" --arg goal_src "$GOAL_SOURCE" \
        --argjson asana "$asana_all" --argjson matched "$matched" --argjson unmatched "$unmatched" \
        --arg s_sprint "$SEC_SPRINT" --arg s_bugs "$SEC_BUGS" --arg s_backlog "$SEC_BACKLOG" '
        {sprint_label: $label,
         capacity_points: $cap, feature_ratio: $ratio, default_points: $defpts,
         sections: {current_sprint: $s_sprint, bugs: $s_bugs, backlog: $s_backlog},
         goal: {source: $goal_src, text: $goal},
         asana_tasks: $asana,
         local_matched: $matched,
         local_unmatched: $unmatched}')"

    printf '%s\n' "$payload" >"${WORK_DIR}/inventory.json"
    local keep="${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/sprint-inventory-${SPRINT_LABEL}.json"
    printf '%s\n' "$payload" >"$keep"

    local n_sprint n_bugs n_backlog n_unmatched n_inflight
    n_sprint="$(jq -r --arg s "$SEC_SPRINT" '[.asana_tasks[] | select(.section == $s)] | length' <<<"$payload")"
    n_bugs="$(jq -r --arg s "$SEC_BUGS" '[.asana_tasks[] | select(.section == $s)] | length' <<<"$payload")"
    n_backlog="$(jq -r --arg s "$SEC_BACKLOG" '[.asana_tasks[] | select(.section == $s)] | length' <<<"$payload")"
    n_unmatched="$(jq -r '.local_unmatched | length' <<<"$payload")"
    n_inflight="$(jq -r '[.local_matched[], .local_unmatched[]] | map(select(.in_flight)) | length' <<<"$payload")"

    # Only the fields the scoring step reasons over are inlined. Doc paths, the
    # matched-item detail and the raw custom-field arrays stay in the file, which
    # the LLM can read on demand instead of paying for them every run.
    local digest
    digest="$(jq -c --arg s_sprint "$SEC_SPRINT" --arg s_bugs "$SEC_BUGS" --arg s_backlog "$SEC_BACKLOG" '
        {backlog:        [.asana_tasks[] | select(.section == $s_backlog) | {gid, name, score, priority}],
         current_sprint: [.asana_tasks[] | select(.section == $s_sprint)  | {gid, name, score, sprint, status}],
         bugs:           [.asana_tasks[] | select(.section == $s_bugs)    | {gid, name, score, priority}],
         in_flight:      [(.local_matched[], .local_unmatched[]) | select(.in_flight)
                          | {id, title, repo: (.repo | split("/") | last), asana_gid}],
         unmatched:      [.local_unmatched[] | {id, title, repo: (.repo | split("/") | last), in_flight}]}' \
        <<<"$payload")"

    exit_with_json "needs_llm" \
        "Inventory complete: ${n_backlog} backlog, ${n_sprint} in sprint, ${n_bugs} bugs, ${n_unmatched} local item(s) unmatched, ${n_inflight} in flight" \
        "" \
        "\"inventory_file\": $(jq -Rn --arg v "$keep" '$v')," \
        "\"sprint_label\": \"${SPRINT_LABEL}\"," \
        "\"counts\": {\"backlog\": ${n_backlog}, \"current_sprint\": ${n_sprint}, \"bugs\": ${n_bugs}, \"local_unmatched\": ${n_unmatched}, \"in_flight\": ${n_inflight}}," \
        "\"capacity\": {\"total_points\": ${CAPACITY}, \"feature_ratio\": ${FEATURE_RATIO}, \"default_points\": ${DEFAULT_POINTS}}," \
        "\"goal\": {\"source\": \"${GOAL_SOURCE}\", \"text\": $(jq -Rn --arg v "$GOAL" '$v')}," \
        "\"rubric\": \"~/.claude/docs/reference/story-points.md\"," \
        "\"inventory\": ${digest}"
}

# ---------------------------------------------------------------------------
# section: select
# ---------------------------------------------------------------------------
section_select() {
    [[ -n "$DECISIONS_FILE" ]] || exit_with_json "error" "--select requires --decisions FILE" \
        "Write the LLM decisions JSON to a file, then re-run with --select --decisions <file>."
    [[ -f "$DECISIONS_FILE" ]] || exit_with_json "error" "Decisions file not found: ${DECISIONS_FILE}" ""

    jq empty "$DECISIONS_FILE" 2>/dev/null \
        || exit_with_json "error" "Decisions file is not valid JSON: ${DECISIONS_FILE}" ""

    # Config supplies capacity unless the decisions file states its own, so a
    # replay of an old decisions file reproduces the sprint it planned.
    local prepared
    prepared="$(jq -c \
        --arg label "$SPRINT_LABEL" --argjson cap "$CAPACITY" \
        --argjson ratio "$FEATURE_RATIO" --argjson defpts "$DEFAULT_POINTS" \
        --arg s_sprint "$SEC_SPRINT" --arg s_bugs "$SEC_BUGS" --arg s_backlog "$SEC_BACKLOG" '
        . + {sprint_label: (.sprint_label // $label),
             capacity_points: (.capacity_points // $cap),
             feature_ratio: (.feature_ratio // $ratio),
             default_points: (.default_points // $defpts),
             sections: (.sections // {current_sprint: $s_sprint, bugs: $s_bugs, backlog: $s_backlog})}' \
        "$DECISIONS_FILE")"

    local plan
    plan="$(printf '%s' "$prepared" | python3 "$SELECT_LIB")" \
        || exit_with_json "error" "Sprint selection failed" "$(printf '%s' "$prepared" | python3 "$SELECT_LIB" 2>&1 || true)"

    local plan_out="${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/sprint-plan-${SPRINT_LABEL}.json"
    printf '%s\n' "$plan" >"$plan_out"

    local sel pts budget
    sel="$(jq -r '.counts.selected' <<<"$plan")"
    pts="$(jq -r '.capacity.committed_points' <<<"$plan")"
    budget="$(jq -r '.capacity.feature_budget' <<<"$plan")"

    exit_with_json "ready_for_sync" \
        "Sprint ${SPRINT_LABEL}: ${sel} item(s) selected, ${pts}/${budget} feature points committed" \
        "" \
        "\"plan_file\": $(jq -Rn --arg v "$plan_out" '$v')," \
        "\"apply_command\": $(jq -Rn --arg v "${BASH_SOURCE[0]} --apply-plan --plan ${plan_out} --apply" '$v')," \
        "\"plan\": ${plan}"
}

# ---------------------------------------------------------------------------
# section: apply
# ---------------------------------------------------------------------------
section_apply() {
    [[ -n "$PLAN_FILE" ]] || exit_with_json "error" "--apply-plan requires --plan FILE" ""
    [[ -f "$PLAN_FILE" ]] || exit_with_json "error" "Plan file not found: ${PLAN_FILE}" ""
    jq empty "$PLAN_FILE" 2>/dev/null || exit_with_json "error" "Plan file is not valid JSON" ""

    local n_actions
    n_actions="$(jq -r '.actions | length' "$PLAN_FILE")"

    if [[ "$DO_APPLY" != "true" ]]; then
        exit_with_json "needs_decision" \
            "Dry run: ${n_actions} Asana change(s) planned, nothing written" \
            "Re-run with --apply to write." \
            "\"dry_run\": true, \"actions\": $(jq -c '.actions' "$PLAN_FILE")," \
            "\"capacity\": $(jq -c '.capacity' "$PLAN_FILE")"
    fi

    log "${BLUE}Applying ${n_actions} change(s) to Asana...${NC}"

    local results='[]' i=0 action gid name
    while (( i < n_actions )); do
        action="$(jq -c ".actions[$i]" "$PLAN_FILE")"
        local kind ok err
        kind="$(jq -r '.action' <<<"$action")"
        name="$(jq -r '.name // ""' <<<"$action")"
        gid="$(jq -r '.gid // ""' <<<"$action")"
        ok=true
        err=""

        case "$kind" in
            create_task)
                local sec notes new_gid
                sec="$(jq -r '.section' <<<"$action")"
                notes="$(jq -r '.notes // ""' <<<"$action")"
                new_gid="$("$ASANA" create-task --name "$name" --notes "$notes" \
                    --project "$ASANA_PROJECT" --section "$sec" 2>"${WORK_DIR}/err" \
                    | jq -r '.gid // empty')" || ok=false
                if [[ -n "$new_gid" ]]; then
                    gid="$new_gid"
                    local pts
                    pts="$(jq -r '.points // empty' <<<"$action")"
                    [[ -n "$pts" ]] && "$ASANA" update-custom-field "$gid" --field "$FIELD_SCORE" \
                        --value "$pts" --project "$ASANA_PROJECT" --if-supported >/dev/null 2>&1 || true
                    "$ASANA" update-custom-field "$gid" --field "$FIELD_SPRINT" \
                        --value "$SPRINT_LABEL" --project "$ASANA_PROJECT" --if-supported >/dev/null 2>&1 || true
                else
                    ok=false
                fi
                ;;
            move_task)
                local sec
                sec="$(jq -r '.section' <<<"$action")"
                "$ASANA" move-task-to-section "$gid" --section "$sec" --project "$ASANA_PROJECT" \
                    >/dev/null 2>"${WORK_DIR}/err" || ok=false
                ;;
            set_score)
                "$ASANA" update-custom-field "$gid" --field "$FIELD_SCORE" \
                    --value "$(jq -r '.points' <<<"$action")" --project "$ASANA_PROJECT" --if-supported \
                    >/dev/null 2>"${WORK_DIR}/err" || ok=false
                ;;
            set_sprint)
                "$ASANA" update-custom-field "$gid" --field "$FIELD_SPRINT" \
                    --value "$(jq -r '.sprint' <<<"$action")" --project "$ASANA_PROJECT" --if-supported \
                    >/dev/null 2>"${WORK_DIR}/err" || ok=false
                ;;
            set_relevance)
                if [[ -z "$FIELD_RELEVANCE" ]]; then
                    # No relevance field configured — the plan file and the
                    # summary shown to the user are the record instead.
                    results="$(jq -c --argjson r "$results" --argjson a "$action" -n \
                        '$r + [$a + {result: "skipped", detail: "no sprint.fields.relevance configured"}]')"
                    i=$((i + 1))
                    continue
                fi
                "$ASANA" update-custom-field "$gid" --field "$FIELD_RELEVANCE" \
                    --value "$(jq -r '.relevance' <<<"$action")" --project "$ASANA_PROJECT" --if-supported \
                    >/dev/null 2>"${WORK_DIR}/err" || ok=false
                ;;
            *) ok=false; err="unknown action '${kind}'" ;;
        esac

        [[ -z "$err" && "$ok" == "false" && -f "${WORK_DIR}/err" ]] && err="$(<"${WORK_DIR}/err")"
        results="$(jq -c --argjson r "$results" --argjson a "$action" \
            --arg res "$([[ "$ok" == "true" ]] && echo applied || echo failed)" \
            --arg gid "$gid" --arg err "$err" -n \
            '$r + [$a + {gid: (if $gid == "" then null else $gid end), result: $res,
                         error: (if $err == "" then null else $err end)}]')"
        i=$((i + 1))
    done

    local n_ok n_fail n_skip
    n_ok="$(jq -r '[.[] | select(.result == "applied")] | length' <<<"$results")"
    n_fail="$(jq -r '[.[] | select(.result == "failed")] | length' <<<"$results")"
    n_skip="$(jq -r '[.[] | select(.result == "skipped")] | length' <<<"$results")"

    local status="success"
    [[ "$n_fail" -gt 0 ]] && status="warning"

    exit_with_json "$status" \
        "Applied ${n_ok}/${n_actions} change(s) to Asana (${n_fail} failed, ${n_skip} skipped)" \
        "" \
        "\"applied\": ${n_ok}, \"failed\": ${n_fail}, \"skipped\": ${n_skip}," \
        "\"results\": ${results}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# identify populates the section gids the inventory step needs; export them as
# plain variables so the two sections stay independently runnable.
prime_sections() {
    resolve_repos
    resolve_goal
    local sections_json
    sections_json="$("$ASANA" list-sections --project "$ASANA_PROJECT")"
    SECTION_GIDS_SPRINT="$(jq -r --arg n "$SEC_SPRINT" '[.[] | select((.name|ascii_downcase) == ($n|ascii_downcase))][0].gid // empty' <<<"$sections_json")"
    SECTION_GIDS_BUGS="$(jq -r --arg n "$SEC_BUGS" '[.[] | select((.name|ascii_downcase) == ($n|ascii_downcase))][0].gid // empty' <<<"$sections_json")"
    SECTION_GIDS_BACKLOG="$(jq -r --arg n "$SEC_BACKLOG" '[.[] | select((.name|ascii_downcase) == ($n|ascii_downcase))][0].gid // empty' <<<"$sections_json")"
    [[ -n "$SECTION_GIDS_SPRINT" && -n "$SECTION_GIDS_BUGS" && -n "$SECTION_GIDS_BACKLOG" ]] \
        || exit_with_json "blocked" "Sprint sections missing in Asana project ${ASANA_PROJECT}" \
            "Run --identify for the details."
}

case "$SECTION" in
    identify)  section_identify ;;
    inventory) prime_sections; section_inventory ;;
    select)    section_select ;;
    apply)     section_apply ;;
    full)      section_identify; prime_sections; section_inventory ;;
    *) exit_with_json "error" "Unknown section: ${SECTION}" "" ;;
esac
