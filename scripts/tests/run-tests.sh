#!/usr/bin/env bash
set -euo pipefail

# Test runner for BATS test suite
# Usage: ./run-tests.sh              # Run all tests
#        ./run-tests.sh task         # Run test-task-*.bats only
#        ./run-tests.sh common git   # Run test-common.bats and test-git-*.bats
#        ./run-tests.sh --parallel   # Run all tests in parallel

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors (only when outputting to a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Check for bats
if ! command -v bats &>/dev/null; then
    echo -e "${RED}Error: bats-core is not installed${NC}"
    echo ""
    echo "Install with:"
    echo "  macOS:  brew install bats-core"
    echo "  Linux:  npm install -g bats"
    echo "  Manual: git clone https://github.com/bats-core/bats-core.git"
    echo "          cd bats-core && sudo ./install.sh /usr/local"
    exit 1
fi

# Check for required dependencies
for cmd in jq yq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Error: $cmd is required but not installed${NC}"
        exit 1
    fi
done

# Parse args
PARALLEL=false
FILTERS=()
for arg in "$@"; do
    if [[ "$arg" == "--parallel" ]]; then
        PARALLEL=true
    else
        FILTERS+=("$arg")
    fi
done

# Auto-discover test files
ALL_TESTS=()
for f in "$SCRIPT_DIR"/test-*.bats; do
    [[ -f "$f" ]] && ALL_TESTS+=("$f")
done

if [[ ${#ALL_TESTS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No test files found${NC}"
    exit 1
fi

# Filter if patterns provided
TEST_FILES=()
if [[ ${#FILTERS[@]} -gt 0 ]]; then
    for filter in "${FILTERS[@]}"; do
        for f in "${ALL_TESTS[@]}"; do
            if [[ "$(basename "$f")" == *"${filter}"* ]]; then
                TEST_FILES+=("$f")
            fi
        done
    done
    if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
        echo -e "${RED}No test files match filter(s): ${FILTERS[*]}${NC}"
        exit 1
    fi
else
    TEST_FILES=("${ALL_TESTS[@]}")
fi

echo -e "${BLUE}Running ${#TEST_FILES[@]} test file(s)...${NC}"
echo ""

# Parse TAP output to count individual tests
# TAP format: "ok N ..." for pass, "not ok N ..." for fail, "ok N ... # skip" for skip
count_tap_results() {
    local tap_output="$1"
    local passed=0 failed=0 skipped=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^"not ok " ]]; then
            failed=$((failed + 1))
        elif [[ "$line" =~ ^"ok " ]]; then
            if [[ "$line" =~ "# skip" ]]; then
                skipped=$((skipped + 1))
            else
                passed=$((passed + 1))
            fi
        fi
    done <<< "$tap_output"
    echo "$passed $failed $skipped"
}

# Run tests
FILES_FAILED=0
FILES_PASSED=0
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

if [[ "$PARALLEL" == true ]]; then
    # True parallel: pass all files to a single bats invocation
    JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    echo -e "${BLUE}Running in parallel with $JOBS jobs...${NC}"

    tap_output=""
    if tap_output=$(bats --jobs "$JOBS" --tap "${TEST_FILES[@]}" 2>&1); then
        FILES_PASSED=${#TEST_FILES[@]}
    else
        FILES_FAILED=${#TEST_FILES[@]}
    fi

    read -r p f s <<< "$(count_tap_results "$tap_output")"
    TOTAL_PASSED=$p
    TOTAL_FAILED=$f
    TOTAL_SKIPPED=$s
    TOTAL_TESTS=$((p + f + s))

    # Print the original bats output for visibility
    echo "$tap_output"
    echo ""
else
    for test_file in "${TEST_FILES[@]}"; do
        echo -e "${BLUE}Running $(basename "$test_file")...${NC}"

        tap_output=""
        if tap_output=$(bats --tap "$test_file" 2>&1); then
            FILES_PASSED=$((FILES_PASSED + 1))
            echo -e "${GREEN}  $(basename "$test_file") passed${NC}"
        else
            FILES_FAILED=$((FILES_FAILED + 1))
            echo -e "${RED}  $(basename "$test_file") failed${NC}"
        fi

        read -r p f s <<< "$(count_tap_results "$tap_output")"
        TOTAL_PASSED=$((TOTAL_PASSED + p))
        TOTAL_FAILED=$((TOTAL_FAILED + f))
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + s))
        TOTAL_TESTS=$((TOTAL_TESTS + p + f + s))

        echo "$tap_output"
        echo ""
    done
fi

# Summary
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}=========================================${NC}"
echo -e "Files:   ${GREEN}${FILES_PASSED} passed${NC}, ${RED}${FILES_FAILED} failed${NC} (${#TEST_FILES[@]} total)"
echo -e "Tests:   ${GREEN}${TOTAL_PASSED} passed${NC}, ${RED}${TOTAL_FAILED} failed${NC}, ${YELLOW}${TOTAL_SKIPPED} skipped${NC} (${TOTAL_TESTS} total)"
echo ""

if [[ $FILES_FAILED -gt 0 || $TOTAL_FAILED -gt 0 ]]; then
    echo -e "${RED}Some tests failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
