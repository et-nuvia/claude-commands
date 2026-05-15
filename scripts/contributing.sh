#!/usr/bin/env bash
# Contributing Analysis Script
# Analyzes project context and provides contribution strategy

set -euo pipefail

# Configuration
SCRIPT_NAME="contributing.sh"
OUTPUT_MODE="json"  # json or raw
SECTION="contributing"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success) echo "execute_contribution_strategy" ;;
        *)       _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"

# Section flags
RUN_FULL=false
RUN_CONTEXT=false
RUN_STANDARDS=false
RUN_STRATEGY=false

# Output helper (delegates to output-framework)
output_json() {
  local status="$1"
  local section_name="$2"
  local message="$3"
  local data="${4:-"{}"}"

  local next_action
  next_action=$(map_status_to_action "$status")

  # Use jq to combine the JSON properly
  jq -n \
    --arg status "$status" \
    --arg section "$section_name" \
    --arg message "$message" \
    --arg data_json "$data" \
    --arg timestamp "$(date -Iseconds)" \
    --arg next_action "$next_action" \
    '{
      status: $status,
      section: $section,
      message: $message,
      next_action: $next_action,
      data: ($data_json | fromjson),
      timestamp: $timestamp
    }'
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_MODE="json"
      shift
      ;;
    --raw)
      OUTPUT_MODE="raw"
      shift
      ;;
    --full)
      RUN_FULL=true
      shift
      ;;
    --context)
      RUN_CONTEXT=true
      shift
      ;;
    --standards)
      RUN_STANDARDS=true
      shift
      ;;
    --strategy)
      RUN_STRATEGY=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# If --full, enable all sections
if [[ "$RUN_FULL" == "true" ]]; then
  RUN_CONTEXT=true
  RUN_STANDARDS=true
  RUN_STRATEGY=true
fi

# Detect git platform
detect_platform() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")

  if [[ "$remote_url" =~ github\.com ]]; then
    echo "github"
  elif [[ "$remote_url" =~ gitlab ]]; then
    echo "gitlab"
  else
    echo "unknown"
  fi
}

# Detect project type
detect_project_type() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")

  # Check if this is a fork
  if git remote | grep -q upstream; then
    echo "fork"
  # Check if it's a personal project (no CONTRIBUTING.md, and the remote
  # matches the user's self-hosted git instance from their profile, or
  # is literally labeled "personal" in the URL)
  elif [[ ! -f "CONTRIBUTING.md" ]] && {
    [[ "$remote_url" =~ personal ]] ||
    { personal_host=$(profile_env_get .git.instance 2>/dev/null); \
      [[ -n "$personal_host" ]] && \
      [[ "$personal_host" != "github.com" ]] && \
      [[ "$personal_host" != "gitlab.com" ]] && \
      [[ "$remote_url" == *"$personal_host"* ]]; };
  }; then
    echo "personal"
  # Has CONTRIBUTING.md = likely open source
  elif [[ -f "CONTRIBUTING.md" ]]; then
    echo "opensource"
  # Default to company/team
  else
    echo "company"
  fi
}

# Analyze context section
analyze_context() {
  log "=== Analyzing Context ==="

  local git_status
  local uncommitted_changes
  local unpushed_commits
  local current_branch

  git_status=$(git status --porcelain 2>/dev/null || echo "")
  uncommitted_changes=$(echo "$git_status" | wc -l | tr -d ' ')
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  # Count unpushed commits
  if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" &>/dev/null; then
    unpushed_commits=$(git log "@{u}"..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
  else
    unpushed_commits=0
  fi

  # Detect session context (has CLAUDE.md been modified recently?)
  local has_session_context=false
  if [[ -f "CLAUDE.md" ]]; then
    local modified_mins
    modified_mins=$(( ($(date +%s) - $(stat -c %Y CLAUDE.md 2>/dev/null || stat -f %m CLAUDE.md 2>/dev/null || echo 0)) / 60 ))
    if [[ $modified_mins -lt 60 ]]; then
      has_session_context=true
    fi
  fi

  log "Current branch: $current_branch"
  log "Uncommitted changes: $uncommitted_changes files"
  log "Unpushed commits: $unpushed_commits"
  log "Session context available: $has_session_context"

  # Build context data
  local context_data
  context_data=$(jq -n \
    --arg branch "$current_branch" \
    --arg uncommitted "$uncommitted_changes" \
    --arg unpushed "$unpushed_commits" \
    --arg has_session "$has_session_context" \
    '{
      current_branch: $branch,
      uncommitted_changes: ($uncommitted | tonumber),
      unpushed_commits: ($unpushed | tonumber),
      has_session_context: ($has_session | if . == "true" then true else false end)
    }')

  echo "$context_data"
}

# Analyze standards section
analyze_standards() {
  log "=== Analyzing Project Standards ==="

  local platform
  local project_type
  local has_contributing=false
  local has_pr_template=false
  local has_issue_template=false
  local has_changelog=false
  local has_license=false

  platform=$(detect_platform)
  project_type=$(detect_project_type)

  [[ -f "CONTRIBUTING.md" ]] && has_contributing=true
  [[ -f ".github/pull_request_template.md" ]] || [[ -f ".gitlab/merge_request_templates/Default.md" ]] && has_pr_template=true
  [[ -d ".github/ISSUE_TEMPLATE" ]] || [[ -d ".gitlab/issue_templates" ]] && has_issue_template=true
  [[ -f "CHANGELOG.md" ]] && has_changelog=true
  [[ -f "LICENSE" ]] || [[ -f "LICENSE.md" ]] && has_license=true

  log "Platform: $platform"
  log "Project type: $project_type"
  log "Has CONTRIBUTING.md: $has_contributing"
  log "Has PR template: $has_pr_template"
  log "Has issue templates: $has_issue_template"
  log "Has CHANGELOG: $has_changelog"
  log "Has LICENSE: $has_license"

  # Build standards data
  local standards_data
  standards_data=$(jq -n \
    --arg platform "$platform" \
    --arg project_type "$project_type" \
    --arg has_contributing "$has_contributing" \
    --arg has_pr_template "$has_pr_template" \
    --arg has_issue_template "$has_issue_template" \
    --arg has_changelog "$has_changelog" \
    --arg has_license "$has_license" \
    '{
      platform: $platform,
      project_type: $project_type,
      has_contributing: ($has_contributing | if . == "true" then true else false end),
      has_pr_template: ($has_pr_template | if . == "true" then true else false end),
      has_issue_template: ($has_issue_template | if . == "true" then true else false end),
      has_changelog: ($has_changelog | if . == "true" then true else false end),
      has_license: ($has_license | if . == "true" then true else false end)
    }')

  echo "$standards_data"
}

# Generate strategy section
generate_strategy() {
  log "=== Generating Contribution Strategy ==="

  local context_data="$1"
  local standards_data="$2"

  local uncommitted
  local unpushed
  local has_session
  local project_type

  uncommitted=$(echo "$context_data" | jq -r '.uncommitted_changes')
  unpushed=$(echo "$context_data" | jq -r '.unpushed_commits')
  has_session=$(echo "$context_data" | jq -r '.has_session_context')
  project_type=$(echo "$standards_data" | jq -r '.project_type')

  # Determine strategy based on context
  local strategy
  local next_steps=()

  if [[ $uncommitted -gt 0 ]]; then
    strategy="commit_changes"
    next_steps+=("Review and stage changes: git add <files>")
    next_steps+=("Create commit with conventional format")
    next_steps+=("Consider running tests first: make test or /test")
  fi

  if [[ $unpushed -gt 0 ]] || [[ "$strategy" == "commit_changes" ]]; then
    if [[ "$strategy" != "commit_changes" ]]; then
      strategy="create_pr"
    fi
    next_steps+=("Push branch to remote: git push")

    if [[ "$project_type" == "opensource" ]]; then
      next_steps+=("Read CONTRIBUTING.md for project-specific requirements")
      next_steps+=("Search for related issues to link")
    fi

    next_steps+=("Create PR/MR with descriptive title and body")
    next_steps+=("Request appropriate reviewers")
  fi

  if [[ $uncommitted -eq 0 ]] && [[ $unpushed -eq 0 ]]; then
    strategy="up_to_date"
    next_steps+=("No changes to contribute")
    next_steps+=("Current branch is up to date")
  fi

  log "Strategy: $strategy"
  log "Next steps: ${#next_steps[@]} items"

  # Build strategy data
  local strategy_data
  local next_steps_json
  next_steps_json=$(printf '%s\n' "${next_steps[@]}" | jq -R . | jq -s .)

  strategy_data=$(jq -n \
    --arg strategy "$strategy" \
    --argjson next_steps "$next_steps_json" \
    '{
      recommended_strategy: $strategy,
      next_steps: $next_steps
    }')

  echo "$strategy_data"
}

# Main execution
main() {
  local context_data=""
  local standards_data=""
  local strategy_data=""

  # Run context analysis
  if [[ "$RUN_CONTEXT" == "true" ]]; then
    context_data=$(analyze_context)

    if [[ "$OUTPUT_MODE" == "json" ]] && [[ "$RUN_FULL" == "false" ]]; then
      output_json "success" "context" "Context analysis complete" "$context_data"
      exit 0
    fi
  fi

  # Run standards analysis
  if [[ "$RUN_STANDARDS" == "true" ]]; then
    standards_data=$(analyze_standards)

    if [[ "$OUTPUT_MODE" == "json" ]] && [[ "$RUN_FULL" == "false" ]]; then
      output_json "success" "standards" "Standards analysis complete" "$standards_data"
      exit 0
    fi
  fi

  # Generate strategy
  if [[ "$RUN_STRATEGY" == "true" ]]; then
    # Need context and standards for strategy
    if [[ -z "$context_data" ]]; then
      context_data=$(analyze_context)
    fi
    if [[ -z "$standards_data" ]]; then
      standards_data=$(analyze_standards)
    fi

    strategy_data=$(generate_strategy "$context_data" "$standards_data")

    if [[ "$OUTPUT_MODE" == "json" ]] && [[ "$RUN_FULL" == "false" ]]; then
      output_json "success" "strategy" "Strategy generated" "$strategy_data"
      exit 0
    fi
  fi

  # Full run - combine all data
  if [[ "$RUN_FULL" == "true" ]]; then
    local combined_data
    # Ensure all data is populated
    if [[ -z "$context_data" ]]; then
      context_data=$(analyze_context)
    fi
    if [[ -z "$standards_data" ]]; then
      standards_data=$(analyze_standards)
    fi
    if [[ -z "$strategy_data" ]]; then
      strategy_data=$(generate_strategy "$context_data" "$standards_data")
    fi

    combined_data=$(jq -n \
      --argjson context "$context_data" \
      --argjson standards "$standards_data" \
      --argjson strategy "$strategy_data" \
      '{
        context: $context,
        standards: $standards,
        strategy: $strategy
      }')

    output_json "success" "full" "Contributing analysis complete" "$combined_data"
    exit 0
  fi

  # No sections specified
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    output_json "error" "none" "No sections specified. Use --full or specific section flags" "{}"
    exit 1
  else
    echo "Error: No sections specified"
    echo "Usage: $SCRIPT_NAME [--json|--raw] [--full|--context|--standards|--strategy]"
    exit 1
  fi
}

main "$@"
