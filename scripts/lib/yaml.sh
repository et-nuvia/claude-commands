#!/usr/bin/env bash
# yaml.sh - Cross-platform YAML helper that works with both Go yq and Python yq
#
# Usage:
#   source "$(dirname "$0")/lib/yaml.sh"
#   value=$(yaml_get '.path.to.key' file.yaml)
#   value=$(yaml_get '.path.to.key // "default"' file.yaml)
#
# Detects yq variant once, caches the result, adapts call syntax.
# Works on macOS (Go yq / brew) and Linux/WSL (Python yq / pip/apt).

# Cache detection result
_YQ_VARIANT=""

# Detect which yq is installed: "go" (Mike Farah's) or "python" (kislyuk's)
_detect_yq_variant() {
    if [[ -n "$_YQ_VARIANT" ]]; then
        return 0
    fi

    if ! command -v yq &>/dev/null; then
        echo "Error: yq is required but not installed" >&2
        echo "  macOS: brew install yq" >&2
        echo "  Linux: pip install yq  OR  snap install yq" >&2
        return 1
    fi

    # Go yq has --version that outputs "yq (https://github.com/mikefarah/yq/) version v4.x.x"
    # Python yq has --version that outputs "yq X.X.X" (or "yq 0.0.0" on some installs)
    local version_output
    version_output=$(yq --version 2>&1 || true)

    if [[ "$version_output" == *"mikefarah"* ]] || [[ "$version_output" == *"https://github.com"* ]]; then
        _YQ_VARIANT="go"
    elif [[ "$version_output" =~ ^yq\ [0-9] ]]; then
        # Could be either — test with a known operation
        # Python yq requires -r flag and uses jq filter syntax
        # Go yq v4 accepts bare filter syntax
        if echo '{"test": "value"}' | yq -r '.test' 2>/dev/null | grep -q "value"; then
            # Both can do this — try Go-specific syntax
            if echo 'test: value' | yq eval '.test' 2>/dev/null | grep -q "value"; then
                _YQ_VARIANT="go"
            else
                _YQ_VARIANT="python"
            fi
        else
            _YQ_VARIANT="go"
        fi
    else
        # Default to go if can't determine
        _YQ_VARIANT="go"
    fi

    export _YQ_VARIANT
}

# Get a value from a YAML file using jq-compatible filter syntax
# Usage: yaml_get '.path.to.key' file.yaml
#        yaml_get '.path.to.key // "default"' file.yaml
# Returns raw value (no quotes). Returns empty string on error.
yaml_get() {
    local filter="$1"
    local file="${2:-PROJECT.yaml}"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    _detect_yq_variant || return 1

    local result=""
    if [[ "$_YQ_VARIANT" == "python" ]]; then
        result=$(yq -r "$filter" "$file" 2>/dev/null || echo "")
    else
        # Go yq v4: use eval with the filter
        result=$(yq eval "$filter" "$file" 2>/dev/null || echo "")
    fi

    # Normalize "null" to empty
    if [[ "$result" == "null" ]]; then
        echo ""
    else
        echo "$result"
    fi
}

# Get a value with explicit default (convenience wrapper)
# Usage: yaml_get_default '.path.to.key' 'fallback' file.yaml
yaml_get_default() {
    local filter="$1"
    local default="$2"
    local file="${3:-PROJECT.yaml}"

    local result
    result=$(yaml_get "${filter} // \"${default}\"" "$file")
    if [[ -z "$result" ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}

# Get a YAML array as newline-separated values
# Usage: while IFS= read -r item; do echo "$item"; done < <(yaml_get_array '.path.to.list' file.yaml)
#        mapfile -t items < <(yaml_get_array '.path.to.list' file.yaml)
yaml_get_array() {
    local filter="$1"
    local file="${2:-PROJECT.yaml}"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    _detect_yq_variant || return 1

    local result=""
    if [[ "$_YQ_VARIANT" == "python" ]]; then
        result=$(yq -r "${filter}[]" "$file" 2>/dev/null || echo "")
    else
        # Go yq v4: use eval
        result=$(yq eval "${filter}[]" "$file" 2>/dev/null || echo "")
    fi

    # Filter out "null" lines
    if [[ -n "$result" && "$result" != "null" ]]; then
        echo "$result" | grep -v '^null$'
    fi
}
