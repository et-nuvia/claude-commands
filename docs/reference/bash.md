# Bash Best Practices

Guidelines for writing safe, maintainable shell scripts.

---

## Script Header

Always start scripts with proper safety settings:

```bash
#!/usr/bin/env bash

set -euo pipefail  # Exit on error, undefined var, pipe failure

# Script continues...
```

| Flag | Purpose |
|------|---------|
| `-e` | Exit immediately on error |
| `-u` | Treat unset variables as error |
| `-o pipefail` | Catch errors in pipes |

---

## Variables

- Use `${VAR}` syntax, not `$VAR`
- Quote variables to handle spaces
- Use uppercase for environment vars, lowercase for local

```bash
# Good
local_var="value"
GLOBAL_VAR="global"

echo "The value is: ${local_var}"

# Handle paths with spaces
file_path="/path/with spaces/file.txt"
cat "${file_path}"

# Bad
VAR=value
echo $VAR
cat $file_path  # Breaks with spaces
```

---

## Functions

- Use lowercase with underscores
- Declare local variables
- Return status codes, not strings

```bash
# Good
check_docker_running() {
    local container_name="${1}"

    if docker ps | grep -q "${container_name}"; then
        return 0  # Success
    else
        return 1  # Failure
    fi
}

# Usage
if check_docker_running "backend"; then
    echo "Backend is running"
fi

# Bad
CheckDocker() {
    container=$1  # Not local
    result=$(docker ps | grep $container)
    echo $result  # Don't echo for return values
}
```

---

## Error Handling

- Check command exit codes
- Provide helpful error messages
- Use trap for cleanup

```bash
cleanup() {
    echo "Cleaning up..."
    rm -f /tmp/temp_file
}

trap cleanup EXIT

run_migration() {
    if ! docker compose exec backend alembic upgrade head; then
        echo "ERROR: Migration failed" >&2
        exit 1
    fi
    echo "Migration successful"
}
```

---

## Conditionals

- Use `[[ ]]`, not `[ ]`
- Quote strings in comparisons
- Use meaningful operators

```bash
# Good
if [[ -f "${config_file}" ]]; then
    echo "Config exists"
fi

if [[ "${environment}" == "production" ]]; then
    echo "Running in production"
fi

if [[ -z "${optional_var:-}" ]]; then
    echo "Variable not set"
fi

# Bad - single bracket, unquoted
if [ -f $config_file ]; then
    echo "Config exists"
fi
```

### Common Test Operators

| Operator | Purpose |
|----------|---------|
| `-f` | File exists |
| `-d` | Directory exists |
| `-z` | String is empty |
| `-n` | String is not empty |
| `==` | String equality |
| `-eq` | Integer equality |

---

## Command Substitution

Use `$(command)`, not backticks:

```bash
# Good
current_time=$(date +%Y%m%d_%H%M%S)
echo "Timestamp: ${current_time}"

# Bad (deprecated)
current_time=`date +%Y%m%d_%H%M%S`
```

---

## Arrays

Use arrays for lists of items:

```bash
# Good
services=("backend" "frontend" "postgres" "redis")

for service in "${services[@]}"; do
    echo "Starting ${service}..."
    docker compose up -d "${service}"
done

# Get array length
echo "Total services: ${#services[@]}"

# Bad - string, not array
services="backend frontend postgres redis"

for service in $services; do  # Breaks with spaces in names
    docker compose up -d $service
done
```

---

## User Input

- Validate user input
- Provide clear prompts
- Handle empty input

```bash
prompt_user_confirmation() {
    local message="${1}"

    echo "${message}"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Usage
if prompt_user_confirmation "This will delete all data!"; then
    delete_data
else
    echo "Operation cancelled"
fi
```

---

## Logging and Output

- Use stderr for errors and diagnostics
- Use stdout for program output
- Color output for human readability

```bash
# Output functions
log_info() {
    echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_success() {
    echo "[OK] $*"
}

# With colors (when terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'  # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}
```

---

## Script Structure Pattern

```bash
#!/usr/bin/env bash

set -euo pipefail

# Constants
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Cleanup on exit
cleanup() {
    # Cleanup code here
    :
}
trap cleanup EXIT

# Display usage
usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <command>

Commands:
    start       Start services
    stop        Stop services
    status      Show status

Options:
    -h, --help  Show this help message
    -v          Verbose output
EOF
}

# Main function
main() {
    local verbose=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h|--help)
                usage
                exit 0
                ;;
            -v)
                verbose=true
                shift
                ;;
            start|stop|status)
                cmd="${1}"
                shift
                break
                ;;
            *)
                echo "Unknown option: ${1}" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    # Execute command
    case "${cmd:-}" in
        start)
            do_start
            ;;
        stop)
            do_stop
            ;;
        status)
            do_status
            ;;
        *)
            echo "No command specified" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
```

---

## Checklist

Before committing bash scripts:

- [ ] Script starts with `set -euo pipefail`
- [ ] All variables are quoted
- [ ] Local variables declared with `local`
- [ ] Error messages go to stderr
- [ ] Cleanup handled with trap
- [ ] Tested with `shellcheck`
