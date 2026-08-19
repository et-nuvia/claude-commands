#!/usr/bin/env bash
# Shared auto-stash helpers for deploy-to-stage.sh / deploy-to-prod.sh.
#
# A dirty working tree blocks the branch switch + merge a deploy performs, so we
# stash it (tracked AND untracked) with a recognizable marker before the deploy,
# then — on success, once we've landed back on the dev branch — offer to restore
# it. The marker lets EITHER deploy script detect a stash the other one created.
#
# Sourced by both deploy scripts; relies on their `log`, colors, and cwd (repo root).

STASH_MARKER="claude-deploy-autostash"

# Stash a dirty working tree with the marker. $1 = command label (e.g. "deploy-to-prod").
# No-op (and success) when the tree is already clean.
deploy_autostash() {
    local cmd_label="$1"
    if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
        return 0
    fi
    local msg="${STASH_MARKER}|${cmd_label}|$(date -Iseconds)"
    if git stash push -u -m "$msg" >/dev/null 2>&1; then
        log "${YELLOW}⚠${NC} Uncommitted changes stashed before deploy (${msg}); you'll be prompted to restore them on success"
    else
        log "${YELLOW}⚠${NC} Uncommitted changes present but 'git stash push' failed — deploy may fail on the merge"
    fi
    return 0
}

# Echo the most recent marked stash ref (e.g. "stash@{0}"), or empty if none.
deploy_find_marked_stash() {
    git stash list 2>/dev/null | grep -F "$STASH_MARKER" | head -1 | sed 's/:.*//' || true
}

# Echo a JSON object describing the marked stash at ref $1, for the prompt so the
# user can make an educated pop-vs-drop decision. Fields: ref, message, files[], summary.
deploy_stash_details_json() {
    local ref="$1"
    local subject stat files_raw
    subject=$(git stash list 2>/dev/null | grep -F "$STASH_MARKER" | head -1 | sed 's/^[^:]*: //')
    # Prefer including untracked files (git >= 2.32); fall back to tracked-only.
    files_raw=$(git stash show --include-untracked --name-only "$ref" 2>/dev/null)
    [[ -z "$files_raw" ]] && files_raw=$(git stash show --name-only "$ref" 2>/dev/null)
    stat=$(git stash show --include-untracked --stat "$ref" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')
    [[ -z "$stat" ]] && stat=$(git stash show --stat "$ref" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')
    # Emit via env + stdin so a message with quotes/special chars can't break JSON.
    DS_REF="$ref" DS_MSG="$subject" DS_STAT="$stat" python3 -c '
import os, json, sys
files = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps({"ref": os.environ["DS_REF"], "message": os.environ["DS_MSG"],
                  "files": files, "summary": os.environ["DS_STAT"]}))
' <<<"$files_raw" 2>/dev/null \
        || printf '{"ref":"%s","message":"%s","files":[],"summary":""}' "$ref" "$subject"
}
