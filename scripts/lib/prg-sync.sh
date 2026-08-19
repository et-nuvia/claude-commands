#!/usr/bin/env bash
# prg-sync.sh - Program (PRG) tracker synchronization
#
# A PRG document (docs/active/PRG-<DATETIME>-<slug>.md) tracks one initiative
# across many TSKs. Its Workstreams table is the single source of truth for
# cross-task progress. These helpers keep that table current automatically, so
# it never drifts from reality.
#
# Membership rule: a TSK belongs to a PRG if and only if its Task ID appears in
# the TSK ID column of some PRG's Workstreams table. If no PRG contains the ID,
# the TSK is simply not part of a program and every function here is a no-op
# that returns success. Program tracking must never block or fail a task
# operation — a missing PRG is the normal case, not an error.
#
# Provides:
#   prg_find_for_task      — locate the PRG owning a Task ID (empty if none)
#   prg_bind_task          — write a Task ID into a workstream row (W# binding)
#   prg_set_status         — set a workstream's Status cell (monotonic)
#   prg_workstream_status  — read a workstream's current Status
#   prg_all_done           — true when every workstream is Done or Dropped
#   prg_progress           — "done/total" counts for reporting
#   prg_complete_and_move  — mark Complete and git mv to docs/completed/
#   prg_stage_for_commit    — git add the PRG (and its new path after a move)
#
# Usage: source "${SCRIPT_DIR}/lib/prg-sync.sh"

# Guard against double-sourcing
[[ -n "${_PRG_SYNC_LOADED:-}" ]] && return 0
_PRG_SYNC_LOADED=1

_PRG_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Machine anchors delimiting the Workstreams table in a PRG document.
# They are HTML comments: invisible when rendered, untouched by Prettier.
#
# Why anchors rather than "find the table with a TSK ID column": a PRG contains
# several tables and the Verification ledger also keys rows by W#. Inferring the
# target table from its headers works only while the Workstreams table happens
# to come first and no other table gains a Status column — a silent breakage
# waiting for a section reorder. The anchor states the target explicitly.
#
# Documents without anchors still work: every reader falls back to header
# discovery, so hand-written and pre-anchor PRGs are unaffected.
_PRG_ANCHOR_BEGIN="<!-- prg:workstreams:begin -->"
_PRG_ANCHOR_END="<!-- prg:workstreams:end -->"

# Echo only the anchored Workstreams region of a PRG, or the whole file when the
# document has no anchors.
_prg_table_region() {
    local prg="$1"
    if grep -qF "$_PRG_ANCHOR_BEGIN" "$prg" 2>/dev/null; then
        awk -v b="$_PRG_ANCHOR_BEGIN" -v e="$_PRG_ANCHOR_END" '
            index($0, b) { inside = 1; next }
            index($0, e) { inside = 0; next }
            inside { print }
        ' "$prg"
    else
        cat "$prg"
    fi
}

# doc-utils.sh provides find_docs_dir(). Source only if absent so callers that
# already loaded it keep their resolved state.
if ! declare -f find_docs_dir &>/dev/null; then
    source "${_PRG_SYNC_DIR}/../doc-utils.sh"
fi

# Status vocabulary, in progression order. Index = rank.
# Used to keep updates monotonic: a later hook can advance a workstream but
# never silently regress it (e.g. a re-run of task-start after a close must not
# drag a Done row back to In progress).
_PRG_STATUSES=(
    "Not started"
    "TSK created"
    "In progress"
    "In review"
    "Merged to dev"
    "On staging"
    "In production"
    "Done"
)

# Terminal statuses — a workstream in one of these counts as finished for the
# all-done check. Blocked deliberately is NOT terminal.
_prg_is_terminal() {
    case "$1" in
        "Done"|"Dropped") return 0 ;;
        *) return 1 ;;
    esac
}

# Rank a status for monotonic comparison. Unknown/Blocked → -1 (always
# overwritable, since Blocked is a temporary state that any real progress clears).
_prg_rank() {
    local status="$1" i=0
    for s in "${_PRG_STATUSES[@]}"; do
        if [[ "$s" == "$status" ]]; then echo "$i"; return 0; fi
        ((i++))
    done
    echo "-1"
}

# Resolve the PRG search root: docs/active ROOT ONLY (no month subfolders).
# A PRG spans months, so it is deliberately not filed under one.
_prg_active_dir() {
    local docs_dir
    docs_dir=$(find_docs_dir 2>/dev/null || echo "docs")
    echo "${docs_dir}/active"
}

# ──────────────────────────────────────────────────────────────────────────
# prg_find_for_task <TASK_ID>
#
# Echoes the path of the active PRG whose Workstreams table contains TASK_ID,
# or nothing. Exit status is always 0 — "no PRG" is not an error.
#
# Only the TSK ID column is authoritative. A Task ID mentioned in prose (Notes,
# Decision log, Lessons learned) does NOT constitute membership, otherwise a
# passing reference would bind an unrelated task to the program.
# ──────────────────────────────────────────────────────────────────────────
prg_find_for_task() {
    local task_id="$1"
    [[ -z "$task_id" ]] && return 0

    # Search the current checkout first, then the main repo. When running inside
    # a worktree whose branch predates the PRG's creation, the file is absent
    # here but present in the main checkout — mirroring find_primary()'s
    # existing worktree fallback. Without this, program tracking would silently
    # no-op for exactly the tasks most likely to be mid-flight.
    local -a search_dirs=()
    local active_dir
    active_dir=$(_prg_active_dir)
    [[ -d "$active_dir" ]] && search_dirs+=("$active_dir")

    local common_dir main_root
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
    if [[ -n "$common_dir" ]]; then
        main_root=$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd || true)
        if [[ -n "$main_root" ]] && [[ -d "$main_root/docs/active" ]] \
           && [[ "$main_root/docs/active" != "$active_dir" ]]; then
            search_dirs+=("$main_root/docs/active")
        fi
    fi

    local dir prg
    for dir in "${search_dirs[@]}"; do
        # -maxdepth 1: root only, never month subfolders.
        while IFS= read -r prg; do
            [[ -z "$prg" ]] && continue
            if [[ -n "$(_prg_row_for_task "$prg" "$task_id")" ]]; then
                echo "$prg"
                return 0
            fi
        done < <(find "$dir" -maxdepth 1 -name "PRG-*.md" 2>/dev/null | sort)
    done

    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# _prg_row_for_task <prg_path> <TASK_ID>
#
# Echoes the W# of the workstream row whose TSK ID cell equals TASK_ID, or
# nothing. Internal — column positions are derived from the table header rather
# than hardcoded, so the table can gain columns without breaking this.
# ──────────────────────────────────────────────────────────────────────────
_prg_row_for_task() {
    local prg="$1" task_id="$2"
    [[ -f "$prg" ]] || return 0

    awk -v want="$task_id" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

        # Locate the Workstreams table header and learn its column layout.
        /^\|/ && idcol == 0 {
            n = split($0, cell, "|")
            for (i = 2; i < n; i++) {
                h = trim(cell[i])
                if (h == "TSK ID") idcol = i
                if (h == "W#")     wcol  = i
            }
            next
        }
        # Skip the separator row.
        idcol > 0 && /^\|[ \-|]+\|$/ { next }
        # Data rows.
        idcol > 0 && /^\|/ {
            n = split($0, cell, "|")
            if (n <= idcol) next
            if (trim(cell[idcol]) == want) {
                print (wcol > 0 && n > wcol) ? trim(cell[wcol]) : "?"
                exit
            }
        }
        # A blank line after the table ends it.
        idcol > 0 && /^[[:space:]]*$/ { exit }
    ' <(_prg_table_region "$prg")
}

# ──────────────────────────────────────────────────────────────────────────
# prg_workstream_status <prg_path> <TASK_ID>
#
# Echoes the current Status cell for the workstream owning TASK_ID.
# ──────────────────────────────────────────────────────────────────────────
prg_workstream_status() {
    local prg="$1" task_id="$2"
    [[ -f "$prg" ]] || return 0

    awk -v want="$task_id" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ && idcol == 0 {
            n = split($0, cell, "|")
            for (i = 2; i < n; i++) {
                h = trim(cell[i])
                if (h == "TSK ID") idcol = i
                if (h == "Status") scol  = i
            }
            next
        }
        idcol > 0 && /^\|[ \-|]+\|$/ { next }
        idcol > 0 && /^\|/ {
            n = split($0, cell, "|")
            if (n <= idcol || scol == 0 || n <= scol) next
            if (trim(cell[idcol]) == want) { print trim(cell[scol]); exit }
        }
        idcol > 0 && /^[[:space:]]*$/ { exit }
    ' <(_prg_table_region "$prg")
}

# ──────────────────────────────────────────────────────────────────────────
# prg_bind_task <prg_path> <W#> <TASK_ID>
#
# Writes TASK_ID into the TSK ID cell of workstream W#, establishing
# membership. Called when a TSK is first spawned from a program (e.g. by
# /feature-to-task), because until then the row holds a placeholder.
#
# Idempotent: rebinding the same ID is a no-op. Refuses to overwrite a
# DIFFERENT non-placeholder ID — that would silently orphan the existing TSK.
# Returns 1 with a message on stderr in that case.
# ──────────────────────────────────────────────────────────────────────────
prg_bind_task() {
    local prg="$1" wnum="$2" task_id="$3"
    [[ -f "$prg" && -n "$wnum" && -n "$task_id" ]] || return 0

    local existing
    existing=$(awk -v want="$wnum" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ && wcol == 0 {
            n = split($0, cell, "|")
            for (i = 2; i < n; i++) {
                h = trim(cell[i])
                if (h == "W#")     wcol  = i
                if (h == "TSK ID") idcol = i
            }
            next
        }
        wcol > 0 && /^\|[ \-|]+\|$/ { next }
        wcol > 0 && /^\|/ {
            n = split($0, cell, "|")
            if (n <= wcol || idcol == 0 || n <= idcol) next
            if (trim(cell[wcol]) == want) { print trim(cell[idcol]); exit }
        }
        wcol > 0 && /^[[:space:]]*$/ { exit }
    ' <(_prg_table_region "$prg"))

    # Placeholders that mean "not yet assigned".
    case "$existing" in
        "$task_id") return 0 ;;                    # already bound
        ""|"—"|"-"|"TBD"|"[TSK ID]") ;;            # free to bind
        *)
            echo "prg_bind_task: $wnum already bound to $existing (refusing to overwrite with $task_id)" >&2
            return 1
            ;;
    esac

    _prg_write_cell "$prg" "W#" "$wnum" "TSK ID" "$task_id"
}

# ──────────────────────────────────────────────────────────────────────────
# prg_set_status <prg_path> <TASK_ID> <new_status> [--force]
#
# Sets the Status cell for the workstream owning TASK_ID. Monotonic by default:
# refuses to move a workstream backwards through the progression, so hooks can
# fire in any order (or twice) without corrupting state. "Blocked" and
# "Dropped" always apply — they are explicit human-meaningful transitions.
# ──────────────────────────────────────────────────────────────────────────
prg_set_status() {
    local prg="$1" task_id="$2" new_status="$3" force="${4:-}"
    [[ -f "$prg" && -n "$task_id" && -n "$new_status" ]] || return 0

    local current
    current=$(prg_workstream_status "$prg" "$task_id")
    [[ "$current" == "$new_status" ]] && return 0

    if [[ "$force" != "--force" ]] && [[ "$new_status" != "Blocked" ]] && [[ "$new_status" != "Dropped" ]]; then
        local cur_rank new_rank
        cur_rank=$(_prg_rank "$current")
        new_rank=$(_prg_rank "$new_status")
        if [[ "$cur_rank" -ge 0 ]] && [[ "$new_rank" -lt "$cur_rank" ]]; then
            return 0   # would regress — silently keep the further-along status
        fi
    fi

    _prg_write_cell "$prg" "TSK ID" "$task_id" "Status" "$new_status" || return 1
    _prg_touch_last_updated "$prg"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# _prg_write_cell <prg_path> <key_header> <key_value> <target_header> <new_value>
#
# The single deterministic table mutation primitive. Finds the row whose
# <key_header> cell equals <key_value> and replaces its <target_header> cell.
# Column positions come from the table header, never hardcoded offsets, so
# Prettier's cell padding and any added columns are both tolerated.
#
# Preserves the original cell's padding width where possible so Prettier's
# realignment produces a minimal diff.
# ──────────────────────────────────────────────────────────────────────────
_prg_write_cell() {
    local prg="$1" key_h="$2" key_v="$3" tgt_h="$4" new_v="$5"
    local tmp
    tmp=$(mktemp) || return 1

    # Anchor-aware: when the document carries anchors, confine both header
    # discovery and the row match to that region, so a same-shaped table
    # elsewhere in the PRG can never be edited by mistake.
    local anchored=0
    grep -qF "$_PRG_ANCHOR_BEGIN" "$prg" 2>/dev/null && anchored=1

    awk -v key_h="$key_h" -v key_v="$key_v" -v tgt_h="$tgt_h" -v new_v="$new_v" \
        -v anchored="$anchored" -v abegin="$_PRG_ANCHOR_BEGIN" -v aend="$_PRG_ANCHOR_END" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        BEGIN { done = 0; inside = 0 }

        # Track the anchored region. Unanchored documents are always "inside".
        anchored && index($0, abegin) { inside = 1; print; next }
        anchored && index($0, aend)   { inside = 0; print; next }
        anchored && !inside { print; next }

        # Header discovery: first pipe row that carries BOTH headers.
        /^\|/ && kcol == 0 && !done {
            n = split($0, cell, "|")
            kc = 0; tc = 0
            for (i = 2; i < n; i++) {
                h = trim(cell[i])
                if (h == key_h) kc = i
                if (h == tgt_h) tc = i
            }
            if (kc > 0 && tc > 0) { kcol = kc; tcol = tc; print; next }
            print; next
        }

        kcol > 0 && !done && /^\|/ {
            n = split($0, cell, "|")
            if (n > kcol && n > tcol && trim(cell[kcol]) == key_v) {
                # Rebuild the row, replacing only the target cell. Match the
                # old cell width so the table stays visually aligned.
                oldlen = length(cell[tcol])
                pad = oldlen - length(new_v) - 2
                if (pad < 0) pad = 0
                spaces = ""
                for (j = 0; j < pad; j++) spaces = spaces " "
                cell[tcol] = " " new_v " " spaces

                out = ""
                for (i = 2; i < n; i++) out = out "|" cell[i]
                print out "|"
                done = 1
                next
            }
            print; next
        }
        { print }
    ' "$prg" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Never leave a truncated document behind.
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "_prg_write_cell: refusing to write empty output to $prg" >&2
        return 1
    fi

    mv "$tmp" "$prg"
    return 0
}

# Refresh the "Last Updated" header line.
_prg_touch_last_updated() {
    local prg="$1"
    local now
    now=$(date '+%Y-%m-%d %H:%M')
    local tmp
    tmp=$(mktemp) || return 1
    sed "s|^- \*\*Last Updated\*\*:.*|- **Last Updated**: ${now}|" "$prg" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; return 1
    }
    [[ -s "$tmp" ]] && mv "$tmp" "$prg" || rm -f "$tmp"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# prg_append_status_log <prg_path> <message>
#
# Appends a timestamped entry under "## Status Log". Best-effort.
# ──────────────────────────────────────────────────────────────────────────
prg_append_status_log() {
    local prg="$1" msg="$2"
    [[ -f "$prg" && -n "$msg" ]] || return 0

    local now tmp
    now=$(date '+%Y-%m-%d %H:%M')
    tmp=$(mktemp) || return 1

    # Insert the entry as the last line of the Status Log list — immediately
    # after the final existing entry, so the log stays chronological and no
    # stray blank line accumulates between entries on repeated appends.
    awk -v entry="- \`${now}\` — ${msg}" '
        BEGIN { in_log = 0; inserted = 0; pending = 0 }
        /^## Status Log[[:space:]]*$/ { print; in_log = 1; next }
        in_log && !inserted {
            # Buffer blank lines: we only emit them once we know the list
            # continues, so the entry lands flush against the last bullet.
            if ($0 ~ /^[[:space:]]*$/) { pending++; next }
            if ($0 ~ /^(## |---)/) {
                print entry
                for (i = 0; i < pending; i++) print ""
                inserted = 1; in_log = 0
                print; next
            }
            # Another list line — flush buffered blanks and continue.
            for (i = 0; i < pending; i++) print ""
            pending = 0
            print; next
        }
        { print }
        END {
            if (in_log && !inserted) {
                print entry
                for (i = 0; i < pending; i++) print ""
            }
        }
    ' "$prg" > "$tmp" || { rm -f "$tmp"; return 1; }

    [[ -s "$tmp" ]] && mv "$tmp" "$prg" || rm -f "$tmp"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# prg_progress <prg_path>
#
# Echoes "<terminal>/<total>" — workstreams that are Done or Dropped over the
# total row count. Rows whose W# is a placeholder still count if they carry a
# real status, because a Dropped candidate row is a legitimate terminal row.
# ──────────────────────────────────────────────────────────────────────────
prg_progress() {
    local prg="$1"
    [[ -f "$prg" ]] || { echo "0/0"; return 0; }

    awk '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        BEGIN { total = 0; term = 0 }
        /^\|/ && scol == 0 {
            n = split($0, cell, "|")
            sc = 0; ic = 0
            for (i = 2; i < n; i++) {
                h = trim(cell[i])
                if (h == "Status") sc = i
                if (h == "TSK ID") ic = i
            }
            if (sc > 0 && ic > 0) { scol = sc }
            next
        }
        scol > 0 && /^\|[ \-|]+\|$/ { next }
        scol > 0 && /^\|/ {
            n = split($0, cell, "|")
            if (n <= scol) next
            s = trim(cell[scol])
            if (s == "" || s == "Status") next
            total++
            if (s == "Done" || s == "Dropped") term++
            next
        }
        scol > 0 && /^[[:space:]]*$/ { if (total > 0) exit }
        END { print term "/" total }
    ' <(_prg_table_region "$prg")
}

# ──────────────────────────────────────────────────────────────────────────
# prg_all_done <prg_path>
#
# Returns 0 when every workstream row is Done or Dropped (and there is at least
# one row). Returns 1 otherwise. This is the gate for auto-completing a program.
# ──────────────────────────────────────────────────────────────────────────
prg_all_done() {
    local prg="$1"
    local progress term total
    progress=$(prg_progress "$prg")
    term="${progress%%/*}"
    total="${progress##*/}"

    [[ "$total" -gt 0 ]] || return 1
    [[ "$term" -eq "$total" ]] || return 1
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# prg_complete_and_move <prg_path>
#
# Marks the program Complete and relocates it to docs/completed/ ROOT (no month
# subfolder, mirroring where it lived in active/). Echoes the new path.
#
# Uses `git mv` when the file is tracked so history follows the rename.
# Deliberately does NOT tick the Closeout checklist — those items assert human
# verification (metrics re-measured, lessons promoted, docs actually fixed) that
# a script cannot confirm. The caller should surface that they remain open.
# ──────────────────────────────────────────────────────────────────────────
prg_complete_and_move() {
    local prg="$1"
    [[ -f "$prg" ]] || return 1

    # Derive the destination from the PRG's OWN location, never from cwd.
    # A PRG lives at <docs>/active/<file>; its completed sibling is
    # <docs>/completed/<file>. Resolving via find_docs_dir() would key off the
    # current working directory instead, which relocates the file into whatever
    # repo happens to be cwd — a real hazard when a caller operates on a path
    # outside its own project (worktrees, tests, cross-repo tooling).
    local active_dir docs_root completed_dir filename new_path
    active_dir=$(cd "$(dirname "$prg")" && pwd)
    filename=$(basename "$prg")

    if [[ "$(basename "$active_dir")" != "active" ]]; then
        echo "prg_complete_and_move: $prg is not in an active/ directory — refusing to move" >&2
        return 1
    fi

    docs_root=$(dirname "$active_dir")
    completed_dir="${docs_root}/completed"
    mkdir -p "$completed_dir"
    new_path="${completed_dir}/${filename}"

    if [[ -e "$new_path" ]]; then
        echo "prg_complete_and_move: $new_path already exists" >&2
        return 1
    fi

    # Flip Status: Active → Complete before moving.
    local tmp
    tmp=$(mktemp) || return 1
    sed 's|^- \*\*Status\*\*: Active.*|- **Status**: Complete|' "$prg" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; return 1
    }
    [[ -s "$tmp" ]] && mv "$tmp" "$prg" || rm -f "$tmp"

    _prg_touch_last_updated "$prg"
    prg_append_status_log "$prg" "All workstreams terminal — program completed and moved to completed/."

    # Operate git in the PRG's own repo (-C), not cwd, for the same reason the
    # destination is derived from the path above.
    if git -C "$docs_root" ls-files --error-unmatch "$prg" >/dev/null 2>&1; then
        git -C "$docs_root" mv "$prg" "$new_path" 2>/dev/null \
            || { mv "$prg" "$new_path"; git -C "$docs_root" add "$new_path" 2>/dev/null || true; }
    else
        mv "$prg" "$new_path"
        git -C "$docs_root" add "$new_path" 2>/dev/null || true
    fi

    echo "$new_path"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# prg_reopen_for_task <TASK_ID>
#
# The inverse of prg_complete_and_move. If a COMPLETED program owns this Task
# ID, move it back to docs/active/ root and flip Status back to Active. Echoes
# the restored path, or nothing.
#
# Needed because reopening a TSK invalidates the program's completion: a
# program whose workstream just went from Done back to In progress is not
# complete, and leaving it filed under completed/ would hide live work.
# ──────────────────────────────────────────────────────────────────────────
prg_reopen_for_task() {
    local task_id="$1"
    [[ -n "$task_id" ]] || return 0

    local docs_dir completed_dir
    docs_dir=$(find_docs_dir 2>/dev/null || echo "docs")
    completed_dir="${docs_dir}/completed"
    [[ -d "$completed_dir" ]] || return 0

    local prg
    while IFS= read -r prg; do
        [[ -z "$prg" ]] && continue
        [[ -n "$(_prg_row_for_task "$prg" "$task_id")" ]] || continue

        local docs_root active_dir filename new_path
        docs_root=$(dirname "$(cd "$(dirname "$prg")" && pwd)")
        active_dir="${docs_root}/active"
        mkdir -p "$active_dir"
        filename=$(basename "$prg")
        new_path="${active_dir}/${filename}"
        [[ -e "$new_path" ]] && return 0   # already an active copy; leave both alone

        local tmp
        tmp=$(mktemp) || return 0
        sed 's|^- \*\*Status\*\*: Complete.*|- **Status**: Active|' "$prg" > "$tmp" 2>/dev/null || {
            rm -f "$tmp"; return 0
        }
        [[ -s "$tmp" ]] && mv "$tmp" "$prg" || rm -f "$tmp"

        _prg_touch_last_updated "$prg"
        prg_append_status_log "$prg" "Reopened — ${task_id} was reopened, so the program is no longer complete."

        if git -C "$docs_root" ls-files --error-unmatch "$prg" >/dev/null 2>&1; then
            git -C "$docs_root" mv "$prg" "$new_path" 2>/dev/null \
                || { mv "$prg" "$new_path"; git -C "$docs_root" add "$new_path" 2>/dev/null || true; }
        else
            mv "$prg" "$new_path"
            git -C "$docs_root" add "$new_path" 2>/dev/null || true
        fi

        echo "$new_path"
        return 0
    done < <(find "$completed_dir" -maxdepth 1 -name "PRG-*.md" 2>/dev/null | sort)

    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# prg_stage_for_commit <prg_path>
#
# git add the PRG so its update rides along in the caller's commit. The PRG
# change is part of closing/starting the task, so a separate commit would split
# one logical change across two.
# ──────────────────────────────────────────────────────────────────────────
prg_stage_for_commit() {
    local prg="$1"
    [[ -n "$prg" ]] || return 0
    git add "$prg" 2>/dev/null || true
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# prg_sync_task <TASK_ID> <new_status> [--stage]
#
# The one call every task command needs. Finds the owning PRG, advances the
# workstream, logs it, optionally stages the file, and — when the new status is
# terminal and every workstream is now terminal — completes and moves the
# program.
#
# Echoes a TOON-ish set of result fields for the caller to fold into its own
# output, or nothing at all when the task belongs to no program.
# Always returns 0: program bookkeeping never fails a task operation.
# ──────────────────────────────────────────────────────────────────────────
prg_sync_task() {
    local task_id="$1" new_status="$2" stage="${3:-}"
    [[ -n "$task_id" && -n "$new_status" ]] || return 0

    local prg
    prg=$(prg_find_for_task "$task_id")
    if [[ -z "$prg" ]]; then
        # Not part of a program — the common case.
        echo "prg_member: false"
        return 0
    fi

    local before after
    before=$(prg_workstream_status "$prg" "$task_id")
    prg_set_status "$prg" "$task_id" "$new_status" || true
    after=$(prg_workstream_status "$prg" "$task_id")

    if [[ "$before" != "$after" ]]; then
        prg_append_status_log "$prg" "${task_id}: ${before:-unset} → ${after}" || true
    fi

    local progress
    progress=$(prg_progress "$prg")

    echo "prg_member: true"
    echo "prg_path: $prg"
    echo "prg_workstream_status_before: ${before:-unset}"
    echo "prg_workstream_status_after: ${after:-unset}"
    echo "prg_progress: $progress"

    local moved=""
    if _prg_is_terminal "$after" && prg_all_done "$prg"; then
        moved=$(prg_complete_and_move "$prg" 2>/dev/null || echo "")
        if [[ -n "$moved" ]]; then
            echo "prg_completed: true"
            echo "prg_new_path: $moved"
            echo "prg_closeout_checklist: unverified"
            prg="$moved"
        else
            echo "prg_completed: false"
        fi
    else
        echo "prg_completed: false"
    fi

    [[ "$stage" == "--stage" ]] && prg_stage_for_commit "$prg"
    return 0
}
