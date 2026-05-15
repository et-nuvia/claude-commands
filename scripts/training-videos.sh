#!/usr/bin/env bash
set -euo pipefail

# training-videos.sh - Training Video Production Script
# Usage:
#   training-videos.sh --json --full
#   training-videos.sh --json --status
#   training-videos.sh --json --video <id> [--phase <phase>]
#   training-videos.sh --raw --<section>

MANIFEST_FILE="training-videos.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${HOME}/.claude/templates/training-videos.yaml"

# Custom status-to-action mapping (must be defined before sourcing output-framework.sh)
map_status_to_action() {
    case "$1" in
        success)         echo "display_summary" ;;
        partial_success) echo "investigate_failures" ;;
        error)           echo "fix_error" ;;
        *)               echo "display_summary" ;;
    esac
}

# shellcheck source=lib/yaml.sh
source "${SCRIPT_DIR}/lib/yaml.sh" || {
    echo "{\"status\":\"error\",\"message\":\"Failed to load yaml.sh\"}" >&2
    exit 1
}

# shellcheck source=lib/output-framework.sh
source "${SCRIPT_DIR}/lib/output-framework.sh" || {
    echo "{\"status\":\"error\",\"message\":\"Failed to load output-framework.sh\"}" >&2
    exit 1
}

OUTPUT_MODE="json"; SECTION=""; MODE=""; VIDEO_ID=""; PHASE=""
AUTO_CONFIRM=false; VOICE_OVERRIDE=""; RESOLUTION_OVERRIDE=""; FORCE_REGEN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --validate|--status|--audio|--video|--assembly|--add-new) SECTION="${1#--}"; shift ;;
        --video|--video-id) VIDEO_ID="$2"; MODE="specific"; shift 2 ;;
        --mode|-m) MODE="$2"; shift 2 ;;
        --phase) PHASE="$2"; shift 2 ;;
        --yes|-y) AUTO_CONFIRM=true; shift ;;
        --voice) VOICE_OVERRIDE="$2"; shift 2 ;;
        --resolution|--res) RESOLUTION_OVERRIDE="$2"; shift 2 ;;
        --force|-f) FORCE_REGEN=true; shift ;;
        --quiet|-q) shift ;;
        --verbose|-v) shift ;;
        *) echo "{\"status\":\"error\",\"message\":\"Unknown option: $1\"}"; exit 1 ;;
    esac
done

[[ -z "$SECTION" ]] && SECTION="full"

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_response() {
    local status="$1" section="$2" message="$3"; shift 3
    local next_action
    next_action=$(map_status_to_action "$status")
    local json="{\"status\":\"${status}\",\"section\":\"${section}\",\"message\":\"${message}\",\"next_action\":\"${next_action}\",\"timestamp\":\"$(timestamp)\""
    while [[ $# -gt 0 ]]; do json="${json},\"$1\":\"$2\""; shift 2; done
    log_json "${json}}"
}

json_array() {
    local items=("$@"); local json="["; local first=true
    for item in "${items[@]}"; do [[ "$first" == true ]] && first=false || json="${json},"; json="${json}\"${item}\""; done
    echo "${json}]"
}

error_exit() {
    local message="$1" section="${2:-general}"
    [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "$section" "$message" || echo "Error: $message" >&2
    exit 1
}

section_validate() {
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "=== Validation ===" >&2
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "validate" "No training-videos.yaml found" "suggestion" "Copy from ${TEMPLATE_FILE}" || echo "Error: No training-videos.yaml" >&2
        return 1
    fi
    local missing=()
    command -v edge-tts >/dev/null 2>&1 || command -v "$HOME/.local/bin/edge-tts" >/dev/null 2>&1 || missing+=("edge-tts")
    command -v ffmpeg >/dev/null 2>&1 || missing+=("ffmpeg")
    command -v ffprobe >/dev/null 2>&1 || missing+=("ffprobe")
    command -v npx >/dev/null 2>&1 || missing+=("npx")
    command -v yq >/dev/null 2>&1 || missing+=("yq")
    if [[ ${#missing[@]} -gt 0 ]]; then
        [[ "$OUTPUT_MODE" == "json" ]] && echo "{\"status\":\"error\",\"section\":\"validate\",\"next_action\":\"fix_error\",\"message\":\"Missing required tools\",\"missing_tools\":$(json_array "${missing[@]}")}" || echo "Missing: ${missing[*]}" >&2
        return 1
    fi
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "✓ Validation passed" >&2
    return 0
}

section_status() {
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "=== Status ===" >&2
    local video_count; video_count=$(yaml_get '.videos | length' "$MANIFEST_FILE")
    local needs_update=()
    for ((i=0; i<video_count; i++)); do
        local id; id=$(yaml_get ".videos[$i].id" "$MANIFEST_FILE")
        local version; version=$(yaml_get ".videos[$i].last_updated_version" "$MANIFEST_FILE")
        local date; date=$(yaml_get ".videos[$i].last_updated_date" "$MANIFEST_FILE")
        local patterns; patterns=$(yaml_get_array ".videos[$i].covers.files" "$MANIFEST_FILE")
        [[ -z "$patterns" || "$patterns" == "null" ]] && continue
        local baseline=""
        [[ -n "$version" && "$version" != "null" ]] && baseline=$(git rev-parse "v$version" 2>/dev/null || git log --all --grep="$version" --format="%H" -n 1 2>/dev/null || echo "")
        [[ -z "$baseline" && -n "$date" && "$date" != "null" ]] && baseline=$(git log --until="${date}T23:59:59" --format="%H" -n 1 2>/dev/null || echo "")
        [[ -z "$baseline" ]] && { needs_update+=("$id"); continue; }
        local changed=false
        while IFS= read -r pattern; do
            git diff --name-only "$baseline"..HEAD -- "$pattern" 2>/dev/null | grep -q . && { changed=true; break; }
        done <<< "$patterns"
        [[ "$changed" == true ]] && needs_update+=("$id")
    done
    local count=${#needs_update[@]}
    [[ "$OUTPUT_MODE" == "json" ]] && echo "{\"status\":\"success\",\"section\":\"status\",\"next_action\":\"display_summary\",\"message\":\"$count video(s) need updating\",\"needs_update\":$(json_array "${needs_update[@]}"),\"total\":$video_count,\"timestamp\":\"$(timestamp)\"}" || { echo "Summary: $count need updating"; for id in "${needs_update[@]}"; do echo "  - $id"; done; }
}

section_audio() {
    local video_idx="$1" id="$2"
    local videos_root; videos_root=$(yaml_get_default '.constraints.videos_root' './videos' "$MANIFEST_FILE")
    local video_dir="${videos_root}/${id}"
    local voiceover_script="${video_dir}/$(yaml_get ".videos[$video_idx].paths.voiceover_script" "$MANIFEST_FILE")"
    local audio_dir="${video_dir}/audio"
    [[ ! -f "$voiceover_script" ]] && { [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "audio" "Voiceover script not found" "video_id" "$id" "expected_path" "$voiceover_script" || echo "Error: $voiceover_script not found" >&2; return 1; }
    local voice; voice=$(yaml_get '.constraints.voice' "$MANIFEST_FILE")
    local rate; rate=$(yaml_get '.constraints.rate' "$MANIFEST_FILE")
    [[ -n "$VOICE_OVERRIDE" ]] && voice="$VOICE_OVERRIDE"
    mkdir -p "$audio_dir"; chmod +x "$voiceover_script"
    export EDGE_TTS_VOICE="$voice" EDGE_TTS_RATE="$rate" OUTPUT_DIR="$audio_dir"
    [[ "$OUTPUT_MODE" == "raw" ]] && bash "$voiceover_script" || bash "$voiceover_script" >/dev/null 2>&1
    [[ $? -ne 0 ]] && { [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "audio" "Audio generation failed" "video_id" "$id"; return 1; }
    local playwright_test="${video_dir}/$(yaml_get ".videos[$video_idx].paths.playwright_test" "$MANIFEST_FILE")"
    if [[ -f "$playwright_test" ]]; then
        local durations_js="const AUDIO = {\n"
        for audio_file in "$audio_dir"/*.mp3; do
            [[ ! -f "$audio_file" ]] && continue
            local filename; filename=$(basename "$audio_file" .mp3)
            [[ "$filename" == "full-voiceover" || "$filename" == "concat-list" ]] && continue
            local duration; duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$audio_file" 2>/dev/null || echo "0")
            [[ -n "$duration" && "$duration" != "0" ]] && { local ms; ms=$(echo "$duration * 1000" | bc 2>/dev/null | cut -d. -f1); local js_var="s${filename//-/_}"; durations_js+="  ${js_var}: ${ms},\n"; }
        done
        durations_js+="};"
        grep -q "const AUDIO = {" "$playwright_test" && perl -i -0pe "s/const AUDIO = \{[^}]*\};/$(echo -e "$durations_js" | sed 's/[\/&]/\\&/g')/s" "$playwright_test"
    fi
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "✓ Audio generated" >&2
    return 0
}

section_video() {
    local video_idx="$1" id="$2"
    local videos_root; videos_root=$(yaml_get_default '.constraints.videos_root' './videos' "$MANIFEST_FILE")
    local video_dir="${videos_root}/${id}"
    local playwright_test="${video_dir}/$(yaml_get ".videos[$video_idx].paths.playwright_test" "$MANIFEST_FILE")"
    [[ ! -f "$playwright_test" ]] && { [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "video" "Playwright test not found" "video_id" "$id"; return 1; }
    [[ "$OUTPUT_MODE" == "raw" ]] && npx playwright test "$playwright_test" --headed --project=chromium || npx playwright test "$playwright_test" --headed --project=chromium >/dev/null 2>&1
    [[ $? -ne 0 ]] && { [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "video" "Video recording failed" "video_id" "$id"; return 1; }
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "✓ Video recorded" >&2
}

section_assembly() {
    local video_idx="$1" id="$2"
    local videos_root; videos_root=$(yaml_get_default '.constraints.videos_root' './videos' "$MANIFEST_FILE")
    local video_dir="${videos_root}/${id}"; local audio_dir="${video_dir}/audio"; local output_dir="${video_dir}/output"
    local video_file; video_file=$(find test-results -name "video.webm" -type f 2>/dev/null | head -1 || echo "")
    [[ -f "$video_file" ]] && { mkdir -p "${video_dir}/video"; cp "$video_file" "${video_dir}/video/recording.webm"; }
    local audio_file="${audio_dir}/full-voiceover.mp3"
    [[ ! -f "${video_file:-}" || ! -f "$audio_file" ]] && { [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "assembly" "Missing video or audio file" "video_id" "$id"; return 1; }
    local crf; crf=$(yaml_get_default '.constraints.ffmpeg.crf' '18' "$MANIFEST_FILE")
    local preset; preset=$(yaml_get_default '.constraints.ffmpeg.preset' 'slow' "$MANIFEST_FILE")
    local video_br; video_br=$(yaml_get_default '.constraints.video_bitrate' '8M' "$MANIFEST_FILE")
    local audio_br; audio_br=$(yaml_get_default '.constraints.audio_bitrate' '192k' "$MANIFEST_FILE")
    mkdir -p "$output_dir"
    local output_video; output_video=$(yaml_get ".videos[$video_idx].paths.output_video" "$MANIFEST_FILE")
    local final="${video_dir}/${output_video}"
    [[ "$OUTPUT_MODE" == "raw" ]] && ffmpeg -y -i "$video_file" -i "$audio_file" -c:v libx264 -crf "$crf" -preset "$preset" -b:v "$video_br" -c:a aac -b:a "$audio_br" -shortest "$final" || ffmpeg -y -i "$video_file" -i "$audio_file" -c:v libx264 -crf "$crf" -preset "$preset" -b:v "$video_br" -c:a aac -b:a "$audio_br" -shortest "$final" >/dev/null 2>&1
    [[ $? -ne 0 ]] && { [[ "$OUTPUT_MODE" == "json" ]] && json_response "error" "assembly" "FFmpeg failed" "video_id" "$id"; return 1; }
    local dur; dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$final" 2>/dev/null || echo "0")
    local dur_fmt; dur_fmt=$(printf '%d:%02d' $((${dur%.*}/60)) $((${dur%.*}%60)))
    local ver; ver=$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local date; date=$(date +%Y-%m-%d)
    yq eval -i ".videos[$video_idx].duration = \"$dur_fmt\"" "$MANIFEST_FILE"
    yq eval -i ".videos[$video_idx].last_updated_version = \"$ver\"" "$MANIFEST_FILE"
    yq eval -i ".videos[$video_idx].last_updated_date = \"$date\"" "$MANIFEST_FILE"
    yq eval -i ".videos[$video_idx].status = \"completed\"" "$MANIFEST_FILE"
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "✓ Assembly complete: $final ($dur_fmt)" >&2
}

main() {
    case "$SECTION" in
        validate)
            section_validate || exit 1
            [[ "$OUTPUT_MODE" == "json" ]] && json_response "success" "validate" "Environment validated"
            ;;
        status)
            section_validate || exit 1
            section_status || exit 1
            ;;
        full)
            section_validate || exit 1
            local video_count; video_count=$(yaml_get '.videos | length' "$MANIFEST_FILE")
            local videos_to_process=()
            if [[ -n "$VIDEO_ID" ]]; then
                for ((i=0; i<video_count; i++)); do
                    local id; id=$(yaml_get ".videos[$i].id" "$MANIFEST_FILE")
                    [[ "$id" == "$VIDEO_ID" ]] && { videos_to_process+=("$i:$id"); break; }
                done
                [[ ${#videos_to_process[@]} -eq 0 ]] && error_exit "Video '$VIDEO_ID' not found" "full"
            else
                for ((i=0; i<video_count; i++)); do
                    local id; id=$(yaml_get ".videos[$i].id" "$MANIFEST_FILE")
                    videos_to_process+=("$i:$id")
                done
            fi
            local processed=(); local failed=()
            for video_spec in "${videos_to_process[@]}"; do
                IFS=':' read -r idx id <<< "$video_spec"
                { [[ -z "$PHASE" || "$PHASE" == "audio" ]] && section_audio "$idx" "$id"; } || { failed+=("$id"); continue; }
                { [[ -z "$PHASE" || "$PHASE" == "video" ]] && section_video "$idx" "$id"; } || { failed+=("$id"); continue; }
                { [[ -z "$PHASE" || "$PHASE" == "assembly" ]] && section_assembly "$idx" "$id"; } || { failed+=("$id"); continue; }
                processed+=("$id")
            done
            local status="success"; [[ ${#failed[@]} -gt 0 ]] && status="partial_success"
            local next_action; [[ "$status" == "success" ]] && next_action="display_summary" || next_action="investigate_failures"
            [[ "$OUTPUT_MODE" == "json" ]] && echo "{\"status\":\"$status\",\"section\":\"full\",\"next_action\":\"$next_action\",\"message\":\"Processed ${#processed[@]} video(s)\",\"processed\":$(json_array "${processed[@]}"),\"failed\":$(json_array "${failed[@]}"),\"timestamp\":\"$(timestamp)\"}" || { echo "Processed: ${#processed[@]}"; echo "Failed: ${#failed[@]}"; }
            ;;
        audio|video|assembly)
            section_validate || exit 1
            [[ -z "$VIDEO_ID" ]] && error_exit "Video ID required for phase-specific execution" "$SECTION"
            local video_count; video_count=$(yaml_get '.videos | length' "$MANIFEST_FILE")
            local found=false
            for ((i=0; i<video_count; i++)); do
                local id; id=$(yaml_get ".videos[$i].id" "$MANIFEST_FILE")
                [[ "$id" == "$VIDEO_ID" ]] && { "section_${SECTION}" "$i" "$id" || exit 1; found=true; break; }
            done
            [[ "$found" == false ]] && error_exit "Video '$VIDEO_ID' not found" "$SECTION"
            [[ "$OUTPUT_MODE" == "json" ]] && json_response "success" "$SECTION" "Phase completed" "video_id" "$VIDEO_ID"
            ;;
        *) error_exit "Unknown section: $SECTION" ;;
    esac
}

main
