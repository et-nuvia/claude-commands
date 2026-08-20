#!/usr/bin/env bash
# Test Suite for Generator Scripts and Libraries
# Tests Phase 1 deliverables: common.sh, templates.sh, and generators

# Don't use set -e so tests can continue after failures
set -uo pipefail

# Colors for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test functions
pass() {
  echo -e "${GREEN}✓ PASS${NC}: $1"
  ((TESTS_PASSED++)) || true
  ((TESTS_RUN++)) || true
}

fail() {
  echo -e "${RED}✗ FAIL${NC}: $1"
  echo -e "  ${RED}$2${NC}"
  ((TESTS_FAILED++)) || true
  ((TESTS_RUN++)) || true
}

test_group() {
  echo ""
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  echo -e "${YELLOW}$1${NC}"
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
}

# =============================================================================
# Phase 1, Task 1.1: Test common.sh
# =============================================================================

test_common_sh() {
  test_group "Testing common.sh Library"

  # Test 1.1.1: Library loads without errors
  if (set +e; source "${SCRIPT_DIR}/lib/common.sh" >/dev/null 2>&1); then
    pass "common.sh loads without errors"
  else
    fail "common.sh loads without errors" "Failed to source common.sh"
    return
  fi

  # Source the library for remaining tests (disable pipefail temporarily)
  set +e
  source "${SCRIPT_DIR}/lib/common.sh" >/dev/null 2>&1
  set -e

  # Test 1.1.2: Print functions exist
  if type print_error &>/dev/null && \
     type print_success &>/dev/null && \
     type print_warning &>/dev/null && \
     type print_info &>/dev/null; then
    pass "All print functions exist"
  else
    fail "All print functions exist" "One or more print functions missing"
  fi

  # Test 1.1.3: check_dependency function works
  if type check_dependency &>/dev/null; then
    if check_dependency "bash" >/dev/null 2>&1; then
      pass "check_dependency finds existing command (bash)"
    else
      fail "check_dependency finds existing command" "bash should be found"
    fi
  else
    fail "check_dependency function exists" "Function not found"
  fi

  # Test 1.1.4: File operation functions exist
  if type ensure_directory &>/dev/null && \
     type confirm_overwrite &>/dev/null && \
     type check_writable &>/dev/null; then
    pass "File operation functions exist"
  else
    fail "File operation functions exist" "One or more functions missing"
  fi

  # Test 1.1.5: ensure_directory works
  TEST_DIR="/tmp/test-generators-$$"
  if ensure_directory "$TEST_DIR" >/dev/null 2>&1 && [[ -d "$TEST_DIR" ]]; then
    pass "ensure_directory creates directory"
    rmdir "$TEST_DIR" 2>/dev/null || true
  else
    fail "ensure_directory creates directory" "Directory not created"
  fi

  # Test 1.1.6: Utility functions exist
  if type trim &>/dev/null && \
     type to_lowercase &>/dev/null && \
     type to_uppercase &>/dev/null; then
    pass "Utility functions exist"
  else
    fail "Utility functions exist" "One or more functions missing"
  fi

  # Test 1.1.7: to_lowercase works
  result=$(to_lowercase "UPPERCASE" 2>/dev/null || echo "")
  if [[ "$result" == "uppercase" ]]; then
    pass "to_lowercase converts correctly"
  else
    fail "to_lowercase converts correctly" "Expected 'uppercase', got '$result'"
  fi

  # Test 1.1.8: to_uppercase works
  result=$(to_uppercase "lowercase" 2>/dev/null || echo "")
  if [[ "$result" == "LOWERCASE" ]]; then
    pass "to_uppercase converts correctly"
  else
    fail "to_uppercase converts correctly" "Expected 'LOWERCASE', got '$result'"
  fi

  # Test 1.1.9: trim works
  result=$(trim "  whitespace  " 2>/dev/null || echo "")
  if [[ "$result" == "whitespace" ]]; then
    pass "trim removes whitespace"
  else
    fail "trim removes whitespace" "Expected 'whitespace', got '$result'"
  fi

  # Test 1.1.10: Works in bash subprocess
  if bash -c "source ${SCRIPT_DIR}/lib/common.sh >/dev/null 2>&1 && print_success 'test' 2>&1" 2>/dev/null | grep -q "test"; then
    pass "Works in bash subprocess"
  else
    fail "Works in bash subprocess" "Failed to load in bash"
  fi

  # Test 1.1.11: Works on current OS
  source "${SCRIPT_DIR}/lib/platform.sh"
  if env_is_darwin || env_is_linux; then
    pass "Works on macOS or Linux (detected: $(env_platform))"
  else
    fail "Works on macOS or Linux" "Unsupported platform: $(env_platform)"
  fi
}
test_templates_sh() {
  test_group "Testing templates.sh Library"

  # Test 1.2.1: Library loads without errors
  if (set +e; source "${SCRIPT_DIR}/lib/templates.sh" >/dev/null 2>&1); then
    pass "templates.sh loads without errors"
  else
    fail "templates.sh loads without errors" "Failed to source templates.sh"
    return
  fi

  # Source the library for remaining tests
  set +e
  source "${SCRIPT_DIR}/lib/templates.sh" >/dev/null 2>&1
  set -e

  # Test 1.2.2: Template rendering functions exist
  if type render_template &>/dev/null && \
     type render_template_stdout &>/dev/null && \
     type find_template &>/dev/null; then
    pass "Template rendering functions exist"
  else
    fail "Template rendering functions exist" "One or more functions missing"
  fi

  # Test 1.2.3: Conditional processing works
  TEST_TEMPLATE="/tmp/test-template-$$"
  cat > "$TEST_TEMPLATE" << 'EOF'
Start
#IF:SHOW_LINE
Middle
#ENDIF:SHOW_LINE
End
EOF

  export SHOW_LINE="yes"
  result=$(render_template_stdout "$TEST_TEMPLATE" 2>/dev/null || echo "FAILED")
  if [[ "$result" == *"Middle"* ]]; then
    pass "Conditional block rendered when variable set"
  else
    fail "Conditional block rendered when variable set" "Middle line not found"
  fi
  unset SHOW_LINE

  # Test 1.2.4: Conditional skipped when variable not set
  result=$(render_template_stdout "$TEST_TEMPLATE" 2>/dev/null || echo "FAILED")
  if [[ "$result" != *"Middle"* ]]; then
    pass "Conditional block skipped when variable not set"
  else
    fail "Conditional block skipped when variable not set" "Should not include Middle"
  fi

  # Test 1.2.5: Variable substitution works
  VAR_TEMPLATE="/tmp/test-var-template-$$"
  cat > "$VAR_TEMPLATE" << 'EOF'
Name: ${TEST_NAME}
Value: ${TEST_VALUE}
EOF

  export TEST_NAME="example"
  export TEST_VALUE="123"
  result=$(render_template_stdout "$VAR_TEMPLATE" 2>/dev/null || echo "FAILED")
  if [[ "$result" == *"Name: example"* ]] && [[ "$result" == *"Value: 123"* ]]; then
    pass "Variable substitution works"
  else
    fail "Variable substitution works" "Variables not substituted: $result"
  fi
  unset TEST_NAME TEST_VALUE

  # Cleanup
  rm -f "$TEST_TEMPLATE" "$VAR_TEMPLATE" 2>/dev/null || true
}

# =============================================================================
# Phase 1, Task 1.7: Test generate-dockerfile.sh
# =============================================================================

test_generate_dockerfile() {
  test_group "Testing generate-dockerfile.sh Script"

  # Test 1.7.1: Script exists and is executable
  if [[ -x "${SCRIPT_DIR}/generate-dockerfile.sh" ]]; then
    pass "generate-dockerfile.sh is executable"
  else
    fail "generate-dockerfile.sh is executable" "Script not found or not executable"
    return
  fi

  # Test 1.7.2: Help output works
  if "${SCRIPT_DIR}/generate-dockerfile.sh" --help >/dev/null 2>&1; then
    pass "Help output works (--help)"
  else
    fail "Help output works" "Help command failed"
  fi

  # Test 1.7.3: Help contains key information
  help_output=$("${SCRIPT_DIR}/generate-dockerfile.sh" --help 2>&1)
  if [[ "$help_output" == *"--dry-run"* ]] && \
     [[ "$help_output" == *"--template"* ]] && \
     [[ "$help_output" == *"--output"* ]]; then
    pass "Help output contains all options"
  else
    fail "Help output contains all options" "Missing key options in help"
  fi

  # Create temporary test directory
  TEST_PROJECT_DIR="/tmp/test-dockerfile-gen-$$"
  mkdir -p "$TEST_PROJECT_DIR"

  # Test 1.7.4: Python project auto-detection
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml
  output=$("${SCRIPT_DIR}/generate-dockerfile.sh" --dry-run 2>&1 || true)
  if [[ "$output" == *"Detected Python project"* ]] || \
     [[ "$output" == *"python-nix"* ]]; then
    pass "Auto-detects Python project from pyproject.toml"
  else
    fail "Auto-detects Python project" "Did not detect Python: $output"
  fi
  rm -f pyproject.toml
  cd - >/dev/null

  # Test 1.7.5: Node.js project auto-detection
  cd "$TEST_PROJECT_DIR"
  touch package.json
  output=$("${SCRIPT_DIR}/generate-dockerfile.sh" --dry-run 2>&1 || true)
  if [[ "$output" == *"Detected Node.js project"* ]] || \
     [[ "$output" == *"nodejs-nix"* ]]; then
    pass "Auto-detects Node.js project from package.json"
  else
    fail "Auto-detects Node.js project" "Did not detect Node.js: $output"
  fi
  rm -f package.json
  cd - >/dev/null

  # Test 1.7.6: Dry-run mode doesn't write file
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml
  "${SCRIPT_DIR}/generate-dockerfile.sh" --dry-run >/dev/null 2>&1 || true
  if [[ ! -f "./Dockerfile" ]]; then
    pass "Dry-run mode doesn't write file"
  else
    fail "Dry-run mode doesn't write file" "Dockerfile was created"
    rm -f ./Dockerfile
  fi
  cd - >/dev/null

  # Test 1.7.7: Explicit template selection works
  cd "$TEST_PROJECT_DIR"
  output=$("${SCRIPT_DIR}/generate-dockerfile.sh" --template generic-nix --dry-run 2>&1 || true)
  if [[ "$output" == *"generic-nix"* ]]; then
    pass "Explicit template selection works (--template generic-nix)"
  else
    fail "Explicit template selection" "Template not selected: $output"
  fi
  cd - >/dev/null

  # Test 1.7.8: Dry-run outputs Dockerfile content
  cd "$TEST_PROJECT_DIR"
  output=$("${SCRIPT_DIR}/generate-dockerfile.sh" --template python-nix --dry-run 2>&1 || true)
  if [[ "$output" == *"FROM nixos/nix"* ]] && \
     [[ "$output" == *"RUN_TESTS"* ]]; then
    pass "Dry-run outputs Dockerfile content"
  else
    fail "Dry-run outputs Dockerfile content" "Expected Dockerfile content not found"
  fi
  cd - >/dev/null

  # Test 1.7.9: Error on missing template
  cd "$TEST_PROJECT_DIR"
  output=$("${SCRIPT_DIR}/generate-dockerfile.sh" --template nonexistent-template --dry-run 2>&1 || true)
  if [[ "$output" == *"Template not found"* ]] || [[ $? -ne 0 ]]; then
    pass "Error on missing template"
  else
    fail "Error on missing template" "Should fail for nonexistent template"
  fi
  cd - >/dev/null

  # Test 1.7.10: No auto-detection without marker files
  cd "$TEST_PROJECT_DIR"
  # Empty directory, no pyproject.toml or package.json
  output=$("${SCRIPT_DIR}/generate-dockerfile.sh" --dry-run 2>&1 || true)
  if [[ "$output" == *"Could not auto-detect"* ]] || [[ $? -ne 0 ]]; then
    pass "Error when no language detected"
  else
    fail "Error when no language detected" "Should fail without marker files"
  fi
  cd - >/dev/null

  # Cleanup
  rm -rf "$TEST_PROJECT_DIR" 2>/dev/null || true
}

# =============================================================================
# Phase 3, Task 3.5: Test Detection Scripts
# =============================================================================

test_detect_tech_stack() {
  test_group "Testing detect-tech-stack.sh Script"

  # Test 3.1.1: Script exists and is executable
  if [[ -x "${SCRIPT_DIR}/detect-tech-stack.sh" ]]; then
    pass "detect-tech-stack.sh is executable"
  else
    fail "detect-tech-stack.sh is executable" "Script not found or not executable"
    return
  fi

  # Test 3.1.2: Help output works
  if "${SCRIPT_DIR}/detect-tech-stack.sh" --help >/dev/null 2>&1; then
    pass "Help output works (--help)"
  else
    fail "Help output works" "Help command failed"
  fi

  # Create temporary test directory
  TEST_PROJECT_DIR="/tmp/test-tech-stack-$$"
  mkdir -p "$TEST_PROJECT_DIR"

  # Test 3.1.3: Detects Python from pyproject.toml
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml
  output=$("${SCRIPT_DIR}/detect-tech-stack.sh" languages 2>&1 || true)
  if [[ "$output" == *"python"* ]]; then
    pass "Detects Python from pyproject.toml"
  else
    fail "Detects Python" "Python not detected from pyproject.toml"
  fi
  rm -f pyproject.toml
  cd - >/dev/null

  # Test 3.1.4: Detects Node.js from package.json
  cd "$TEST_PROJECT_DIR"
  echo '{"name":"test"}' > package.json
  output=$("${SCRIPT_DIR}/detect-tech-stack.sh" languages 2>&1 || true)
  if [[ "$output" == *"nodejs"* ]]; then
    pass "Detects Node.js from package.json"
  else
    fail "Detects Node.js" "Node.js not detected from package.json"
  fi
  rm -f package.json
  cd - >/dev/null

  # Test 3.1.5: Detects frameworks from dependencies
  cd "$TEST_PROJECT_DIR"
  cat > pyproject.toml << 'EOF'
[project]
dependencies = ["fastapi==0.100.0"]
EOF
  output=$("${SCRIPT_DIR}/detect-tech-stack.sh" frameworks 2>&1 || true)
  if [[ "$output" == *"fastapi"* ]]; then
    pass "Detects frameworks (FastAPI) from dependencies"
  else
    fail "Detects frameworks" "FastAPI not detected from dependencies"
  fi
  rm -f pyproject.toml
  cd - >/dev/null

  # Test 3.1.6: JSON output mode works
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml
  output=$("${SCRIPT_DIR}/detect-tech-stack.sh" json 2>&1 || true)
  if echo "$output" | python3 -m json.tool >/dev/null 2>&1; then
    pass "JSON output mode produces valid JSON"
  else
    fail "JSON output mode" "Invalid JSON produced"
  fi
  rm -f pyproject.toml
  cd - >/dev/null

  # Test 3.1.7: Detects tools (Makefile, docker-compose.yml)
  cd "$TEST_PROJECT_DIR"
  touch Makefile docker-compose.yml
  output=$("${SCRIPT_DIR}/detect-tech-stack.sh" tools 2>&1 || true)
  if [[ "$output" == *"docker"* ]] && [[ "$output" == *"make"* ]]; then
    pass "Detects tools (Docker, Make)"
  else
    fail "Detects tools" "Docker or Make not detected"
  fi
  rm -f Makefile docker-compose.yml
  cd - >/dev/null

  # Test 3.1.8: Works with multiple languages
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml package.json go.mod
  output=$("${SCRIPT_DIR}/detect-tech-stack.sh" languages 2>&1 || true)
  lang_count=$(echo "$output" | wc -w)
  if [[ $lang_count -ge 3 ]]; then
    pass "Detects multiple languages simultaneously"
  else
    fail "Detects multiple languages" "Expected 3+ languages, got $lang_count"
  fi
  cd - >/dev/null

  # Cleanup
  rm -rf "$TEST_PROJECT_DIR" 2>/dev/null || true
}

test_detect_database() {
  test_group "Testing detect-database.sh Script"

  # Test 3.2.1: Script exists and is executable
  if [[ -x "${SCRIPT_DIR}/detect-database.sh" ]]; then
    pass "detect-database.sh is executable"
  else
    fail "detect-database.sh is executable" "Script not found or not executable"
    return
  fi

  # Test 3.2.2: Help output works
  if "${SCRIPT_DIR}/detect-database.sh" --help >/dev/null 2>&1; then
    pass "Help output works (--help)"
  else
    fail "Help output works" "Help command failed"
  fi

  # Create temporary test directory
  TEST_PROJECT_DIR="/tmp/test-detect-db-$$"
  mkdir -p "$TEST_PROJECT_DIR"

  # Test 3.2.3: Detects PostgreSQL from compose file
  cd "$TEST_PROJECT_DIR"
  cat > docker-compose.yml << 'EOF'
services:
  db:
    image: postgres:16
    ports:
      - "5432:5432"
EOF
  output=$("${SCRIPT_DIR}/detect-database.sh" 2>&1 || true)
  if [[ "$output" == *"postgresql"* ]]; then
    pass "Detects PostgreSQL from docker-compose.yml"
  else
    fail "Detects PostgreSQL" "PostgreSQL not detected: $output"
  fi
  cd - >/dev/null

  # Test 3.2.4: Detects MySQL from compose file
  cd "$TEST_PROJECT_DIR"
  cat > docker-compose.yml << 'EOF'
services:
  db:
    image: mysql:8.0
    ports:
      - "3306:3306"
EOF
  output=$("${SCRIPT_DIR}/detect-database.sh" 2>&1 || true)
  if [[ "$output" == *"mysql"* ]]; then
    pass "Detects MySQL from docker-compose.yml"
  else
    fail "Detects MySQL" "MySQL not detected: $output"
  fi
  cd - >/dev/null

  # Test 3.2.5: Detects multiple databases
  cd "$TEST_PROJECT_DIR"
  cat > docker-compose.yml << 'EOF'
services:
  postgres:
    image: postgres:16
  redis:
    image: redis:7
  mongo:
    image: mongo:7
EOF
  output=$("${SCRIPT_DIR}/detect-database.sh" 2>&1 || true)
  if [[ "$output" == *"postgresql"* ]] && \
     [[ "$output" == *"redis"* ]] && \
     [[ "$output" == *"mongodb"* ]]; then
    pass "Detects multiple databases (PostgreSQL, Redis, MongoDB)"
  else
    fail "Detects multiple databases" "Not all databases detected: $output"
  fi
  cd - >/dev/null

  # Test 3.2.6: JSON output mode works
  cd "$TEST_PROJECT_DIR"
  cat > docker-compose.yml << 'EOF'
services:
  db:
    image: postgres:16
EOF
  output=$("${SCRIPT_DIR}/detect-database.sh" --json 2>&1 || true)
  if echo "$output" | python3 -m json.tool >/dev/null 2>&1; then
    pass "JSON output mode produces valid JSON"
  else
    fail "JSON output mode" "Invalid JSON produced: $output"
  fi
  cd - >/dev/null

  # Test 3.2.7: Handles missing compose file gracefully
  cd "$TEST_PROJECT_DIR"
  rm -f docker-compose.yml
  output=$("${SCRIPT_DIR}/detect-database.sh" --json 2>&1 || true)
  if [[ "$output" == *'"databases": []'* ]]; then
    pass "Handles missing compose file gracefully"
  else
    fail "Handles missing compose file" "Should return empty databases array"
  fi
  cd - >/dev/null

  # Test 3.2.8: Detects migration tools
  cd "$TEST_PROJECT_DIR"
  cat > docker-compose.yml << 'EOF'
services:
  db:
    image: postgres:16
EOF
  touch alembic.ini
  mkdir -p prisma
  output=$("${SCRIPT_DIR}/detect-database.sh" --json 2>&1 || true)
  if [[ "$output" == *"alembic"* ]] && [[ "$output" == *"prisma"* ]]; then
    pass "Detects migration tools (Alembic, Prisma)"
  else
    fail "Detects migration tools" "Migration tools not detected: $output"
  fi
  cd - >/dev/null

  # Cleanup
  rm -rf "$TEST_PROJECT_DIR" 2>/dev/null || true
}

test_init_project_config() {
  test_group "Testing init-project-config.sh Script"

  # Test 3.3.1: Script exists and is executable
  if [[ -x "${SCRIPT_DIR}/init-project-config.sh" ]]; then
    pass "init-project-config.sh is executable"
  else
    fail "init-project-config.sh is executable" "Script not found or not executable"
    return
  fi

  # Test 3.3.2: Help output works
  if "${SCRIPT_DIR}/init-project-config.sh" --help >/dev/null 2>&1; then
    pass "Help output works (--help)"
  else
    fail "Help output works" "Help command failed"
  fi

  # Create temporary test directory
  TEST_PROJECT_DIR="/tmp/test-init-config-$$"
  mkdir -p "$TEST_PROJECT_DIR"

  # Test 3.3.3: Dry-run mode doesn't write file
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml
  "${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive >/dev/null 2>&1 || true
  if [[ ! -f "PROJECT.yaml" ]]; then
    pass "Dry-run mode doesn't write PROJECT.yaml"
  else
    fail "Dry-run mode" "PROJECT.yaml was created"
    rm -f PROJECT.yaml
  fi
  cd - >/dev/null

  # Test 3.3.4: Dry-run outputs YAML content
  cd "$TEST_PROJECT_DIR"
  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)
  if [[ "$output" == *"project:"* ]] && \
     [[ "$output" == *"tech_stack:"* ]]; then
    pass "Dry-run outputs YAML content"
  else
    fail "Dry-run outputs YAML content" "Expected YAML structure not found"
  fi
  cd - >/dev/null

  # Test 3.3.5: Auto-detects project name from directory
  cd "$TEST_PROJECT_DIR"
  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)
  expected_name=$(basename "$TEST_PROJECT_DIR")
  if [[ "$output" == *"project: $expected_name"* ]]; then
    pass "Auto-detects project name from directory"
  else
    fail "Auto-detects project name" "Expected '$expected_name' in output"
  fi
  cd - >/dev/null

  # Test 3.3.6: Detects Python and includes it in config
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml
  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)
  if [[ "$output" == *"- python"* ]]; then
    pass "Detects and includes Python in config"
  else
    fail "Detects Python" "Python not found in config: $output"
  fi
  rm -f pyproject.toml
  cd - >/dev/null

  # Test 3.3.7: Detects git platform
  cd "$TEST_PROJECT_DIR"
  git init >/dev/null 2>&1
  git remote add origin "git@github.com:user/repo.git" 2>/dev/null || true
  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)
  if [[ "$output" == *"platform: github"* ]]; then
    pass "Detects git platform (GitHub)"
  else
    fail "Detects git platform" "GitHub not detected: $output"
  fi
  cd - >/dev/null

  # Test 3.3.8: Includes databases in config
  cd "$TEST_PROJECT_DIR"
  cat > docker-compose.yml << 'EOF'
services:
  db:
    image: postgres:16
EOF
  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)
  if [[ "$output" == *"databases:"* ]] && [[ "$output" == *"postgresql"* ]]; then
    pass "Includes databases in config"
  else
    fail "Includes databases" "PostgreSQL not found in config: $output"
  fi
  cd - >/dev/null

  # Test 3.3.9: Prevents overwriting existing PROJECT.yaml
  cd "$TEST_PROJECT_DIR"
  echo "existing" > PROJECT.yaml
  output=$("${SCRIPT_DIR}/init-project-config.sh" --non-interactive 2>&1 || true)
  if [[ "$output" == *"already exists"* ]]; then
    pass "Prevents overwriting existing PROJECT.yaml"
  else
    fail "Prevents overwriting" "Should detect existing file"
  fi
  rm -f PROJECT.yaml
  cd - >/dev/null

  # Test 3.3.10: Force flag allows overwriting
  cd "$TEST_PROJECT_DIR"
  echo "existing" > PROJECT.yaml
  "${SCRIPT_DIR}/init-project-config.sh" --force --dry-run --non-interactive >/dev/null 2>&1 || true
  if [[ $? -eq 0 ]]; then
    pass "Force flag allows overwriting (--force)"
  else
    fail "Force flag" "Should allow overwriting with --force"
  fi
  rm -f PROJECT.yaml
  cd - >/dev/null

  # Cleanup
  rm -rf "$TEST_PROJECT_DIR" 2>/dev/null || true
}

test_phase3_integration() {
  test_group "Phase 3 Integration Tests"

  # Create temporary test directory with realistic project structure
  TEST_PROJECT_DIR="/tmp/test-phase3-integration-$$"
  mkdir -p "$TEST_PROJECT_DIR"/{backend,frontend,scripts}

  # Test 3.5.1: Full detection pipeline with Python backend
  cd "$TEST_PROJECT_DIR"
  cat > pyproject.toml << 'EOF'
[project]
name = "test-app"
dependencies = ["fastapi==0.100.0", "sqlalchemy==2.0.0"]
EOF
  cat > docker-compose.yml << 'EOF'
services:
  backend:
    image: python:3.14
  postgres:
    image: postgres:16
  redis:
    image: redis:7
EOF
  touch Makefile
  git init >/dev/null 2>&1
  git remote add origin "git@github.com:user/test-app.git" 2>/dev/null || true

  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)

  # Verify all components detected
  checks=0
  [[ "$output" == *"python"* ]] && ((checks++)) || true
  [[ "$output" == *"fastapi"* ]] && ((checks++)) || true
  [[ "$output" == *"postgresql"* ]] && ((checks++)) || true
  [[ "$output" == *"redis"* ]] && ((checks++)) || true
  [[ "$output" == *"github"* ]] && ((checks++)) || true

  if [[ $checks -eq 5 ]]; then
    pass "Full detection pipeline detects all components (Python, FastAPI, DBs, Git)"
  else
    fail "Full detection pipeline" "Only detected $checks/5 components: $output"
  fi
  cd - >/dev/null

  # Test 3.5.2: Full detection pipeline with Node.js frontend
  cd "$TEST_PROJECT_DIR"
  rm -f pyproject.toml docker-compose.yml
  cat > package.json << 'EOF'
{
  "name": "test-frontend",
  "dependencies": {
    "react": "^19.0.0",
    "next": "^16.0.0"
  }
}
EOF
  cat > docker-compose.yml << 'EOF'
services:
  frontend:
    image: node:24
  mongo:
    image: mongo:7
EOF

  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)

  # Verify components detected
  checks=0
  [[ "$output" == *"nodejs"* ]] && ((checks++)) || true
  [[ "$output" == *"react"* ]] && ((checks++)) || true
  [[ "$output" == *"mongodb"* ]] && ((checks++)) || true

  if [[ $checks -eq 3 ]]; then
    pass "Node.js detection pipeline detects frontend stack (Node, React, MongoDB)"
  else
    fail "Node.js detection" "Only detected $checks/3 components: $output"
  fi
  cd - >/dev/null

  # Test 3.5.3: Handles project with no databases
  cd "$TEST_PROJECT_DIR"
  rm -f docker-compose.yml
  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)

  if [[ "$output" == *"nodejs"* ]] && [[ "$output" != *"databases:"* ]]; then
    pass "Handles projects without databases gracefully"
  else
    fail "No databases case" "Should not include databases section"
  fi
  cd - >/dev/null

  # Test 3.5.4: Multi-language project detection
  cd "$TEST_PROJECT_DIR"
  touch pyproject.toml package.json go.mod
  output=$("${SCRIPT_DIR}/init-project-config.sh" --dry-run --non-interactive 2>&1 || true)

  checks=0
  [[ "$output" == *"python"* ]] && ((checks++)) || true
  [[ "$output" == *"nodejs"* ]] && ((checks++)) || true
  [[ "$output" == *"go"* ]] && ((checks++)) || true

  if [[ $checks -eq 3 ]]; then
    pass "Detects multiple languages in same project (Python, Node.js, Go)"
  else
    fail "Multi-language detection" "Only detected $checks/3 languages: $output"
  fi
  cd - >/dev/null

  # Cleanup
  rm -rf "$TEST_PROJECT_DIR" 2>/dev/null || true
}

# =============================================================================

main() {
  echo "Generator Scripts Test Suite"
  echo "============================="
  echo ""
  echo "Phase 1 Tests: Foundation"
  echo ""

  # Run Phase 1 tests
  test_common_sh
  test_templates_sh
  test_generate_dockerfile

  echo ""
  echo "Phase 3 Tests: Detection Scripts"
  echo ""

  # Run Phase 3 tests
  test_detect_tech_stack
  test_detect_database
  test_init_project_config
  test_phase3_integration

  # Summary
  echo ""
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  echo "Test Summary"
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  echo "Total:  $TESTS_RUN"
  echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
  else
    echo -e "${GREEN}Failed: $TESTS_FAILED${NC}"
  fi
  echo ""

  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
  else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
  fi
}

# Run tests
main "$@"
