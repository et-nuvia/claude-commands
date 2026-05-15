#!/usr/bin/env bash
#
# benchmark-generators.sh - Benchmark generator scripts performance
#
# Measures wall-clock time for each generator in --dry-run mode
# and compares to AI baseline (~3-10 seconds) to verify 100x improvement

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
source "${SCRIPT_DIR}/lib/common.sh" || {
    echo "Error: Failed to load common.sh library" >&2
    exit 1
}

# =============================================================================
# Configuration
# =============================================================================

ITERATIONS=5
AI_BASELINE_MS=5000  # 5 seconds average for AI-based generation
TARGET_MS=100        # Target: <100ms per operation

# =============================================================================
# Functions
# =============================================================================

# Benchmark a command
# Usage: benchmark_command "command description" "command to run"
benchmark_command() {
    local description="$1"
    local command="$2"
    local total_ms=0

    print_info "Benchmarking: $description"

    for i in $(seq 1 $ITERATIONS); do
        local start_ms=$(date +%s%3N)
        eval "$command" >/dev/null 2>&1 || true
        local end_ms=$(date +%s%3N)
        local duration_ms=$((end_ms - start_ms))
        total_ms=$((total_ms + duration_ms))
    done

    local avg_ms=$((total_ms / ITERATIONS))
    local improvement=$((AI_BASELINE_MS / avg_ms))

    # Determine status
    local status="✓"
    local color="$GREEN"
    if [[ $avg_ms -gt $TARGET_MS ]]; then
        status="⚠"
        color="$YELLOW"
    fi

    echo -e "${color}${status} ${description}: ${avg_ms}ms avg (${improvement}x faster than AI)${NC}" >&2

    # Return average for reporting
    echo "$avg_ms"
}

# =============================================================================
# Main Benchmark
# =============================================================================

main() {
    print_info "Generator Performance Benchmark"
    echo "=================================" >&2
    echo "" >&2
    print_info "Configuration:"
    echo "  Iterations: $ITERATIONS" >&2
    echo "  AI Baseline: ${AI_BASELINE_MS}ms" >&2
    echo "  Target: <${TARGET_MS}ms" >&2
    echo "" >&2

    # Create temp directory for benchmarking
    BENCH_DIR="/tmp/benchmark-generators-$$"
    mkdir -p "$BENCH_DIR"
    cd "$BENCH_DIR"

    # Setup test project
    touch pyproject.toml package.json
    cat > docker-compose.yml << 'EOF'
services:
  backend:
    image: python:3.14
  postgres:
    image: postgres:16
EOF
    git init >/dev/null 2>&1
    git remote add origin "git@github.com:user/test.git" 2>/dev/null || true

    echo "" >&2
    print_info "Running benchmarks..."
    echo "" >&2

    # Benchmark each generator
    local total_improvement=0
    local generator_count=0

    # 1. detect-tech-stack.sh
    if [[ -x "${SCRIPT_DIR}/detect-tech-stack.sh" ]]; then
        local ms
        ms=$(benchmark_command "detect-tech-stack.sh" "${SCRIPT_DIR}/detect-tech-stack.sh json")
        ((generator_count++)) || true
        local improvement=$((AI_BASELINE_MS / ms))
        total_improvement=$((total_improvement + improvement))
    fi

    # 2. detect-database.sh
    if [[ -x "${SCRIPT_DIR}/detect-database.sh" ]]; then
        local ms
        ms=$(benchmark_command "detect-database.sh" "${SCRIPT_DIR}/detect-database.sh --json")
        ((generator_count++)) || true
        local improvement=$((AI_BASELINE_MS / ms))
        total_improvement=$((total_improvement + improvement))
    fi

    # 3. init-project-config.sh
    if [[ -x "${SCRIPT_DIR}/init-project-config.sh" ]]; then
        local ms
        ms=$(benchmark_command "init-project-config.sh" "${SCRIPT_DIR}/init-project-config.sh --dry-run --non-interactive")
        ((generator_count++)) || true
        local improvement=$((AI_BASELINE_MS / ms))
        total_improvement=$((total_improvement + improvement))
    fi

    # 4. generate-dockerfile.sh
    if [[ -x "${SCRIPT_DIR}/generate-dockerfile.sh" ]]; then
        local ms
        ms=$(benchmark_command "generate-dockerfile.sh" "${SCRIPT_DIR}/generate-dockerfile.sh --template python-nix --dry-run")
        ((generator_count++)) || true
        local improvement=$((AI_BASELINE_MS / ms))
        total_improvement=$((total_improvement + improvement))
    fi

    # 5. generate-pipeline.sh
    if [[ -x "${SCRIPT_DIR}/generate-pipeline.sh" ]]; then
        local ms
        ms=$(benchmark_command "generate-pipeline.sh" "${SCRIPT_DIR}/generate-pipeline.sh --dry-run")
        ((generator_count++)) || true
        local improvement=$((AI_BASELINE_MS / ms))
        total_improvement=$((total_improvement + improvement))
    fi

    # 6. generate-makefile.sh
    if [[ -x "${SCRIPT_DIR}/generate-makefile.sh" ]]; then
        local ms
        ms=$(benchmark_command "generate-makefile.sh" "${SCRIPT_DIR}/generate-makefile.sh --dry-run")
        ((generator_count++)) || true
        local improvement=$((AI_BASELINE_MS / ms))
        total_improvement=$((total_improvement + improvement))
    fi

    # Cleanup
    cd - >/dev/null
    rm -rf "$BENCH_DIR"

    # Summary
    echo "" >&2
    print_success "Benchmark Complete"
    echo "==================" >&2

    if [[ $generator_count -gt 0 ]]; then
        local avg_improvement=$((total_improvement / generator_count))
        echo "" >&2
        echo "Average improvement: ${avg_improvement}x faster than AI" >&2
        echo "Generators tested: $generator_count" >&2

        if [[ $avg_improvement -ge 100 ]]; then
            print_success "✓ Target achieved: 100x+ improvement"
        elif [[ $avg_improvement -ge 50 ]]; then
            print_success "✓ Excellent: 50x+ improvement"
        else
            print_warning "⚠ Below target, but still significant improvement"
        fi
    fi
}

# Run benchmark
main "$@"
