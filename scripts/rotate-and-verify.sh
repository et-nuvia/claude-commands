#!/usr/bin/env bash
set -euo pipefail

# Complete Rotation and Verification Script
# Performs rotation and monitors for success
#
# Usage: ./scripts/rotate-and-verify.sh --bucket <bucket> [--dry-run] [--monitor 15]
#
# Examples:
#   ./scripts/rotate-and-verify.sh --bucket database
#   ./scripts/rotate-and-verify.sh --bucket database --dry-run
#   ./scripts/rotate-and-verify.sh --bucket database --monitor 10

BUCKET=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/colors.sh"

DRY_RUN=false
MONITOR_DURATION=15

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket)
            BUCKET="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --monitor)
            MONITOR_DURATION="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --bucket <bucket> [--dry-run] [--monitor <minutes>]" >&2
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$BUCKET" ]]; then
    echo "Error: --bucket is required" >&2
    echo "Usage: $0 --bucket <bucket> [--dry-run] [--monitor <minutes>]" >&2
    exit 1
fi

echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "${BLUE}  COMPLETE ROTATION WORKFLOW${NC}"
echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "Bucket: ${CYAN}${BUCKET}${NC}"
echo "Dry run: ${CYAN}${DRY_RUN}${NC}"
echo "Monitor duration: ${CYAN}${MONITOR_DURATION} minutes${NC}"
echo ""

# Determine which rotation script to use
ROTATION_SCRIPT=""
case "$BUCKET" in
    database)
        ROTATION_SCRIPT="${SCRIPT_DIR}/rotate-database.sh"
        ;;
    *)
        ROTATION_SCRIPT="${SCRIPT_DIR}/rotate-generic.sh"
        ;;
esac

if [[ ! -x "$ROTATION_SCRIPT" ]]; then
    echo "${RED}✗${NC} Rotation script not found: ${ROTATION_SCRIPT}"
    exit 1
fi

# Phase 1: Perform rotation
echo "${BLUE}Phase 1: Performing rotation${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$DRY_RUN" == "true" ]]; then
    "$ROTATION_SCRIPT" "$BUCKET" --dry-run
    ROTATION_EXIT=$?
else
    "$ROTATION_SCRIPT" "$BUCKET"
    ROTATION_EXIT=$?
fi

if [[ $ROTATION_EXIT -ne 0 ]]; then
    echo ""
    echo "${RED}✗${NC} Rotation failed or was rolled back"
    exit 1
fi

echo ""
echo "${GREEN}✓${NC} Rotation completed successfully"

# Phase 2: Verification
if [[ "$DRY_RUN" == "false" ]]; then
    echo ""
    echo "${BLUE}Phase 2: Verification and monitoring${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    "${SCRIPT_DIR}/verify-rotation.sh" --duration "$MONITOR_DURATION"
    VERIFY_EXIT=$?

    if [[ $VERIFY_EXIT -ne 0 ]]; then
        echo ""
        echo "${RED}✗${NC} Verification failed - consider rollback"
        echo "Manual rollback: ${SCRIPT_DIR}/rollback-secret.sh ${BUCKET}"
        exit 1
    fi

    echo ""
    echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo "${GREEN}  ROTATION COMPLETE AND VERIFIED!${NC}"
    echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
else
    echo ""
    echo "${CYAN}[DRY RUN]${NC} Skipping verification phase"
fi
