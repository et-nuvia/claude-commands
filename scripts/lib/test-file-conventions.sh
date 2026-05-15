#!/usr/bin/env bash
# Test-file conventions library
#
# Provides four pure functions used by scripts/tdd-precheck.sh to decide
# whether a new file requires a corresponding test, where that test would
# live, and how to recognise a sentinel-comment bypass.
#
#   is_excluded_path <path>     → 0 if path is excluded from TDD check
#   detect_language <path>      → emits python|javascript|typescript|bash|go|rust|unknown
#   get_test_paths <path>       → emits newline-separated candidate test paths
#   get_comment_prefix <path>   → emits language-appropriate single-line comment prefix
#
# Designed to be sourced. No `set -e` here on purpose — the caller controls
# its own error handling (tdd-precheck.sh fail-opens at every step).
#
# PROJECT.yaml override: get_test_paths reads
#   task_management.test_conventions.<language>
# from PROJECT.yaml in the current working directory if present. Each entry
# is a path template; `{name}` is replaced with the source file basename
# without extension, `{dir}` with the source file directory.

# ─── is_excluded_path ─────────────────────────────────────────────────────────
# Returns 0 if the given path is excluded from TDD enforcement (test files,
# docs, configs, schemas, fixtures, well-known literals). Returns 1 otherwise.
is_excluded_path() {
    local path="$1"
    local basename="${path##*/}"

    # Directory-based exclusions (any segment matches)
    case "/$path/" in
        */tests/*|*/test/*|*/__tests__/*) return 0 ;;
        */docs/*) return 0 ;;
        */schemas/*) return 0 ;;
        */templates/*) return 0 ;;
        */fixtures/*) return 0 ;;
        */seeds/*) return 0 ;;
    esac

    # Test-file naming patterns
    case "$basename" in
        *_test.*|*.test.*|*.spec.*) return 0 ;;
    esac

    # Docs / text
    case "$basename" in
        *.md|*.txt|*.rst) return 0 ;;
    esac

    # Config formats
    case "$basename" in
        *.json|*.yaml|*.yml|*.toml|*.ini|*.cfg) return 0 ;;
    esac

    # Well-known literal filenames
    case "$basename" in
        .gitignore|.dockerignore|.editorconfig|LICENSE|Makefile|Dockerfile) return 0 ;;
    esac

    return 1
}

# ─── detect_language ──────────────────────────────────────────────────────────
# Emits one of: python, javascript, typescript, bash, go, rust, unknown
detect_language() {
    local path="$1"
    case "$path" in
        *.py)         echo "python" ;;
        *.tsx|*.ts)   echo "typescript" ;;
        *.jsx|*.js)   echo "javascript" ;;
        *.bash|*.sh)  echo "bash" ;;
        *.go)         echo "go" ;;
        *.rs)         echo "rust" ;;
        *)            echo "unknown" ;;
    esac
}

# ─── get_test_paths ───────────────────────────────────────────────────────────
# Emits newline-separated candidate test paths for the given source file.
# Built-in defaults per language; PROJECT.yaml override (if present) wins.
get_test_paths() {
    local path="$1"
    local lang basename name dir

    lang=$(detect_language "$path")
    [[ "$lang" == "unknown" ]] && return 0

    basename="${path##*/}"
    name="${basename%.*}"
    dir="${path%/*}"
    # If path has no directory component, %/* yields the path itself; normalise to "."
    [[ "$dir" == "$path" ]] && dir="."

    # PROJECT.yaml override has priority
    if [[ -f PROJECT.yaml ]] && command -v yq >/dev/null 2>&1; then
        local override
        override=$(yq -r ".task_management.test_conventions.${lang}[]?" PROJECT.yaml 2>/dev/null || true)
        if [[ -n "$override" ]]; then
            # Substitute {name} and {dir} placeholders, emit one per line
            while IFS= read -r tmpl; do
                [[ -z "$tmpl" ]] && continue
                tmpl="${tmpl//\{name\}/$name}"
                tmpl="${tmpl//\{dir\}/$dir}"
                echo "$tmpl"
            done <<< "$override"
            return 0
        fi
    fi

    # Built-in defaults
    case "$lang" in
        python)
            echo "tests/test_${name}.py"
            echo "test/test_${name}.py"
            echo "${dir}/test_${name}.py"
            ;;
        typescript)
            local ext="${basename##*.}"  # ts or tsx
            echo "${dir}/${name}.test.${ext}"
            echo "${dir}/${name}.spec.${ext}"
            echo "${dir}/__tests__/${name}.test.${ext}"
            ;;
        javascript)
            local ext="${basename##*.}"  # js or jsx
            echo "${dir}/${name}.test.${ext}"
            echo "${dir}/${name}.spec.${ext}"
            echo "${dir}/__tests__/${name}.test.${ext}"
            ;;
        bash)
            echo "tests/test_${name}.bats"
            echo "tests/${name}.bats"
            ;;
        go)
            echo "${dir}/${name}_test.go"
            ;;
        rust)
            echo "${dir}/${name}_test.rs"
            echo "tests/${name}.rs"
            ;;
    esac
}

# ─── get_comment_prefix ───────────────────────────────────────────────────────
# Emits the language-appropriate single-line comment prefix used for the
# `<prefix> tdd-bypass: <reason>` sentinel detection. Defaults to `#`.
get_comment_prefix() {
    local path="$1"
    case "$path" in
        *.py|*.sh|*.bash|*.yaml|*.yml|*.toml|*.rb|*.pl|*.r) echo "#" ;;
        *.js|*.jsx|*.ts|*.tsx|*.go|*.rs|*.c|*.cpp|*.h|*.java|*.cs|*.swift|*.kt) echo "//" ;;
        *.html|*.htm|*.xml|*.svg|*.md) echo "<!--" ;;
        *.sql|*.lua|*.hs|*.elm) echo "--" ;;
        *) echo "#" ;;
    esac
}
