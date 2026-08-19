#!/usr/bin/env bash
set -euo pipefail

# Git History Scrub Script
# Removes leaked secrets from git history using gitleaks + git-filter-repo.
#
# Workflow (each section is a separate invocation; LLM classifies between scan and plan):
#   --scan     Scan full history with gitleaks, dedupe distinct secrets, check HEAD liveness
#   --plan     Validate decisions.json, build filter-repo replacements, check safety gates
#   --rewrite  Mirror-clone origin, create backup bundle, run filter-repo, verify clean
#   --push     Force-push rewritten refs to origin (requires --confirm; rotation-gated)
#   --status   Show current workflow state
#
# State lives in <git-common-dir>/history-scrub/ (never committed):
#   findings.json     raw gitleaks report (full history)
#   secrets.json      deduped distinct secrets with id, rule, files, liveness
#   decisions.json    LLM/user-written classification (see schema below)
#   replacements.txt  git-filter-repo --replace-text input (chmod 600)
#   state.json        workflow phase, origin URL, mirror path
#   backup-pre-scrub.bundle  full pre-rewrite backup (git clone-able)
#
# decisions.json schema (written by the agent after classifying secrets.json):
#   [
#     {"id": 1, "action": "scrub", "rotated": false, "note": "GCP API key"},
#     {"id": 2, "action": "allowlist", "note": "placeholder in docs"}
#   ]
#   Every id in secrets.json must be covered. "allowlist" means the agent adds
#   a scoped entry to the repo's .gitleaks.toml instead of rewriting history.
#
# Usage:
#   git-history-scrub.sh [--json|--raw] --scan|--plan|--rewrite|--push [--confirm]|--status
#                        [--skip-rotation-gate]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status->action mappings (define BEFORE sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success)        echo "display_summary" ;;
        ready_for_llm)  echo "parse_content" ;;
        needs_decision) echo "confirm_action" ;;
        blocked)        echo "fix_error" ;;
        *)              _default_map_status_to_action "$1" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# --- Flag Parsing ---
OUTPUT_MODE="json"
SECTION=""
CONFIRM=0
SKIP_ROTATION_GATE=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --json) OUTPUT_MODE="json"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --scan|--plan|--rewrite|--push|--status) SECTION="${1#--}"; shift ;;
        --confirm) CONFIRM=1; shift ;;
        --skip-rotation-gate) SKIP_ROTATION_GATE=1; shift ;;
        *) exit_with_json "error" "Unknown flag: $1" "Valid: --scan --plan --rewrite --push --status --confirm --skip-rotation-gate --json --raw" ;;
    esac
done
[[ -z "$SECTION" ]] && exit_with_json "error" "No section specified" "Use --scan, --plan, --rewrite, --push, or --status"

# --- Common Setup ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || exit_with_json "error" "Not inside a git repository"
GIT_COMMON_DIR=$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir)
STATE_DIR="${GIT_COMMON_DIR}/history-scrub"
FINDINGS_JSON="${STATE_DIR}/findings.json"
SECRETS_JSON="${STATE_DIR}/secrets.json"
DECISIONS_JSON="${STATE_DIR}/decisions.json"
REPLACEMENTS_TXT="${STATE_DIR}/replacements.txt"
STATE_JSON="${STATE_DIR}/state.json"
BACKUP_BUNDLE="${STATE_DIR}/backup-pre-scrub.bundle"
GITLEAKS_CONFIG_ARGS=()
[[ -f "${REPO_ROOT}/.gitleaks.toml" ]] && GITLEAKS_CONFIG_ARGS=(--config "${REPO_ROOT}/.gitleaks.toml")

require_tools() {
    local missing=()
    for tool in gitleaks git-filter-repo jq; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        exit_with_json "blocked" "Missing required tools: ${missing[*]}" \
            "Install with: brew install ${missing[*]} (gitleaks, git-filter-repo via homebrew)"
    fi
}

state_get() {
    [[ -f "$STATE_JSON" ]] && jq -r ".$1 // empty" "$STATE_JSON" || true
}

state_set() {
    local key="$1" value="$2"
    mkdir -p "$STATE_DIR"
    if [[ -f "$STATE_JSON" ]]; then
        jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_JSON" > "${STATE_JSON}.tmp" \
            && mv "${STATE_JSON}.tmp" "$STATE_JSON"
    else
        jq -n --arg k "$key" --arg v "$value" '{($k): $v}' > "$STATE_JSON"
    fi
}

origin_url() {
    git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true
}

# --- Section: scan ---
section_scan() {
    require_tools
    mkdir -p "$STATE_DIR"

    local origin
    origin=$(origin_url)
    [[ -n "$origin" ]] && state_set "origin_url" "$origin"

    log "${BLUE}Scanning full git history with gitleaks (this can take minutes on large repos)...${NC}"
    gitleaks git "$REPO_ROOT" "${GITLEAKS_CONFIG_ARGS[@]}" \
        --report-format json --report-path "$FINDINGS_JSON" --exit-code 0 \
        > /dev/null 2>&1 \
        || exit_with_json "error" "gitleaks scan failed" "Re-run manually: gitleaks git ${REPO_ROOT} --report-format json"

    local total
    total=$(jq 'length' "$FINDINGS_JSON")
    if [[ "$total" -eq 0 ]]; then
        state_set "phase" "clean"
        exit_with_json "success" "Git history is clean — no gitleaks findings" "" \
            '"findings_total": 0'
    fi

    # Dedupe into distinct secrets with stable ids
    jq '[group_by(.Secret)[] | {
            secret: .[0].Secret,
            rule: .[0].RuleID,
            files: (map(.File) | unique),
            finding_count: length,
            commits: (map(.Commit[0:8]) | unique)
        }] | to_entries | map(.value + {id: (.key + 1)})' \
        "$FINDINGS_JSON" > "${SECRETS_JSON}.tmp"

    # Liveness: is each secret still present at HEAD? (live secrets need a code
    # fix BEFORE rewrite, otherwise filter-repo silently redacts working code)
    local enriched="[]"
    while IFS= read -r entry; do
        local secret live_files
        secret=$(jq -r '.secret' <<<"$entry")
        live_files=$( (cd "$REPO_ROOT" && git grep -lF "$secret" HEAD -- 2>/dev/null || true) | sed 's/^HEAD://' | jq -R . | jq -s . )
        enriched=$(jq --argjson e "$entry" --argjson lf "$live_files" \
            '. + [$e + {live_in_head: ($lf | length > 0), live_files: $lf}]' <<<"$enriched")
    done < <(jq -c '.[]' "${SECRETS_JSON}.tmp")
    echo "$enriched" > "$SECRETS_JSON"
    rm -f "${SECRETS_JSON}.tmp"
    chmod 600 "$FINDINGS_JSON" "$SECRETS_JSON"

    state_set "phase" "scanned"
    local distinct live_count
    distinct=$(jq 'length' "$SECRETS_JSON")
    live_count=$(jq '[.[] | select(.live_in_head)] | length' "$SECRETS_JSON")

    exit_with_json "ready_for_llm" "Found ${total} findings (${distinct} distinct secrets, ${live_count} still live in HEAD). Classify each and write decisions.json" \
        "Write ${DECISIONS_JSON} as a JSON array covering every id: {\"id\": N, \"action\": \"scrub\"|\"allowlist\", \"rotated\": bool (scrub only), \"note\": \"...\"}. Then run --plan." \
        "\"findings_total\": ${total}," \
        "\"distinct_secrets\": $(cat "$SECRETS_JSON")," \
        "\"decisions_path\": \"${DECISIONS_JSON}\""
}

# --- Section: plan ---
section_plan() {
    require_tools
    [[ -f "$SECRETS_JSON" ]] || exit_with_json "error" "No scan results found" "Run --scan first"
    [[ -f "$DECISIONS_JSON" ]] || exit_with_json "error" "decisions.json not found at ${DECISIONS_JSON}" "Classify the secrets from --scan output and write the decisions file first"

    jq -e 'type == "array"' "$DECISIONS_JSON" > /dev/null 2>&1 \
        || exit_with_json "error" "decisions.json is not a JSON array"

    # Every secret id must have a valid decision
    local uncovered invalid
    uncovered=$(jq --slurpfile d "$DECISIONS_JSON" \
        '[.[] | select(.id as $i | ($d[0] | map(.id) | index($i)) == null) | .id]' "$SECRETS_JSON")
    [[ "$uncovered" != "[]" ]] && exit_with_json "error" "decisions.json does not cover all secrets" "Missing ids: ${uncovered}"
    invalid=$(jq '[.[] | select(.action != "scrub" and .action != "allowlist") | .id]' "$DECISIONS_JSON")
    [[ "$invalid" != "[]" ]] && exit_with_json "error" "Invalid action values in decisions.json" "ids with bad action (must be scrub|allowlist): ${invalid}"

    # Gate: scrub-marked secrets must not be live in HEAD
    local live_scrub
    live_scrub=$(jq --slurpfile d "$DECISIONS_JSON" \
        '[.[] | select(.live_in_head) | select(.id as $i | ($d[0][] | select(.id == $i) | .action) == "scrub") | {id, rule, live_files}]' \
        "$SECRETS_JSON")
    if [[ "$live_scrub" != "[]" ]]; then
        exit_with_json "blocked" "Scrub-marked secrets are still live in HEAD — remediate code first" \
            "Move these secrets to the secrets manager, commit, and push. Rewriting now would redact working code. Then re-run --scan and --plan." \
            "\"live_scrub_secrets\": ${live_scrub}"
    fi

    # Build replacements file for git filter-repo --replace-text
    local scrub_count=0
    : > "$REPLACEMENTS_TXT"
    chmod 600 "$REPLACEMENTS_TXT"
    while IFS= read -r secret; do
        if [[ "$secret" == *"==>"* ]]; then
            exit_with_json "error" "Secret contains '==>' which breaks the replace-text format" "Handle this one manually with a regex: rule in git-filter-repo docs"
        fi
        printf 'literal:%s==>***SCRUBBED***\n' "$secret" >> "$REPLACEMENTS_TXT"
        scrub_count=$((scrub_count + 1))
    done < <(jq -r --slurpfile d "$DECISIONS_JSON" \
        '.[] | select(.id as $i | ($d[0][] | select(.id == $i) | .action) == "scrub") | .secret' "$SECRETS_JSON")

    local allowlist_pending unrotated
    allowlist_pending=$(jq --slurpfile s "$SECRETS_JSON" \
        '[.[] | select(.action == "allowlist") | .id as $i | ($s[0][] | select(.id == $i)) | {id, rule, files}]' "$DECISIONS_JSON")
    unrotated=$(jq '[.[] | select(.action == "scrub" and (.rotated != true)) | .id]' "$DECISIONS_JSON")

    if [[ "$scrub_count" -eq 0 ]]; then
        state_set "phase" "planned"
        exit_with_json "success" "All findings classified as allowlist — no history rewrite needed" \
            "Add scoped allowlist entries to ${REPO_ROOT}/.gitleaks.toml for the listed secrets, commit, and push. No filter-repo run required." \
            "\"allowlist_secrets\": ${allowlist_pending}"
    fi

    state_set "phase" "planned"
    exit_with_json "needs_decision" "Plan ready: ${scrub_count} secret(s) to scrub from history" \
        "Allowlist decisions must be added to ${REPO_ROOT}/.gitleaks.toml BEFORE --rewrite (the post-rewrite verification scan uses that config). Unrotated scrub secrets will block --push. Next: run --rewrite." \
        "\"scrub_count\": ${scrub_count}," \
        "\"allowlist_secrets\": ${allowlist_pending}," \
        "\"unrotated_secret_ids\": ${unrotated}," \
        "\"replacements_path\": \"${REPLACEMENTS_TXT}\""
}

# --- Section: rewrite ---
section_rewrite() {
    require_tools
    [[ -f "$REPLACEMENTS_TXT" && -s "$REPLACEMENTS_TXT" ]] \
        || exit_with_json "error" "No replacements file found" "Run --plan first"

    local origin
    origin=$(origin_url)
    [[ -z "$origin" ]] && exit_with_json "blocked" "Repository has no 'origin' remote" "The rewrite operates on a fresh mirror clone of origin. Add a remote or scrub manually with git filter-repo."

    # Warn about local-only work: the mirror reflects origin, not local branches
    local unpushed
    unpushed=$(
        cd "$REPO_ROOT"
        for branch in $(git for-each-ref --format='%(refname:short)' refs/heads); do
            local_sha=$(git rev-parse "$branch")
            upstream_sha=$(git rev-parse --verify -q "${branch}@{upstream}" 2>/dev/null || true)
            [[ "$local_sha" != "$upstream_sha" ]] && echo "$branch" || true
        done | jq -R . | jq -s -c .
    )

    local mirror_parent mirror_dir
    mirror_parent=$(mktemp -d "${TMPDIR:-/tmp}/history-scrub-XXXXXX")
    mirror_dir="${mirror_parent}/repo.git"

    log "${BLUE}Mirror-cloning ${origin}...${NC}"
    git clone --quiet --mirror "$origin" "$mirror_dir" \
        || exit_with_json "error" "Mirror clone failed" "Check network/auth for ${origin}"

    log "${BLUE}Creating pre-rewrite backup bundle...${NC}"
    git -C "$mirror_dir" bundle create "$BACKUP_BUNDLE" --all --quiet \
        || exit_with_json "error" "Backup bundle creation failed"

    log "${BLUE}Rewriting history with git filter-repo...${NC}"
    git -C "$mirror_dir" filter-repo --replace-text "$REPLACEMENTS_TXT" --force \
        > "${STATE_DIR}/filter-repo.log" 2>&1 \
        || exit_with_json "error" "git filter-repo failed" "See ${STATE_DIR}/filter-repo.log"

    log "${BLUE}Verifying rewritten history with gitleaks...${NC}"
    local verify_report="${STATE_DIR}/verify-findings.json"
    gitleaks git "$mirror_dir" "${GITLEAKS_CONFIG_ARGS[@]}" \
        --report-format json --report-path "$verify_report" --exit-code 0 \
        > /dev/null 2>&1 \
        || exit_with_json "error" "Post-rewrite gitleaks verification scan failed to run"

    local remaining
    remaining=$(jq 'length' "$verify_report")
    if [[ "$remaining" -gt 0 ]]; then
        local remaining_summary
        remaining_summary=$(jq '[.[] | {rule: .RuleID, file: .File, commit: .Commit[0:8]}] | .[0:20]' "$verify_report")
        exit_with_json "error" "Rewritten history still has ${remaining} finding(s)" \
            "Likely causes: allowlist decisions not yet added to ${REPO_ROOT}/.gitleaks.toml, or the secret appears in a form the literal replacement missed. Full report: ${verify_report}" \
            "\"remaining_findings\": ${remaining_summary}"
    fi

    state_set "mirror_dir" "$mirror_dir"
    state_set "phase" "rewritten"
    local ref_count
    ref_count=$(git -C "$mirror_dir" for-each-ref refs/heads refs/tags | wc -l | tr -d ' ')

    exit_with_json "needs_decision" "History rewritten and verified clean in mirror — awaiting push approval" \
        "Nothing has been pushed. Review, confirm rotation, then run --push --confirm. Backup bundle: ${BACKUP_BUNDLE} (restore: git clone ${BACKUP_BUNDLE} restored). Commit map: ${mirror_dir}/filter-repo/commit-map" \
        "\"mirror_dir\": \"${mirror_dir}\"," \
        "\"refs_to_push\": ${ref_count}," \
        "\"unpushed_local_branches\": ${unpushed}," \
        "\"push_command\": \"$(basename "${BASH_SOURCE[0]}") --push --confirm\""
}

# --- Section: push ---
section_push() {
    require_tools
    local mirror_dir origin
    mirror_dir=$(state_get "mirror_dir")
    origin=$(state_get "origin_url")
    [[ -n "$mirror_dir" && -d "$mirror_dir" ]] \
        || exit_with_json "error" "No rewritten mirror found (temp dir may have been cleaned)" "Re-run --rewrite"
    [[ "$CONFIRM" -eq 1 ]] \
        || exit_with_json "needs_decision" "Refusing to force-push without --confirm" "This rewrites history on origin for ALL branches and tags. Re-run with: --push --confirm"

    # Rotation gate: every scrubbed secret must be marked rotated
    if [[ "$SKIP_ROTATION_GATE" -ne 1 ]]; then
        local unrotated
        unrotated=$(jq '[.[] | select(.action == "scrub" and (.rotated != true)) | .id]' "$DECISIONS_JSON")
        if [[ "$unrotated" != "[]" ]]; then
            exit_with_json "blocked" "Unrotated secrets block the push — scrubbing does NOT un-leak them" \
                "Old clones and GitHub caches retain the secrets. Rotate them (see /rotate-secret), set \"rotated\": true in ${DECISIONS_JSON}, and re-run. Override (not recommended): --skip-rotation-gate" \
                "\"unrotated_secret_ids\": ${unrotated}"
        fi
    fi

    # filter-repo strips the origin remote as a safety measure; restore it
    git -C "$mirror_dir" remote get-url origin &>/dev/null \
        || git -C "$mirror_dir" remote add origin "$origin"

    log "${BLUE}Force-pushing rewritten branches and tags to ${origin}...${NC}"
    # heads+tags only: GitHub rejects pushes to hidden refs/pull/* from mirrors
    if ! git -C "$mirror_dir" push --force origin 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' \
            > "${STATE_DIR}/push.log" 2>&1; then
        exit_with_json "error" "Force-push failed" \
            "Common cause: branch protection. Temporarily allow force pushes in GitHub repo settings (Settings > Branches), then re-run --push --confirm. Log: ${STATE_DIR}/push.log"
    fi

    state_set "phase" "pushed"
    exit_with_json "success" "Rewritten history pushed to origin" \
        "POST-PUSH CHECKLIST: (1) Every local clone/worktree must hard-reset: git fetch origin && git reset --hard origin/<branch> — or re-clone. (2) Unpushed local branches need rebasing via the commit map: ${mirror_dir}/filter-repo/commit-map. (3) Old PRs still reference cached commits — contact GitHub Support to purge cached views. (4) Add gitleaks to CI to prevent recurrence. Backup: ${BACKUP_BUNDLE}" \
        "\"backup_bundle\": \"${BACKUP_BUNDLE}\"," \
        "\"push_log\": \"${STATE_DIR}/push.log\""
}

# --- Section: status ---
section_status() {
    local phase
    phase=$(state_get "phase")
    [[ -z "$phase" ]] && exit_with_json "success" "No scrub workflow in progress" "Start with --scan"

    local distinct="0" decisions_exist="false"
    [[ -f "$SECRETS_JSON" ]] && distinct=$(jq 'length' "$SECRETS_JSON")
    [[ -f "$DECISIONS_JSON" ]] && decisions_exist="true"

    exit_with_json "success" "Scrub workflow phase: ${phase}" \
        "Phases: scanned -> (write decisions.json) -> planned -> rewritten -> pushed" \
        "\"phase\": \"${phase}\"," \
        "\"distinct_secrets\": ${distinct}," \
        "\"decisions_written\": ${decisions_exist}," \
        "\"state_dir\": \"${STATE_DIR}\""
}

# --- Main ---
case "$SECTION" in
    scan) section_scan ;;
    plan) section_plan ;;
    rewrite) section_rewrite ;;
    push) section_push ;;
    status) section_status ;;
esac
