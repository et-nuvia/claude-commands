#!/usr/bin/env bash
set -euo pipefail

# Training Video Generator
# Records and processes training videos using Playwright
# Usage: ./scripts/generate-training-videos.sh [--id <video_id>] [--priority high,medium] [--all]
# Copy to project: cp ~/.claude/scripts/generate-training-videos.sh ./scripts/

MANIFEST_FILE="training-videos.yaml"
SCRIPT_DIR="training/scripts"
OUTPUT_DIR="training/videos"
UPDATES_FILE="training-video-updates-required.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
VIDEO_ID=""
PRIORITIES=""
ALL_VIDEOS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --id)
            VIDEO_ID="$2"
            shift 2
            ;;
        --priority)
            PRIORITIES="$2"
            shift 2
            ;;
        --all)
            ALL_VIDEOS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: generate-training-videos.sh [--id <video_id>] [--priority high,medium] [--all]"
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# Determine which videos to generate
# ─────────────────────────────────────────────────────────────
VIDEOS_TO_GENERATE=()

if [[ -n "${VIDEO_ID}" ]]; then
    VIDEOS_TO_GENERATE+=("${VIDEO_ID}")
elif [[ -n "${PRIORITIES}" ]]; then
    if [[ -f "${UPDATES_FILE}" ]]; then
        while IFS=: read -r priority video; do
            priority_lower=$(echo "${priority}" | tr '[:upper:]' '[:lower:]')
            if [[ "${PRIORITIES}" == *"${priority_lower}"* ]]; then
                VIDEOS_TO_GENERATE+=("${video}")
            fi
        done < "${UPDATES_FILE}"
    else
        echo -e "${RED}Error: ${UPDATES_FILE} not found. Run training-video-analysis.sh first.${NC}"
        exit 1
    fi
elif [[ "${ALL_VIDEOS}" == true ]]; then
    # Extract all video IDs from manifest
    while IFS= read -r line; do
        if [[ "${line}" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"?([^\"]+)\"? ]]; then
            VIDEOS_TO_GENERATE+=("${BASH_REMATCH[1]}")
        fi
    done < "${MANIFEST_FILE}"
else
    echo "Usage: generate-training-videos.sh [--id <video_id>] [--priority high,medium] [--all]"
    echo ""
    echo "Options:"
    echo "  --id <video_id>       Generate specific video by ID"
    echo "  --priority <list>     Generate videos by priority (high,medium,low)"
    echo "  --all                 Generate all videos"
    exit 1
fi

if [[ ${#VIDEOS_TO_GENERATE[@]} -eq 0 ]]; then
    echo -e "${GREEN}No videos to generate${NC}"
    exit 0
fi

echo -e "${BLUE}Videos to generate: ${#VIDEOS_TO_GENERATE[@]}${NC}"
for v in "${VIDEOS_TO_GENERATE[@]}"; do
    echo "  • ${v}"
done
echo ""

# ─────────────────────────────────────────────────────────────
# Create output directory
# ─────────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"

# ─────────────────────────────────────────────────────────────
# Generate each video
# ─────────────────────────────────────────────────────────────
FAILED=()
SUCCEEDED=()

for video_id in "${VIDEOS_TO_GENERATE[@]}"; do
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Generating: ${video_id}${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"

    # Find script file
    SCRIPT_FILE="${SCRIPT_DIR}/${video_id}.ts"

    if [[ ! -f "${SCRIPT_FILE}" ]]; then
        # Try .js extension
        SCRIPT_FILE="${SCRIPT_DIR}/${video_id}.js"
    fi

    if [[ ! -f "${SCRIPT_FILE}" ]]; then
        echo -e "${YELLOW}Warning: Script not found for ${video_id}${NC}"
        echo "Expected: ${SCRIPT_DIR}/${video_id}.ts"
        FAILED+=("${video_id}")
        continue
    fi

    echo "Script: ${SCRIPT_FILE}"

    # Run Playwright to record video
    echo "Recording..."

    if docker compose run --rm frontend \
        npx playwright test "${SCRIPT_FILE}" \
        --project=chromium \
        --reporter=list \
        2>&1; then

        echo -e "${GREEN}✓ Recording complete${NC}"

        # Find the generated video file
        VIDEO_FILE=$(find test-results -name "*.webm" -newer "${SCRIPT_FILE}" 2>/dev/null | head -1)

        if [[ -n "${VIDEO_FILE}" ]]; then
            # Convert to MP4
            OUTPUT_FILE="${OUTPUT_DIR}/${video_id}.mp4"
            echo "Converting to MP4..."

            docker compose run --rm frontend \
                ffmpeg -i "${VIDEO_FILE}" \
                -c:v libx264 -preset medium -crf 23 \
                -c:a aac -b:a 128k \
                "${OUTPUT_FILE}" \
                -y 2>/dev/null

            echo -e "${GREEN}✓ Saved: ${OUTPUT_FILE}${NC}"

            # Generate thumbnail
            THUMB_FILE="${OUTPUT_DIR}/${video_id}-thumb.png"
            docker compose run --rm frontend \
                ffmpeg -i "${OUTPUT_FILE}" \
                -ss 00:00:02 -vframes 1 \
                "${THUMB_FILE}" \
                -y 2>/dev/null

            echo -e "${GREEN}✓ Thumbnail: ${THUMB_FILE}${NC}"

            SUCCEEDED+=("${video_id}")
        else
            echo -e "${RED}✗ Video file not found after recording${NC}"
            FAILED+=("${video_id}")
        fi
    else
        echo -e "${RED}✗ Recording failed${NC}"
        FAILED+=("${video_id}")
    fi

    echo ""
done

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  GENERATION SUMMARY${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

if [[ ${#SUCCEEDED[@]} -gt 0 ]]; then
    echo -e "${GREEN}Succeeded (${#SUCCEEDED[@]}):${NC}"
    for v in "${SUCCEEDED[@]}"; do
        echo -e "  ${GREEN}✓${NC} ${v}"
    done
    echo ""
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo -e "${RED}Failed (${#FAILED[@]}):${NC}"
    for v in "${FAILED[@]}"; do
        echo -e "  ${RED}✗${NC} ${v}"
    done
    echo ""
    exit 1
fi

echo -e "${GREEN}All videos generated successfully!${NC}"
