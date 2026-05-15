#!/usr/bin/env bash
# logging.sh - Unified logging library for all scripts
#
# Provides: log_info(), log_success(), log_error(), log_warn(), log_debug()
# All output goes to stderr, suppressed when OUTPUT_MODE=json
# Color support with terminal detection fallback
#
# Usage: source "${SCRIPT_DIR}/lib/logging.sh"

# Guard against double-sourcing
[[ -n "${_LOGGING_LOADED:-}" ]] && return 0
_LOGGING_LOADED=1

# =============================================================================
# Color Constants (only set if not already defined)
# =============================================================================

if [[ -t 2 ]]; then
    : "${LOG_RED:=\033[0;31m}"
    : "${LOG_GREEN:=\033[0;32m}"
    : "${LOG_YELLOW:=\033[1;33m}"
    : "${LOG_BLUE:=\033[0;34m}"
    : "${LOG_CYAN:=\033[0;36m}"
    : "${LOG_MAGENTA:=\033[0;35m}"
    : "${LOG_NC:=\033[0m}"
else
    : "${LOG_RED:=}"
    : "${LOG_GREEN:=}"
    : "${LOG_YELLOW:=}"
    : "${LOG_BLUE:=}"
    : "${LOG_CYAN:=}"
    : "${LOG_MAGENTA:=}"
    : "${LOG_NC:=}"
fi

# =============================================================================
# Core Logging Functions
# All output to stderr, suppressed when OUTPUT_MODE=json
# =============================================================================

# Internal: check if logging should be suppressed
_log_should_suppress() {
    [[ "${OUTPUT_MODE:-}" == "json" ]]
}

# Log informational message (blue)
# Usage: log_info "Processing file..."
log_info() {
    _log_should_suppress && return 0
    echo -e "${LOG_BLUE}ℹ $*${LOG_NC}" >&2
}

# Log success message (green)
# Usage: log_success "Operation completed"
log_success() {
    _log_should_suppress && return 0
    echo -e "${LOG_GREEN}✓ $*${LOG_NC}" >&2
}

# Log error message (red)
# Usage: log_error "Something went wrong"
log_error() {
    _log_should_suppress && return 0
    echo -e "${LOG_RED}✗ $*${LOG_NC}" >&2
}

# Log warning message (yellow)
# Usage: log_warn "This might cause issues"
log_warn() {
    _log_should_suppress && return 0
    echo -e "${LOG_YELLOW}⚠ $*${LOG_NC}" >&2
}

# Log debug message (cyan, only when DEBUG=1)
# Usage: log_debug "Variable x=$x"
log_debug() {
    [[ "${DEBUG:-0}" != "1" ]] && return 0
    _log_should_suppress && return 0
    echo -e "${LOG_CYAN}[DEBUG] $*${LOG_NC}" >&2
}
