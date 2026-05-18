#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Start working on a task with environment setup
#
# Usage:
#   ~/.claude/scripts/task-start.sh [--json|--raw] [--full|--section] [--task-id <id>]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --identify:     Load task context from task ID/document
#   --verify:        Verify prerequisites (git status, uncommitted changes)
#   --update-repo:   Update from remote (pull latest)
#   --create-branch: Create or resume feature branch
#   --setup-env:     Start Docker, run migrations, install dependencies
#   --link-task:     Create .current-task file
#   --full:          Run all sections end-to-end (default)
#   --base-branch:   Explicit base branch to create feature branch from
#
# Workflow:
#   1. LLM calls: task-start.sh --json --full 23
#   2. If uncommitted changes: Returns {"status":"blocked", "reason":"uncommitted_changes"}
#   3. LLM handles the block (stash/commit/abort decision)
#   4. LLM continues: task-start.sh --json --verify 23
#   5. If on-hold task: Returns {"status":"needs_decision", "reason":"on_hold"}
#   6. LLM asks user, then continues appropriately
#
# Features:
#   - Auto-flow when successful (no prompts)
#   - Strategic intervention points (uncommitted changes, on-hold resume)
#   - Section-based resumption after LLM fixes issues
#   - Structured JSON for easy parsing

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status→action mappings (must be defined BEFORE sourcing)
map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        needs_decision)       echo "confirm_action" ;;
        needs_external_sync)  echo "sync_external" ;;
        blocked)              echo "fix_error" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}

# Source shared output framework
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Source utilities
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, identify, verify, update-repo, create-branch, setup-env, link-task
# Note: --identify replaces the former --load-task flag (standardized naming)
BASE_BRANCH=""      # Explicit base branch override (--base-branch flag)

# Task context
INPUT=""
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
TASK_SLUG=""
TASK_TYPE="feature"
BRANCH_NAME=""
DEFAULT_BRANCH=""
ASANA_GID=""
ON_HOLD=false
PRESERVED_BRANCH=""
HOLD_REASON=""
WAITING_ON=""
TASK_REOPENED=false

# State tracking
BRANCH_CREATED=false
BRANCH_RESUMED=false
USE_WORKTREE=true    # Default: worktrees on (DSN Decision 9). --no-worktree overrides.
WORKTREE_MODE=false  # Set to true when actually using worktree (vs branch) mode
WORKTREE_PATH=""     # Path to .worktrees/<task_id> when in worktree mode
DOCKER_STARTED=false
DOCKER_HEALTHY=false
DB_MIGRATED=false
DEPS_INSTALLED=false
SHOULD_SYNC_ASANA=false
CURRENT_TASK_FILE=".current-task"

# Warnings and next steps
WARNINGS=()
NEXT_STEPS=()

add_warning() {
    WARNINGS+=("$1")
}

add_next_step() {
    NEXT_STEPS+=("$1")
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Load task context
section_identify() {
    log "${BLUE}Loading Task Context${NC}"

    # Find task by task ID
    if [[ "$INPUT" =~ ^[A-Fa-f0-9]{6}$ ]]; then
        TASK_ID=$(normalize_task_id "$INPUT")
        TASK_DOC=$(find_primary "$TASK_ID" 2>/dev/null || echo "")

        if [[ -z "$TASK_DOC" ]]; then
            exit_with_json "error" "No task found for task ID $TASK_ID" \
                "Check docs/active/ for available tasks"
        fi

        log "${GREEN}✓${NC} Found task: $(basename "$TASK_DOC")"
    elif [[ -n "$INPUT" ]]; then
        # Try to find by path
        TASK_DOC=$(find docs/active -name "*-TSK-*.md" -o -name "*-INC-*.md" 2>/dev/null | grep "$INPUT" | head -1 || echo "")
    fi

    # Validate task document exists
    if [[ ! -f "$TASK_DOC" ]]; then
        exit_with_json "error" "Task document not found" \
            "Usage: task-start.sh [task_id]"
    fi

    # Extract metadata
    TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")
    TASK_TITLE=$(get_doc_title "$TASK_DOC")

    # Extract slug from filename
    local filename=$(basename "$TASK_DOC")
    TASK_SLUG=$(echo "$filename" | sed -E 's/^[A-F0-9]{6}-[0-9]{10}-[A-Z]{3}-//' | sed 's/.md$//' | head -c 40 | sed 's/-$//')

    # Extract Asana GID if present
    ASANA_GID=$(grep -A 20 "^## External Tracking" "$TASK_DOC" | \
                grep "^- Task GID:" | \
                sed 's/.*\[\?\([0-9]*\)\]\?/\1/' | \
                tr -d '[]' | head -1 || echo "")

    log "${GREEN}✓${NC} Loaded: $TASK_ID - $TASK_TITLE"

    # Check if task is in completed/ — reopen it
    if [[ "$TASK_DOC" == *"/completed/"* ]]; then
        log "${YELLOW}⚠${NC} Task is in completed/ — reopening"

        # Determine range folder from parent dir name
        local range_folder
        range_folder=$(basename "$(dirname "$TASK_DOC")")
        local docs_dir
        docs_dir=$(find_docs_dir)

        # Ensure target folder exists
        mkdir -p "$docs_dir/active/$range_folder"

        # Move ALL related docs from completed/ to active/
        local moved_count=0
        while IFS= read -r doc; do
            [[ -z "$doc" ]] && continue
            local doc_basename
            doc_basename=$(basename "$doc")
            local target="$docs_dir/active/$range_folder/$doc_basename"

            if git rev-parse --git-dir >/dev/null 2>&1; then
                git mv "$doc" "$target" 2>/dev/null || mv "$doc" "$target"
            else
                mv "$doc" "$target"
            fi

            log "${GREEN}✓${NC} Moved: $doc_basename"
            moved_count=$((moved_count + 1))
        done < <(find_by_id "$TASK_ID" | grep "/completed/")

        # Update TASK_DOC path to new active/ location
        TASK_DOC="$docs_dir/active/$range_folder/$(basename "$TASK_DOC")"

        # Remove "## Completion Summary" section from TSK doc (delete to next ## heading or EOF)
        if grep -q "^## Completion Summary" "$TASK_DOC" 2>/dev/null; then
            sed -i '/^## Completion Summary/,/^## [^C]/{/^## [^C]/!d}' "$TASK_DOC"
            log "${GREEN}✓${NC} Removed completion summary from task doc"
        fi

        TASK_REOPENED=true
        log "${GREEN}✓${NC} Reopened completed task ($moved_count docs moved to active/)"
    fi

    # Check for on-hold status
    if grep -q "^## Task On Hold" "$TASK_DOC"; then
        ON_HOLD=true
        HOLD_REASON=$(sed -n '/^## Task On Hold/,/^##/p' "$TASK_DOC" | grep "^###\s*Hold Reason" -A 1 | tail -1 || echo "")
        WAITING_ON=$(sed -n '/^## Task On Hold/,/^##/p' "$TASK_DOC" | grep "^\*\*Who/What\*\*:" | cut -d':' -f2- | xargs || echo "")
        PRESERVED_BRANCH=$(sed -n '/^## Task On Hold/,/^##/p' "$TASK_DOC" | grep "^\*\*Branch\*\*:" | cut -d':' -f2- | xargs || echo "")

        log "${YELLOW}⚠${NC} Task is on hold - waiting on: $WAITING_ON"

        # Check if preserved branch exists
        local branch_exists_local=$(git show-ref --verify --quiet "refs/heads/${PRESERVED_BRANCH}" && echo "true" || echo "false")
        local branch_exists_remote=$(git ls-remote --heads origin "${PRESERVED_BRANCH}" 2>/dev/null | grep -q "${PRESERVED_BRANCH}" && echo "true" || echo "false")

        # If running only this section, return decision needed
        if [[ "$SECTION" == "identify" ]]; then
            exit_with_json "needs_decision" "Task is on hold - resume decision needed" "" \
                '"on_hold": true,' \
                '"hold_reason": "'"$HOLD_REASON"'",' \
                '"waiting_on": "'"$WAITING_ON"'",' \
                '"preserved_branch": "'"$PRESERVED_BRANCH"'",' \
                '"branch_exists_local": '"$branch_exists_local"',' \
                '"branch_exists_remote": '"$branch_exists_remote"',' \
                '"task_id": "'"$TASK_ID"'",' \
                '"task_title": "'"$TASK_TITLE"'",' \
                '"task_doc": "'"$TASK_DOC"'",' \
                '"next_steps": ["LLM should ask user if ready to resume","If yes and branch exists: task-start.sh --json --resume-branch '"$INPUT"'","If yes but branch missing: task-start.sh --json --verify '"$INPUT"'","If not ready: abort"]'
        fi
    fi

    # If running only this section, return success
    if [[ "$SECTION" == "identify" ]]; then
        exit_with_json "success" "Task context loaded" "" \
            '"task_id": "'"$TASK_ID"'",' \
            '"task_title": "'"$TASK_TITLE"'",' \
            '"task_doc": "'"$TASK_DOC"'",' \
            '"asana_gid": "'"$ASANA_GID"'",' \
            '"on_hold": '"$ON_HOLD"
    fi
}

# Section 2: Verify prerequisites
section_verify() {
    log "${BLUE}Verifying Prerequisites${NC}"

    # Check git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        exit_with_json "error" "Not a git repository" \
            "Run this command from within a git repository"
    fi

    # Check for uncommitted changes (tracked files only — untracked are OK)
    local uncommitted=$(git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null)
    if [[ -n "$uncommitted" ]]; then
        local files_json=$(git status --short | grep -v '^??' | jq -R . | jq -s .)
        [[ "$files_json" == "[]" ]] && files_json="[]"

        # Only block if there are actual tracked-file changes
        if [[ "$files_json" != "[]" ]]; then
            exit_with_json "blocked" "Uncommitted changes detected - decision needed" "" \
                '"reason": "uncommitted_changes",' \
                '"uncommitted_files": '"$files_json"',' \
                '"next_steps": ["LLM should ask user: 1) Stash changes, 2) Commit first, or 3) Abort","If stash: git stash push -m '"'"'WIP before task '"$TASK_ID"''"'"' && task-start.sh --json --full --task-id '"$INPUT"'","If commit: abort and let user commit first","If abort: exit"]'
        fi
    fi

    log "${GREEN}✓${NC} Git repository clean"

    # If running only this section, return success
    if [[ "$SECTION" == "verify" ]]; then
        exit_with_json "success" "Prerequisites verified"
    fi
}

# Section 3: Update from remote
section_update_repo() {
    log "${BLUE}Updating from Remote${NC}"

    # Get default (dev) branch from PROJECT.yaml
    DEFAULT_BRANCH=$(get_default_branch)
    log "${BLUE}ℹ${NC} Default branch: $DEFAULT_BRANCH"

    # Fetch latest (best-effort, remote may not exist)
    if ! git fetch origin >/dev/null 2>&1; then
        add_warning "Failed to fetch from remote"
    fi

    # Determine base branch for new feature branch
    local current
    current=$(git branch --show-current)

    # Read project's configured integration branch from PROJECT.yaml directly.
    # This is the authoritative answer for "what's this project's dev branch" and
    # is independent of get_default_branch's well-known-name fallbacks (which
    # can transiently return master when git rev-parse races with git fetch).
    local project_dev_branch=""
    if [[ -f "PROJECT.yaml" ]] && declare -f yaml_get &>/dev/null; then
        project_dev_branch=$(yaml_get '.ci.branches.dev // ""' PROJECT.yaml 2>/dev/null)
    fi

    if [[ "$BRANCH_RESUMED" == true ]]; then
        # Resuming an existing branch — skip checkout and pull
        :
    elif [[ -n "$BASE_BRANCH" ]]; then
        # Explicit --base-branch flag provided — use it directly
        if ! git rev-parse --verify "$BASE_BRANCH" &>/dev/null; then
            exit_with_json "error" "Base branch '$BASE_BRANCH' does not exist"
        fi
        DEFAULT_BRANCH="$BASE_BRANCH"
        if [[ "$current" != "$DEFAULT_BRANCH" ]]; then
            if ! git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1; then
                add_warning "Failed to checkout $DEFAULT_BRANCH"
            fi
        fi
    elif [[ -n "$project_dev_branch" ]] && [[ "$current" == "$project_dev_branch" ]]; then
        # On the project's configured integration branch (from PROJECT.yaml ci.branches.dev).
        # This is the canonical "branch from here" case — no prompt needed,
        # even if get_default_branch resolved DEFAULT_BRANCH to something else (e.g., master).
        DEFAULT_BRANCH="$current"
    elif [[ "$current" != "$DEFAULT_BRANCH" ]] && [[ "$current" != "main" ]] && [[ "$current" != "master" ]]; then
        # We're on a non-default branch (e.g., another feature branch)
        # Ask the LLM to clarify which base branch to use
        exit_with_json "needs_decision" "Currently on branch '$current' — choose base branch for new feature" "" \
            '"reason": "base_branch_choice",' \
            '"current_branch": "'"$current"'",' \
            '"default_branch": "'"$DEFAULT_BRANCH"'",' \
            '"task_id": "'"$TASK_ID"'",' \
            '"task_title": "'"$TASK_TITLE"'",' \
            '"task_doc": "'"$TASK_DOC"'",' \
            '"next_steps": ["Ask user: branch from current ('"$current"') or dev ('"$DEFAULT_BRANCH"')?","If current: task-start.sh --json --full --base-branch '"$current"' --task-id '"$INPUT"'","If dev: task-start.sh --json --full --base-branch '"$DEFAULT_BRANCH"' --task-id '"$INPUT"'"]'
    else
        # On default branch — switch to it if needed
        if [[ "$current" != "$DEFAULT_BRANCH" ]]; then
            if ! git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1; then
                add_warning "Failed to checkout $DEFAULT_BRANCH"
            fi
        fi
    fi

    # Pull latest changes (skip if resuming branch)
    if [[ "$BRANCH_RESUMED" != true ]]; then
        # Check if remote branch exists before pulling
        if git ls-remote --heads origin "$DEFAULT_BRANCH" 2>/dev/null | grep -q .; then
            if ! git pull origin "$DEFAULT_BRANCH" >/dev/null 2>&1; then
                exit_with_json "error" "Failed to pull latest changes" \
                    "Merge conflicts or network issue. Resolve manually and retry."
            fi
            log "${GREEN}✓${NC} Updated to latest $DEFAULT_BRANCH"
        else
            log "${YELLOW}⚠${NC} Remote branch '$DEFAULT_BRANCH' not found — using local state"
        fi
    fi

    # Update document index if it exists
    if [[ -f "docs/SEQUENCE-TRACKER.md" ]]; then
        "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true
    fi

    # If running only this section, return success
    if [[ "$SECTION" == "update-repo" ]]; then
        exit_with_json "success" "Repository updated" "" \
            '"default_branch": "'"$DEFAULT_BRANCH"'"'
    fi
}

# Section 4: Create or resume feature branch
section_create_branch() {
    log "${BLUE}Creating Feature Branch${NC}"

    # Generate branch name if not resuming
    if [[ -z "$BRANCH_NAME" ]]; then
        BRANCH_NAME="${TASK_TYPE}/${TASK_ID}-${TASK_SLUG}"
    fi

    # Check if branch already exists
    if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
        log "${YELLOW}⚠${NC} Branch ${BRANCH_NAME} already exists"

        # Return needs_decision status - LLM will ask user
        if [[ "$SECTION" == "create-branch" ]]; then
            exit_with_json "needs_decision" "Branch already exists - switch decision needed" "" \
                '"branch_name": "'"$BRANCH_NAME"'",' \
                '"next_steps": ["LLM should ask user to switch to existing branch","If yes: git checkout '"$BRANCH_NAME"' && task-start.sh --json --setup-env '"$INPUT"'","If no: abort"]'
        fi

        # In full mode, check if there's an existing worktree for this branch
        if [[ "$USE_WORKTREE" == "true" ]]; then
            local existing_wt
            existing_wt=$(get_worktree_path "$TASK_ID" 2>/dev/null || echo "")
            if [[ -n "$existing_wt" ]] && [[ -d "$existing_wt" ]]; then
                WORKTREE_PATH="$existing_wt"
                WORKTREE_MODE=true
                BRANCH_RESUMED=true
                log "${GREEN}✓${NC} Resumed existing worktree: ${WORKTREE_PATH}"
            else
                # Branch exists but no worktree — switch to it (branch mode fallback)
                git checkout "${BRANCH_NAME}" >/dev/null 2>&1
                log "${GREEN}✓${NC} Switched to existing branch (no worktree)"
                BRANCH_RESUMED=true
            fi
        else
            git checkout "${BRANCH_NAME}" >/dev/null 2>&1
            log "${GREEN}✓${NC} Switched to existing branch"
            BRANCH_RESUMED=true
        fi
    else
        # Create new branch — worktree mode or branch mode
        if [[ "$USE_WORKTREE" == "true" ]] && declare -f create_task_worktree &>/dev/null; then
            WORKTREE_PATH=$(create_task_worktree "$TASK_ID" "$BRANCH_NAME") || {
                WORKTREE_PATH=""  # Clear any partial output from failed create
                log "${YELLOW}⚠${NC} Worktree creation failed — falling back to branch mode"
                git checkout -b "${BRANCH_NAME}" >/dev/null 2>&1
                BRANCH_CREATED=true
                USE_WORKTREE=false
            }
            if [[ -n "$WORKTREE_PATH" ]]; then
                WORKTREE_MODE=true
                BRANCH_CREATED=true
                log "${GREEN}✓${NC} Created worktree: ${WORKTREE_PATH} (branch: ${BRANCH_NAME})"
            fi
        else
            git checkout -b "${BRANCH_NAME}" >/dev/null 2>&1
            log "${GREEN}✓${NC} Created branch: ${BRANCH_NAME}"
            BRANCH_CREATED=true
        fi
    fi

    # If running only this section, return success
    if [[ "$SECTION" == "create-branch" ]]; then
        exit_with_json "success" "Feature branch ready" "" \
            '"branch_name": "'"$BRANCH_NAME"'",' \
            '"branch_created": '"$BRANCH_CREATED"',' \
            '"branch_resumed": '"$BRANCH_RESUMED"
    fi
}

# Special section: Resume preserved branch from on-hold
section_resume_branch() {
    log "${BLUE}Resuming Preserved Branch${NC}"

    if [[ -z "$PRESERVED_BRANCH" ]]; then
        exit_with_json "error" "No preserved branch found in task document"
    fi

    # Check local first
    if git show-ref --verify --quiet "refs/heads/${PRESERVED_BRANCH}"; then
        git checkout "${PRESERVED_BRANCH}"
        git pull origin "${PRESERVED_BRANCH}" 2>/dev/null || log "No remote branch to pull from"
        log "${GREEN}✓${NC} Resumed local branch ${PRESERVED_BRANCH}"
        BRANCH_NAME="$PRESERVED_BRANCH"
        BRANCH_RESUMED=true
    elif git ls-remote --heads origin "${PRESERVED_BRANCH}" 2>/dev/null | grep -q "${PRESERVED_BRANCH}"; then
        # Check remote
        git fetch origin "${PRESERVED_BRANCH}"
        git checkout -b "${PRESERVED_BRANCH}" "origin/${PRESERVED_BRANCH}"
        log "${GREEN}✓${NC} Checked out ${PRESERVED_BRANCH} from remote"
        BRANCH_NAME="$PRESERVED_BRANCH"
        BRANCH_RESUMED=true
    else
        exit_with_json "error" "Preserved branch not found" \
            "Branch doesn't exist locally or remotely. Create new branch instead." \
            '"branch_name": "'"$PRESERVED_BRANCH"'"'
    fi

    # If running only this section, return success
    if [[ "$SECTION" == "resume-branch" ]]; then
        exit_with_json "success" "Branch resumed from on-hold" "" \
            '"branch_name": "'"$BRANCH_NAME"'",' \
            '"on_hold_resumed": true'
    fi
}

# Section 5: Setup environment (Docker, DB, dependencies)
section_setup_env() {
    log "${BLUE}Setting Up Environment${NC}"

    # Docker services
    if [[ -f "docker-compose.yml" ]]; then
        local running
        running=$(docker compose ps --filter "status=running" --format json 2>/dev/null | jq -s 'length' 2>/dev/null | tr -dc '0-9' || echo "0")
        running="${running:-0}"
        [[ -z "$running" ]] && running=0

        if [[ $running -eq 0 ]]; then
            log "${BLUE}ℹ${NC} Starting Docker services..."

            # Use make if available
            if [[ -f "Makefile" ]] && grep -q "^up:" Makefile 2>/dev/null; then
                make up >/dev/null 2>&1 || add_warning "Docker services may have failed to start"
            else
                docker compose up -d >/dev/null 2>&1 || add_warning "Docker services may have failed to start"
            fi

            # Wait for services
            sleep 3
            DOCKER_STARTED=true
            log "${GREEN}✓${NC} Docker services started"
        else
            log "${GREEN}✓${NC} Docker services already running ($running services)"
            DOCKER_STARTED=true
        fi

        # Check health
        local unhealthy
        unhealthy=$(docker compose ps --filter "health=unhealthy" --format json 2>/dev/null | jq -s 'length' 2>/dev/null | tr -dc '0-9' || echo "0")
        unhealthy="${unhealthy:-0}"
        [[ -z "$unhealthy" ]] && unhealthy=0
        if [[ $unhealthy -gt 0 ]]; then
            add_warning "$unhealthy unhealthy containers"
            DOCKER_HEALTHY=false
        else
            DOCKER_HEALTHY=true
        fi
    fi

    # Database migrations
    if [[ -f "PROJECT.yaml" ]]; then
        local has_db=$(yaml_get '.databases[] | select(.migrations.enabled == true)' PROJECT.yaml)

        if [[ -n "$has_db" ]]; then
            log "${BLUE}ℹ${NC} Running database migrations..."

            if [[ -f "Makefile" ]] && grep -q "^migrate:" Makefile 2>/dev/null; then
                if make migrate >/dev/null 2>&1; then
                    log "${GREEN}✓${NC} Migrations completed"
                    DB_MIGRATED=true
                else
                    add_warning "Migrations may have failed"
                fi
            elif [[ -f "backend/Makefile" ]] && grep -q "^migrate:" backend/Makefile 2>/dev/null; then
                if make -C backend migrate >/dev/null 2>&1; then
                    log "${GREEN}✓${NC} Migrations completed"
                    DB_MIGRATED=true
                else
                    add_warning "Migrations may have failed"
                fi
            fi
        fi
    fi

    # Dependencies
    local deps_changed=$(git diff HEAD@{1} HEAD --name-only 2>/dev/null | grep -E "(requirements.txt|package.json|package-lock.json|go.mod|Cargo.toml)" || echo "")

    if [[ -n "$deps_changed" ]]; then
        log "${BLUE}ℹ${NC} Installing dependencies..."

        if [[ -f "Makefile" ]] && grep -q "^install:" Makefile 2>/dev/null; then
            if make install >/dev/null 2>&1; then
                log "${GREEN}✓${NC} Dependencies installed"
                DEPS_INSTALLED=true
            else
                add_warning "Dependency installation may have failed"
            fi
        fi
    fi

    # If running only this section, return success
    if [[ "$SECTION" == "setup-env" ]]; then
        exit_with_json "success" "Environment setup complete" "" \
            '"docker_started": '"$DOCKER_STARTED"',' \
            '"docker_healthy": '"$DOCKER_HEALTHY"',' \
            '"db_migrated": '"$DB_MIGRATED"',' \
            '"deps_installed": '"$DEPS_INSTALLED"
    fi
}

# Section 6: Link task documents
section_link_task() {
    log "${BLUE}Linking Task Documents${NC}"

    # Derive tracker backend from PROJECT.yaml
    local tracker_backend=""
    local tracker_id=""
    tracker_backend=$(yaml_get '.task_management.backend' PROJECT.yaml)
    # yaml_get normalizes null to empty

    # Use ASANA_GID as tracker_id for asana backend; for gitlab/github, extract from TSK doc
    if [[ "$tracker_backend" == "asana" ]] && [[ -n "$ASANA_GID" ]]; then
        tracker_id="$ASANA_GID"
    elif [[ "$tracker_backend" == "gitlab" ]] || [[ "$tracker_backend" == "github" ]]; then
        tracker_id=$(grep -A 20 "^## External Tracking" "$TASK_DOC" 2>/dev/null | \
                     grep "^- Issue:" | sed 's/.*#\([0-9]*\).*/\1/' | head -1 || echo "")
    fi

    # Create .current-task file (JSON format)
    # DEFAULT_BRANCH is the resolved base branch (from --base-branch or auto-detected)
    write_current_task "$TASK_ID" "$BRANCH_NAME" "$DEFAULT_BRANCH" "$TASK_DOC" "$tracker_backend" "$tracker_id"

    log "${GREEN}✓${NC} Created $CURRENT_TASK_FILE file"

    # Add to .gitignore if not already there
    if [[ -f ".gitignore" ]] && ! grep -q "^.current-task$" .gitignore; then
        echo ".current-task" >> .gitignore
        log "${GREEN}✓${NC} Added .current-task to .gitignore"
    fi

    # Check Asana integration
    local backend=$(yaml_get '.task_management.backend' PROJECT.yaml)
    local sync_on_start=$(yaml_get '.task_management.asana.sync_on_operations[] | select(. == "start")' PROJECT.yaml)

    if [[ "$backend" == "asana" ]] && [[ -n "$sync_on_start" ]]; then
        SHOULD_SYNC_ASANA=true
    fi

    # If running only this section, return success
    if [[ "$SECTION" == "link-task" ]]; then
        exit_with_json "success" "Task linked" "" \
            '"current_task_file": "'"$CURRENT_TASK_FILE"'",' \
            '"should_sync_asana": '"$SHOULD_SYNC_ASANA"',' \
            '"asana_gid": "'"$ASANA_GID"'"'
    fi
}

# Section 7: Assess task readiness
section_assess_task() {
    log "${BLUE}Assessing Task Readiness${NC}"

    local has_plan=false
    local has_design=false
    local req_count=0
    local ac_count=0
    local approach_decided=false

    # Cache document list for this task
    local task_docs
    task_docs=$(find_by_id "$TASK_ID")

    # Check for PLN doc
    if echo "$task_docs" | grep -q "\-PLN-"; then
        has_plan=true
    fi

    # Check for DSN doc
    if echo "$task_docs" | grep -q "\-DSN-"; then
        has_design=true
    fi

    # Count unchecked requirements (- [ ] lines in Requirements section)
    req_count=$(sed -n '/^## Requirements/,/^## /p' "$TASK_DOC" | grep -c '^\- \[ \]' || true)
    [[ -z "$req_count" ]] && req_count=0

    # Count unchecked acceptance criteria
    ac_count=$(sed -n '/^### Acceptance Criteria/,/^##/p' "$TASK_DOC" | grep -c '^\- \[ \]' || true)
    [[ -z "$ac_count" ]] && ac_count=0

    # Check if implementation approach has a decision
    if grep -q '^\*\*Decision\*\*:' "$TASK_DOC" 2>/dev/null; then
        approach_decided=true
    fi

    # Determine recommendation
    local recommendation
    if [[ "$has_plan" == true ]]; then
        recommendation="ready"
    elif [[ "$req_count" -eq 0 ]] && grep -q "^## Requirements" "$TASK_DOC" 2>/dev/null; then
        # All requirements checked off
        recommendation="ready"
    elif [[ "$ac_count" -gt 0 ]] || [[ "$approach_decided" == true ]]; then
        recommendation="needs_plan"
    else
        recommendation="needs_design"
    fi

    log "${GREEN}✓${NC} Assessment: $recommendation (plan=$has_plan, design=$has_design, pending_reqs=$req_count, pending_ac=$ac_count)"

    # Export as JSON fragment for the full response
    ASSESSMENT_JSON=$(cat <<EOFASSESS
"assessment": {
    "has_plan": $has_plan,
    "has_design": $has_design,
    "requirements_pending": $req_count,
    "acceptance_criteria_pending": $ac_count,
    "approach_decided": $approach_decided,
    "recommendation": "$recommendation"
  }
EOFASSESS
)
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --identify) SECTION="identify"; shift ;;
            --verify) SECTION="verify"; shift ;;
            --update-repo) SECTION="update-repo"; shift ;;
            --create-branch) SECTION="create-branch"; shift ;;
            --resume-branch) SECTION="resume-branch"; shift ;;
            --setup-env) SECTION="setup-env"; shift ;;
            --link-task) SECTION="link-task"; shift ;;
            --full) SECTION="full"; shift ;;
            --task-id)
                INPUT="$2"
                shift 2
                ;;
            --base-branch)
                BASE_BRANCH="$2"
                shift 2
                ;;
            --no-worktree)
                USE_WORKTREE=false
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 2
                ;;
        esac
    done

    # Validate input
    if [[ -z "$INPUT" ]]; then
        exit_with_json "error" "Missing task ID" \
            "Usage: task-start.sh [--json|--raw] [--full|--section] <task_id>"
    fi

    # Execute sections based on flag
    case "$SECTION" in
        identify)
            section_identify
            ;;
        verify)
            section_identify
            section_verify
            ;;
        update-repo)
            section_identify
            section_verify
            section_update_repo
            ;;
        create-branch)
            section_identify
            section_verify
            section_update_repo
            section_create_branch
            ;;
        resume-branch)
            section_identify
            section_resume_branch
            ;;
        setup-env)
            section_identify
            section_setup_env
            ;;
        link-task)
            section_identify
            section_link_task
            ;;
        full)
            section_identify
            section_verify
            section_update_repo
            section_create_branch

            # If worktree mode, cd into the worktree so subsequent operations
            # (.current-task write, env setup, etc.) happen in the right place.
            if [[ "$WORKTREE_MODE" == "true" ]] && [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
                cd "$WORKTREE_PATH" || exit_with_json "error" "Failed to cd into worktree: $WORKTREE_PATH"
                log "${GREEN}✓${NC} Working directory: ${WORKTREE_PATH}"
            fi

            # Link task BEFORE env setup so SHOULD_SYNC_ASANA is known early.
            # This lets the LLM sync Asana to "In Progress" before we spend minutes
            # booting Docker / running migrations / installing deps.
            section_link_task
            section_assess_task

            # If Asana sync is required, pause here and return to the LLM.
            # The LLM flips Asana status, then resumes with --setup-env.
            if [[ "$SHOULD_SYNC_ASANA" == "true" ]]; then
                local warnings_json="[]"
                if [[ ${#WARNINGS[@]} -gt 0 ]]; then
                    warnings_json=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)
                fi
                add_next_step "LLM: update task status to 'In Progress' via task adapter (task_update $ASANA_GID status in_progress)"
                add_next_step "Then run: task-start.sh --json --setup-env --task-id $TASK_ID"
                local next_steps_json
                next_steps_json=$(printf '%s\n' "${NEXT_STEPS[@]}" | jq -R . | jq -s .)
                exit_with_json "needs_external_sync" \
                    "Branch + .current-task ready — sync Asana before environment setup" \
                    "Flip Asana status first so we don't boot Docker on a task that can't be tracked" \
                    '"task_id": "'"$TASK_ID"'",' \
                    '"task_title": "'"$TASK_TITLE"'",' \
                    '"task_doc": "'"$TASK_DOC"'",' \
                    '"branch": "'"$BRANCH_NAME"'",' \
                    '"branch_created": '"$BRANCH_CREATED"',' \
                    '"branch_resumed": '"$BRANCH_RESUMED"',' \
                    '"default_branch": "'"$DEFAULT_BRANCH"'",' \
                    '"asana_gid": "'"$ASANA_GID"'",' \
                    '"should_sync_asana": true,' \
                    '"current_task_file": "'"$CURRENT_TASK_FILE"'",' \
                    '"on_hold_resumed": '"$ON_HOLD"',' \
                    '"task_reopened": '"$TASK_REOPENED"',' \
                    "$ASSESSMENT_JSON"',' \
                    '"warnings": '"$warnings_json"',' \
                    '"next_steps": '"$next_steps_json"
            fi

            # Asana not configured → run env setup inline and return full summary.
            section_setup_env

            # Build warnings and next steps arrays
            local warnings_json="[]"
            if [[ ${#WARNINGS[@]} -gt 0 ]]; then
                warnings_json=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)
            fi

            # Add default next steps
            add_next_step "Review task document: cat $TASK_DOC"
            add_next_step "Start implementation"
            add_next_step "Run tests: make test"

            local next_steps_json=$(printf '%s\n' "${NEXT_STEPS[@]}" | jq -R . | jq -s .)

            # Full success - return complete results
            exit_with_json "success" "Task started successfully" "" \
                '"task_id": "'"$TASK_ID"'",' \
                '"task_title": "'"$TASK_TITLE"'",' \
                '"task_doc": "'"$TASK_DOC"'",' \
                '"branch": "'"$BRANCH_NAME"'",' \
                '"branch_created": '"$BRANCH_CREATED"',' \
                '"branch_resumed": '"$BRANCH_RESUMED"',' \
                '"default_branch": "'"$DEFAULT_BRANCH"'",' \
                '"docker_started": '"$DOCKER_STARTED"',' \
                '"docker_healthy": '"$DOCKER_HEALTHY"',' \
                '"db_migrated": '"$DB_MIGRATED"',' \
                '"deps_installed": '"$DEPS_INSTALLED"',' \
                '"asana_gid": "'"$ASANA_GID"'",' \
                '"should_sync_asana": '"$SHOULD_SYNC_ASANA"',' \
                '"current_task_file": "'"$CURRENT_TASK_FILE"'",' \
                '"on_hold_resumed": '"$ON_HOLD"',' \
                '"task_reopened": '"$TASK_REOPENED"',' \
                '"worktree_mode": '"$WORKTREE_MODE"',' \
                '"worktree_path": "'"${WORKTREE_PATH:-}"'",' \
                "$ASSESSMENT_JSON"',' \
                '"warnings": '"$warnings_json"',' \
                '"next_steps": '"$next_steps_json"
            ;;
    esac
}

# Run main function
main "$@"
