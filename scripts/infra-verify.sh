#!/usr/bin/env bash
# Infrastructure verification script
# Verifies infrastructure repository is correctly linked and accessible
#
# Usage:
#   infra-verify.sh [--json|--raw] [--full|--config|--link|--tools|--validate]
#
# Flags:
#   --json    Return structured JSON output (default)
#   --raw     Return raw output with all details
#   --full    Run all verification sections (default)
#   --config  Only verify PROJECT.yaml configuration
#   --link    Only verify symlink
#   --tools   Only verify tool installations
#   --validate Only validate infrastructure files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

# Custom status-to-action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        blocked)       echo "display_summary" ;;
        intervention)  echo "confirm_action" ;;
        success)       echo "display_summary" ;;
        *)             echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Output format (default: json)
OUTPUT_FORMAT="json"

# Sections to run (default: all)
RUN_CONFIG=false
RUN_LINK=false
RUN_TOOLS=false
RUN_VALIDATE=false
RUN_ALL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    --raw) OUTPUT_FORMAT="raw"; shift ;;
    --full) RUN_ALL=true; shift ;;
    --config) RUN_CONFIG=true; shift ;;
    --link) RUN_LINK=true; shift ;;
    --tools) RUN_TOOLS=true; shift ;;
    --validate) RUN_VALIDATE=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# If no specific sections requested, run all
if [[ "$RUN_ALL" == "false" ]] && \
   [[ "$RUN_CONFIG" == "false" ]] && \
   [[ "$RUN_LINK" == "false" ]] && \
   [[ "$RUN_TOOLS" == "false" ]] && \
   [[ "$RUN_VALIDATE" == "false" ]]; then
  RUN_ALL=true
fi

# If --full specified, enable all sections
if [[ "$RUN_ALL" == "true" ]]; then
  RUN_CONFIG=true
  RUN_LINK=true
  RUN_TOOLS=true
  RUN_VALIDATE=true
fi

# Global variables for infrastructure config
INFRA_ENABLED=""
REPO_TYPE=""
REPO_URL=""
REPO_BRANCH=""
LINK_TARGET=""
LINK_SOURCE=""
EXPECTED_TARGET=""
INFRA_LOCAL=""


# Section: Verify PROJECT.yaml configuration
verify_config() {
  local section="config"

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo "=== Verifying PROJECT.yaml Configuration ==="
  fi

  # Check if PROJECT.yaml exists
  if [[ ! -f "PROJECT.yaml" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "error" "PROJECT.yaml not found" \
        "This command requires PROJECT.yaml with infrastructure configuration"
    else
      echo "❌ PROJECT.yaml not found"
      echo "This command requires PROJECT.yaml with infrastructure configuration"
    fi
    exit 1
  fi

  # Check if infrastructure is enabled
  INFRA_ENABLED=$(yaml_get '.infrastructure.enabled')

  if [[ "$INFRA_ENABLED" != "true" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "blocked" "Infrastructure not enabled for this project" \
        "To enable: Edit PROJECT.yaml and set infrastructure.enabled: true"
    else
      echo "ℹ️  Infrastructure not enabled for this project"
      echo ""
      echo "To enable infrastructure management:"
      echo "1. Edit PROJECT.yaml"
      echo "2. Set infrastructure.enabled: true"
      echo "3. Configure infrastructure.repo settings"
    fi
    exit 0
  fi

  # Load infrastructure config
  REPO_TYPE=$(yaml_get '.infrastructure.repo.type')
  REPO_URL=$(yaml_get '.infrastructure.repo.url')
  REPO_BRANCH=$(yaml_get '.infrastructure.repo.branch')
  LINK_TARGET=$(yaml_get '.infrastructure.link.target')
  LINK_SOURCE=$(yaml_get '.infrastructure.link.source')

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo "Infrastructure Configuration:"
    echo "  Type: $REPO_TYPE"
    echo "  URL/Path: $REPO_URL"
    echo "  Branch: $REPO_BRANCH"
    echo "  Link Target: $LINK_TARGET"
    echo "  Link Source: $LINK_SOURCE"
    echo ""
  fi

  # Validate required fields
  if [[ -z "$REPO_TYPE" ]] || [[ "$REPO_TYPE" == "null" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "error" "infrastructure.repo.type not set" \
        "Must be 'git' or 'local'"
    else
      echo "❌ infrastructure.repo.type not set in PROJECT.yaml"
    fi
    exit 1
  fi

  if [[ -z "$REPO_URL" ]] || [[ "$REPO_URL" == "null" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "error" "infrastructure.repo.url not set" \
        "Set the URL or path to infrastructure repository"
    else
      echo "❌ infrastructure.repo.url not set in PROJECT.yaml"
    fi
    exit 1
  fi

  if [[ -z "$LINK_TARGET" ]] || [[ "$LINK_TARGET" == "null" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "error" "infrastructure.link.target not set" \
        "Set the symlink path (e.g., 'infrastructure')"
    else
      echo "❌ infrastructure.link.target not set in PROJECT.yaml"
    fi
    exit 1
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]] && [[ "$RUN_CONFIG" == "true" ]] && [[ "$RUN_ALL" == "false" ]]; then
    SECTION="$section" exit_with_json "success" "Configuration valid" "" \
      "\"repo_type\": \"$REPO_TYPE\", \"repo_url\": \"$REPO_URL\", \"link_target\": \"$LINK_TARGET\""
  fi
}

# Section: Verify/create infrastructure repository and symlink
verify_link() {
  local section="link"

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo "=== Verifying Infrastructure Link ==="
  fi

  # Determine expected infrastructure location based on repo type
  if [[ "$REPO_TYPE" == "git" ]]; then
    INFRA_BASE="${HOME}/.infrastructure"
    INFRA_NAME=$(basename "$REPO_URL" .git)
    INFRA_LOCAL="${INFRA_BASE}/${INFRA_NAME}"

    # Check if infrastructure repo exists locally
    if [[ ! -d "$INFRA_LOCAL" ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "intervention" "Infrastructure repository not cloned" \
          "Clone to $INFRA_LOCAL? Repository: $REPO_URL"
      else
        echo "Infrastructure repository not found locally: $INFRA_LOCAL"
        echo "Repository: $REPO_URL"
        echo ""
        echo "LLM intervention needed: Clone repository"
      fi
      exit 0
    fi

    # Verify it's a git repo
    if [[ ! -d "$INFRA_LOCAL/.git" ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "error" "Not a git repository" \
          "Path exists but is not a git repository: $INFRA_LOCAL"
      else
        echo "❌ Not a git repository: $INFRA_LOCAL"
      fi
      exit 1
    fi

    # Check remote URL matches
    REMOTE_URL=$(cd "$INFRA_LOCAL" && git config --get remote.origin.url)
    if [[ "$REMOTE_URL" != "$REPO_URL" ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "error" "Remote URL mismatch" \
          "Expected: $REPO_URL, Actual: $REMOTE_URL"
      else
        echo "⚠️  Remote URL mismatch:"
        echo "  Expected: $REPO_URL"
        echo "  Actual: $REMOTE_URL"
      fi
      exit 1
    fi

    # Check branch if specified
    CURRENT_BRANCH=$(cd "$INFRA_LOCAL" && git branch --show-current)
    if [[ -n "$REPO_BRANCH" ]] && [[ "$REPO_BRANCH" != "null" ]] && [[ "$CURRENT_BRANCH" != "$REPO_BRANCH" ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "intervention" "Branch mismatch" \
          "Expected: $REPO_BRANCH, Current: $CURRENT_BRANCH. Switch branch?"
      else
        echo "⚠️  Branch mismatch:"
        echo "  Expected: $REPO_BRANCH"
        echo "  Actual: $CURRENT_BRANCH"
        echo ""
        echo "LLM intervention needed: Switch to $REPO_BRANCH"
      fi
      exit 0
    fi

    # Check for uncommitted changes
    if ! (cd "$INFRA_LOCAL" && git diff-index --quiet HEAD --); then
      if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
        echo "⚠️  Infrastructure repository has uncommitted changes:"
        cd "$INFRA_LOCAL" && git status --short
        cd - > /dev/null
      fi
    fi

    if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
      echo "✓ Infrastructure repository found: $INFRA_LOCAL"
      echo "  Remote: $REMOTE_URL"
      echo "  Branch: $CURRENT_BRANCH"
    fi

    # Determine source path within repo
    if [[ -n "$LINK_SOURCE" ]] && [[ "$LINK_SOURCE" != "null" ]] && [[ "$LINK_SOURCE" != "." ]]; then
      EXPECTED_TARGET="${INFRA_LOCAL}/${LINK_SOURCE}"
    else
      EXPECTED_TARGET="$INFRA_LOCAL"
    fi

  elif [[ "$REPO_TYPE" == "local" ]]; then
    if [[ ! -d "$REPO_URL" ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "error" "Local infrastructure path not found" \
          "Path: $REPO_URL"
      else
        echo "❌ Local infrastructure path not found: $REPO_URL"
      fi
      exit 1
    fi

    if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
      echo "✓ Local infrastructure found: $REPO_URL"
    fi

    # Determine source path
    if [[ -n "$LINK_SOURCE" ]] && [[ "$LINK_SOURCE" != "null" ]] && [[ "$LINK_SOURCE" != "." ]]; then
      EXPECTED_TARGET="${REPO_URL}/${LINK_SOURCE}"
    else
      EXPECTED_TARGET="$REPO_URL"
    fi
  fi

  # Verify source path exists
  if [[ ! -d "$EXPECTED_TARGET" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "error" "Source path not found" \
        "Path: $EXPECTED_TARGET"
    else
      echo "❌ Source path not found: $EXPECTED_TARGET"
    fi
    exit 1
  fi

  # Check symlink
  if [[ -L "$LINK_TARGET" ]]; then
    CURRENT_TARGET=$(readlink "$LINK_TARGET")

    # Resolve to absolute paths for comparison
    CURRENT_ABS=$(cd -P "$LINK_TARGET" 2>/dev/null && pwd || echo "$CURRENT_TARGET")
    EXPECTED_ABS=$(cd -P "$EXPECTED_TARGET" 2>/dev/null && pwd)

    if [[ "$CURRENT_ABS" == "$EXPECTED_ABS" ]]; then
      if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
        echo "✓ Symlink is correct: $LINK_TARGET -> $EXPECTED_TARGET"
      fi
    else
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "intervention" "Symlink points to wrong location" \
          "Current: $CURRENT_ABS, Expected: $EXPECTED_ABS. Fix symlink?"
      else
        echo "❌ Symlink points to wrong location:"
        echo "  Current: $CURRENT_ABS"
        echo "  Expected: $EXPECTED_ABS"
        echo ""
        echo "LLM intervention needed: Fix symlink"
      fi
      exit 0
    fi

  elif [[ -e "$LINK_TARGET" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "intervention" "'$LINK_TARGET' exists but is NOT a symlink" \
        "Type: $(file -b "$LINK_TARGET"). Remove and create symlink?"
    else
      echo "⚠️  '$LINK_TARGET' exists but is NOT a symlink"
      echo "  Type: $(file -b "$LINK_TARGET")"
      echo ""
      echo "LLM intervention needed: Remove and create symlink"
    fi
    exit 0

  else
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      SECTION="$section" exit_with_json "intervention" "Symlink does not exist" \
        "Create: $LINK_TARGET -> $EXPECTED_TARGET?"
    else
      echo "ℹ️  Symlink does not exist: $LINK_TARGET"
      echo "LLM intervention needed: Create symlink to $EXPECTED_TARGET"
    fi
    exit 0
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]] && [[ "$RUN_LINK" == "true" ]] && [[ "$RUN_ALL" == "false" ]]; then
    SECTION="$section" exit_with_json "success" "Symlink verified" "" \
      "\"link_target\": \"$LINK_TARGET\", \"expected_target\": \"$EXPECTED_TARGET\""
  fi
}

# Section: Verify tool installations
verify_tools() {
  local section="tools"

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo "=== Verifying Infrastructure Tools ==="
  fi

  CHECK_TOOLS=$(yaml_get '.infrastructure.validation.check_tools')

  if [[ "$CHECK_TOOLS" != "true" ]]; then
    if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
      echo "Tool validation disabled in PROJECT.yaml"
    fi

    if [[ "$OUTPUT_FORMAT" == "json" ]] && [[ "$RUN_TOOLS" == "true" ]] && [[ "$RUN_ALL" == "false" ]]; then
      SECTION="$section" exit_with_json "success" "Tool validation disabled" "" \
        "\"check_tools\": false"
    fi
    return
  fi

  local tools_status="success"
  local tools_warnings=""

  # Check Terraform
  TF_ENABLED=$(yaml_get '.infrastructure.tools[] | select(.name == "terraform") | .enabled')
  if [[ "$TF_ENABLED" == "true" ]]; then
    if command -v terraform &> /dev/null; then
      TF_VERSION=$(terraform version -json | jq -r '.terraform_version')

      if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
        echo "✓ Terraform installed: $TF_VERSION"
      fi

      # Check expected version
      TF_EXPECTED=$(yaml_get '.infrastructure.tools[] | select(.name == "terraform") | .version')
      if [[ -n "$TF_EXPECTED" ]] && [[ "$TF_EXPECTED" != "null" ]] && [[ "$TF_EXPECTED" != "latest" ]]; then
        if [[ "$TF_VERSION" != "$TF_EXPECTED" ]]; then
          tools_warnings="${tools_warnings}Terraform version mismatch: expected $TF_EXPECTED, got $TF_VERSION. "
          if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
            echo "⚠️  Version mismatch: expected $TF_EXPECTED, got $TF_VERSION"
          fi
        fi
      fi
    else
      tools_status="error"
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "error" "Terraform not found in PATH" \
          "Install: https://developer.hashicorp.com/terraform/downloads"
      else
        echo "❌ Terraform not found in PATH"
        echo "  Install: https://developer.hashicorp.com/terraform/downloads"
      fi
    fi
  fi

  # Check Ansible
  ANSIBLE_ENABLED=$(yaml_get '.infrastructure.tools[] | select(.name == "ansible") | .enabled')
  if [[ "$ANSIBLE_ENABLED" == "true" ]]; then
    if command -v ansible &> /dev/null; then
      ANSIBLE_VERSION=$(ansible --version | head -1 | sed -n 's/.*ansible \[\(core [^]]*\)\].*/\1/p')

      if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
        echo "✓ Ansible installed: $ANSIBLE_VERSION"
      fi

      # Check expected version
      ANSIBLE_EXPECTED=$(yaml_get '.infrastructure.tools[] | select(.name == "ansible") | .version')
      if [[ -n "$ANSIBLE_EXPECTED" ]] && [[ "$ANSIBLE_EXPECTED" != "null" ]] && [[ "$ANSIBLE_EXPECTED" != "latest" ]]; then
        if [[ "$ANSIBLE_VERSION" != *"$ANSIBLE_EXPECTED"* ]]; then
          tools_warnings="${tools_warnings}Ansible version mismatch: expected $ANSIBLE_EXPECTED. "
          if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
            echo "⚠️  Version mismatch: expected $ANSIBLE_EXPECTED"
          fi
        fi
      fi
    else
      tools_status="error"
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        SECTION="$section" exit_with_json "error" "Ansible not found in PATH" \
          "Install: pip install ansible"
      else
        echo "❌ Ansible not found in PATH"
        echo "  Install: pip install ansible"
      fi
    fi
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]] && [[ "$RUN_TOOLS" == "true" ]] && [[ "$RUN_ALL" == "false" ]]; then
    if [[ -n "$tools_warnings" ]]; then
      SECTION="$section" exit_with_json "success" "Tools installed with warnings" "" \
        "\"warnings\": \"$tools_warnings\""
    else
      SECTION="$section" exit_with_json "success" "All tools verified"
    fi
  fi
}

# Section: Validate infrastructure files
validate_infrastructure() {
  local section="validate"

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo "=== Validating Infrastructure Files ==="
  fi

  local tf_files=0
  local ansible_files=0

  if [[ -d "$LINK_TARGET/terraform" ]]; then
    tf_files=$(find "$LINK_TARGET/terraform" -name "*.tf" | wc -l)
    if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
      echo "  Terraform: $tf_files .tf files"
    fi
  fi

  if [[ -d "$LINK_TARGET/ansible" ]]; then
    ansible_files=$(find "$LINK_TARGET/ansible" -name "*.yml" -o -name "*.yaml" | wc -l)
    if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
      echo "  Ansible: $ansible_files playbooks"
    fi
  fi

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo ""
    echo "Infrastructure structure:"
    ls -lah "$LINK_TARGET" | head -20
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]] && [[ "$RUN_VALIDATE" == "true" ]] && [[ "$RUN_ALL" == "false" ]]; then
    SECTION="$section" exit_with_json "success" "Infrastructure validated" "" \
      "\"terraform_files\": $tf_files, \"ansible_files\": $ansible_files"
  fi
}

# Main execution
main() {
  # Always load config first
  verify_config

  # Run requested sections
  if [[ "$RUN_LINK" == "true" ]]; then
    verify_link
  fi

  if [[ "$RUN_TOOLS" == "true" ]]; then
    verify_tools
  fi

  if [[ "$RUN_VALIDATE" == "true" ]]; then
    validate_infrastructure
  fi

  # Final success output
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    SECTION="complete" exit_with_json "success" "Infrastructure verification complete" "" \
      "\"repo_type\": \"$REPO_TYPE\", \"link_target\": \"$LINK_TARGET\", \"expected_target\": \"$EXPECTED_TARGET\""
  else
    echo ""
    echo "════════════════════════════════════════"
    echo "Infrastructure Verification Summary"
    echo "════════════════════════════════════════"
    echo ""
    echo "Project: $(basename "$PWD")"
    echo "Infrastructure: $(basename "$EXPECTED_TARGET")"
    echo ""
    echo "✓ Configuration loaded from PROJECT.yaml"
    echo "✓ Infrastructure repository accessible"
    echo "✓ Symlink verified: $LINK_TARGET -> $EXPECTED_TARGET"
    echo ""
    echo "Infrastructure location: $EXPECTED_TARGET"
    echo "Terraform: $(if [[ -d "$LINK_TARGET/terraform" ]]; then echo "✓ Found"; else echo "✗ Not found"; fi)"
    echo "Ansible: $(if [[ -d "$LINK_TARGET/ansible" ]]; then echo "✓ Found"; else echo "✗ Not found"; fi)"
    echo ""
    echo "Next steps:"
    echo "- Run Terraform: cd infrastructure/terraform && terraform plan"
    echo "- Run Ansible: cd infrastructure/ansible && ansible-playbook playbooks/deploy.yml"
  fi
}

main
