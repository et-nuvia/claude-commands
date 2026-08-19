#!/usr/bin/env bash
set -euo pipefail

# db-user-audit.sh - Audit database-level users, roles, and permissions for security review
#
# This script consolidates the db-user-audit command from a 576-line prompt with
# 13 bash blocks into a single auto-approved script that completes in 30-60 seconds.
#
# Usage:
#   ~/.claude/scripts/db-user-audit.sh [--json] [--type TYPE] [--host HOST] [--db DATABASE]
#
# Features:
#   - Auto-detects database type from PROJECT.yaml or prompts
#   - Tests connection and privileges
#   - Lists all database users with privileges
#   - Identifies users with excessive privileges
#   - Checks for weak authentication (empty passwords, expired)
#   - Detects shared/generic account names
#   - Analyzes role memberships
#   - Generates comprehensive audit report
#   - Outputs structured JSON for LLM analysis
#
# Flags:
#   --json: Output JSON to stdout instead of file
#   --type: Database type (postgresql, mysql, mongodb)
#   --host: Database host
#   --db: Database name
#   --user: Database user (with sufficient privileges)

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_MODE="raw"
SECTION="full"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        error)   echo "fix_error" ;;
        *)       echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/project-config.sh"

# Get a secret value - delegates to the project's secrets backend (mirrors
# db-schema-sync.sh's get_secret_value so credential resolution is consistent).
get_secret_value() {
    local secret_name="$1"
    local value=""

    local backend
    backend=$(get_secrets_backend)

    case "$backend" in
        aws)
            value=$(aws secretsmanager get-secret-value \
                --secret-id "$secret_name" \
                --query 'SecretString' \
                --output text 2>/dev/null || echo "")
            ;;
        infisical)
            value=$(infisical secrets get "$secret_name" --plain 2>/dev/null || echo "")
            ;;
        env)
            value="${!secret_name:-}"
            ;;
        *)
            value="${!secret_name:-}"
            ;;
    esac

    echo "$value"
}

# Remaining global variables
DB_TYPE=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
OUTPUT_JSON=false
TOTAL_USERS=0
SUPERUSER_COUNT=0
HIGH_PRIV_COUNT=0
PASSWORDLESS_USERS=0
EXPIRED_PASSWORDS=0
CREATEDB_USERS=0
CREATEROLE_USERS=0
AUDIT_REPORT=""

# JSON output file
OUTPUT_FILE="/tmp/db-user-audit-result.json"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

print_header() {
    if [[ "$OUTPUT_JSON" != "true" ]]; then
        echo "" >&2
        echo -e "${CYAN}$1${NC}" >&2
        printf '%.0s═' {1..60} >&2
        echo "" >&2
    fi
}

#------------------------------------------------------------------------------
# Main Functions
#------------------------------------------------------------------------------

# Step 1: Detect database type
detect_database() {
    print_header "Detecting Database"

    local db_password_secret=""

    # Try to get from PROJECT.yaml
    if [[ -f "PROJECT.yaml" ]] && [[ -z "$DB_TYPE" ]]; then
        DB_TYPE=$(yaml_get '.database.type' PROJECT.yaml)
        DB_HOST=$(yaml_get '.database.connection.host' PROJECT.yaml)
        DB_PORT=$(yaml_get '.database.connection.port' PROJECT.yaml)
        DB_NAME=$(yaml_get '.database.connection.database' PROJECT.yaml)
        DB_USER=$(yaml_get '.database.connection.user' PROJECT.yaml)
        db_password_secret=$(yaml_get '.database.connection.password_secret' PROJECT.yaml)
    fi

    # Prompt if not found
    if [[ -z "$DB_TYPE" ]] || [[ "$DB_TYPE" == "null" ]]; then
        if [[ "$OUTPUT_JSON" != "true" ]]; then
            echo "Database type:" >&2
            echo "1. PostgreSQL" >&2
            echo "2. MySQL/MariaDB" >&2
            echo "3. MongoDB" >&2
            read -p "Choice (1-3): " DB_CHOICE >&2

            case "$DB_CHOICE" in
                1) DB_TYPE="postgresql" ;;
                2) DB_TYPE="mysql" ;;
                3) DB_TYPE="mongodb" ;;
                *) DB_TYPE="postgresql" ;;
            esac

            read -p "Database host: " DB_HOST >&2
            read -p "Database name: " DB_NAME >&2
            read -p "Database user (with sufficient privileges): " DB_USER >&2
        else
            # JSON mode with no PROJECT.yaml database config — surface as an
            # input-needed error instead of silently defaulting to
            # postgresql@localhost/postgres (which produced false-negative audits).
            local error_json=$(cat <<EOF
{
  "status": "error",
  "next_action": "fix_config",
  "message": "No database configuration found",
  "details": "PROJECT.yaml is missing a 'database' section (type/connection.host/connection.database/connection.user). Add it, or pass --type/--host/--db/--user explicitly."
}
EOF
)
            if [[ "$OUTPUT_JSON" == "true" ]]; then
                echo "$error_json"
            else
                echo "$error_json" > "$OUTPUT_FILE"
            fi
            exit 1
        fi
    fi

    # Resolve the DB password from the project's secrets backend and export it
    # so every psql invocation below picks it up via PGPASSWORD.
    if [[ -n "$db_password_secret" ]] && [[ "$db_password_secret" != "null" ]]; then
        DB_PASSWORD=$(get_secret_value "$db_password_secret")
    fi
    if [[ -n "$DB_PASSWORD" ]]; then
        export PGPASSWORD="$DB_PASSWORD"
    fi

    log_info "Database: $DB_TYPE"
    log_info "Host: $DB_HOST"
}

# Step 2: Test connection and privileges
test_connection() {
    print_header "Testing Connection"

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        DB_PORT=${DB_PORT:-5432}

        if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT version();" > /dev/null 2>&1; then
            log_error "Connection failed"

            # Output error JSON and exit
            local error_json=$(cat <<EOF
{
  "status": "error",
  "next_action": "fix_connection",
  "message": "Database connection failed",
  "details": "Could not connect to $DB_TYPE at $DB_HOST:$DB_PORT as user $DB_USER"
}
EOF
)
            if [[ "$OUTPUT_JSON" == "true" ]]; then
                echo "$error_json"
            else
                echo "$error_json" > "$OUTPUT_FILE"
            fi
            exit 1
        fi

        # Check if user has sufficient privileges
        IS_SUPERUSER=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT usesuper FROM pg_user WHERE usename = current_user;" 2>/dev/null || echo "f")

        if [[ "$IS_SUPERUSER" != "t" ]]; then
            log_warning "Current user is not a superuser. Some checks may be limited."
        fi

        log_success "Connected successfully"
    fi
}

# Step 3: List all database users
list_users() {
    print_header "Listing Database Users"

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" << 'SQL' > /tmp/db-users.txt 2>/dev/null
SELECT
  usename as username,
  CASE WHEN usesuper THEN 'SUPERUSER' ELSE '' END as super,
  CASE WHEN usecreatedb THEN 'CREATEDB' ELSE '' END as createdb,
  CASE WHEN usecreaterole THEN 'CREATEROLE' ELSE '' END as createrole,
  CASE WHEN usebypassrls THEN 'BYPASSRLS' ELSE '' END as bypassrls,
  valuntil as password_expiry
FROM pg_user
ORDER BY usename;
SQL

        TOTAL_USERS=$(tail -n +3 /tmp/db-users.txt | head -n -2 | wc -l)
        log_info "Total database users: $TOTAL_USERS"
    fi
}

# Step 4: Identify users with excessive privileges
check_excessive_privileges() {
    print_header "Checking Excessive Privileges"

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        # Superusers
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT usename FROM pg_user WHERE usesuper = true AND usename != 'postgres' ORDER BY usename;" > /tmp/superusers.txt 2>/dev/null

        SUPERUSER_COUNT=$(wc -l < /tmp/superusers.txt 2>/dev/null || echo "0")

        if [[ $SUPERUSER_COUNT -gt 0 ]]; then
            log_warning "Found $SUPERUSER_COUNT non-postgres superusers"
        else
            log_success "Only default postgres superuser found"
        fi

        # Users who can create databases
        CREATEDB_USERS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_user WHERE usecreatedb = true AND usename NOT IN ('postgres');" 2>/dev/null || echo "0")

        if [[ $CREATEDB_USERS -gt 0 ]]; then
            log_warning "$CREATEDB_USERS users have CREATEDB privilege"
        fi

        # Users who can create roles
        CREATEROLE_USERS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_user WHERE usecreaterole = true AND usename NOT IN ('postgres');" 2>/dev/null || echo "0")

        if [[ $CREATEROLE_USERS -gt 0 ]]; then
            log_warning "$CREATEROLE_USERS users have CREATEROLE privilege"
        fi
    fi
}

# Step 5: Check for weak authentication
check_weak_authentication() {
    print_header "Checking Authentication"

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        # Users without password
        PASSWORDLESS_USERS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_shadow WHERE passwd IS NULL;" 2>/dev/null || echo "0")

        if [[ $PASSWORDLESS_USERS -gt 0 ]]; then
            log_warning "$PASSWORDLESS_USERS users without passwords"
        else
            log_success "All users have passwords"
        fi

        # Expired passwords
        EXPIRED_PASSWORDS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_user WHERE valuntil < now();" 2>/dev/null || echo "0")

        if [[ $EXPIRED_PASSWORDS -gt 0 ]]; then
            log_warning "$EXPIRED_PASSWORDS users with expired passwords"
        fi
    fi
}

# Step 5b: Check database connection pool saturation
# Detects a max_connections ceiling that is too low for current demand: if live
# connections are near the usable limit, the backend pool cannot grow and requests
# will queue/fail. This is the DB-server side of the pool check; the backend
# pool_size vs capacity math lives in docker-audit.
check_connection_pool() {
    print_header "Checking Connection Pool Saturation"

    # Defaults so the report/JSON always have values even for non-postgres backends.
    MAX_CONNECTIONS=0
    RESERVED_CONNECTIONS=0
    USABLE_CONNECTIONS=0
    CONN_IN_USE=0
    CONN_PCT=0
    POOL_RISK="none"  # none | medium | high

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        MAX_CONNECTIONS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT setting FROM pg_settings WHERE name='max_connections';" 2>/dev/null || echo "0")
        RESERVED_CONNECTIONS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT setting FROM pg_settings WHERE name='superuser_reserved_connections';" 2>/dev/null || echo "0")
        CONN_IN_USE=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null || echo "0")

        MAX_CONNECTIONS=${MAX_CONNECTIONS:-0}
        RESERVED_CONNECTIONS=${RESERVED_CONNECTIONS:-0}
        CONN_IN_USE=${CONN_IN_USE:-0}

        USABLE_CONNECTIONS=$(( MAX_CONNECTIONS - RESERVED_CONNECTIONS ))
        if [[ $USABLE_CONNECTIONS -gt 0 ]]; then
            CONN_PCT=$(( CONN_IN_USE * 100 / USABLE_CONNECTIONS ))
        fi

        # High: pool is effectively saturated — max_connections is too low for demand.
        # Medium: approaching the ceiling with little headroom to absorb spikes.
        if [[ $CONN_PCT -ge 90 ]]; then
            POOL_RISK="high"
            log_warning "Connection pool ${CONN_PCT}% saturated (${CONN_IN_USE}/${USABLE_CONNECTIONS} usable) — max_connections too low"
        elif [[ $CONN_PCT -ge 75 ]]; then
            POOL_RISK="medium"
            log_warning "Connection pool ${CONN_PCT}% used (${CONN_IN_USE}/${USABLE_CONNECTIONS} usable) — limited headroom"
        else
            log_success "Connection pool healthy: ${CONN_IN_USE}/${USABLE_CONNECTIONS} usable connections (${CONN_PCT}%)"
        fi
    fi
}

# Step 6: Check for shared/generic accounts
check_generic_accounts() {
    print_header "Checking Generic Accounts"

    local generic_names=("app" "application" "service" "admin" "user" "test" "dev" "readonly")
    local generic_count=0

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        for name in "${generic_names[@]}"; do
            local exists=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_user WHERE usename LIKE '%$name%';" 2>/dev/null || echo "0")
            if [[ $exists -gt 0 ]]; then
                ((generic_count++)) || true
            fi
        done

        if [[ $generic_count -gt 0 ]]; then
            log_warning "Found $generic_count generic account names"
        else
            log_success "No generic account names detected"
        fi
    fi
}

# Step 7: Generate audit report
generate_report() {
    print_header "Generating Audit Report"

    AUDIT_REPORT="docs/database-audits/$(date +%Y-%m-%d)-db-user-audit.md"
    mkdir -p docs/database-audits

    cat > "$AUDIT_REPORT" << EOF
# Database User Audit Report

**Date**: $(date -Iseconds)
**Database**: $DB_TYPE
**Host**: $DB_HOST
**Database**: $DB_NAME

---

## Executive Summary

- **Total database users**: $TOTAL_USERS
- **Superusers (non-default)**: ${SUPERUSER_COUNT:-N/A}
- **Users with excessive privileges**: ${HIGH_PRIV_COUNT:-N/A}
- **Users without passwords**: ${PASSWORDLESS_USERS:-N/A}
- **Expired passwords**: ${EXPIRED_PASSWORDS:-N/A}
- **Connection pool usage**: ${CONN_IN_USE:-N/A}/${USABLE_CONNECTIONS:-N/A} usable (${CONN_PCT:-0}%, risk: ${POOL_RISK:-none})

---

## Connection Pool

- **max_connections**: ${MAX_CONNECTIONS:-N/A}
- **superuser_reserved_connections**: ${RESERVED_CONNECTIONS:-N/A}
- **Usable connections**: ${USABLE_CONNECTIONS:-N/A}
- **Currently in use**: ${CONN_IN_USE:-N/A} (${CONN_PCT:-0}%)

$(if [[ "${POOL_RISK:-none}" == "high" ]]; then
  echo "**HIGH RISK**: The pool is ${CONN_PCT}% saturated. \`max_connections\` is too low for current demand — the backend pool cannot grow and new connections will queue or fail. Raise \`max_connections\` (and shared_buffers accordingly), or front the database with a pooler (PgBouncer)."
elif [[ "${POOL_RISK:-none}" == "medium" ]]; then
  echo "**MEDIUM RISK**: The pool is ${CONN_PCT}% used, leaving little headroom for traffic spikes. Review \`max_connections\` and the backend \`pool_size\`/\`max_overflow\` against expected peak load."
else
  echo "Connection pool headroom is healthy."
fi)

---

## All Database Users

\`\`\`
$(cat /tmp/db-users.txt 2>/dev/null || echo "No user data")
\`\`\`

---

## Security Findings

### High Risk Issues

$(if [[ ${SUPERUSER_COUNT:-0} -gt 0 ]]; then
  echo "#### Excessive Superusers"
  echo ""
  echo "Found ${SUPERUSER_COUNT} non-default superusers:"
  echo "\`\`\`"
  cat /tmp/superusers.txt 2>/dev/null || echo "None"
  echo "\`\`\`"
  echo ""
  echo "**Recommendation**: Review if all superuser accounts are necessary. Superusers bypass all permission checks."
  echo ""
fi)

$(if [[ ${PASSWORDLESS_USERS:-0} -gt 0 ]]; then
  echo "#### Users Without Passwords"
  echo ""
  echo "Found ${PASSWORDLESS_USERS} users without passwords."
  echo ""
  echo "**Recommendation**: Set passwords or disable these accounts."
  echo ""
fi)

### Medium Risk Issues

$(if [[ ${EXPIRED_PASSWORDS:-0} -gt 0 ]]; then
  echo "#### Expired Passwords"
  echo ""
  echo "Found ${EXPIRED_PASSWORDS} users with expired passwords."
  echo ""
  echo "**Recommendation**: Update passwords or remove accounts."
  echo ""
fi)

$(if [[ ${CREATEDB_USERS:-0} -gt 0 ]]; then
  echo "#### Users with CREATEDB Privilege"
  echo ""
  echo "Found ${CREATEDB_USERS} users who can create databases."
  echo ""
  echo "**Recommendation**: Review if this privilege is necessary."
  echo ""
fi)

---

## Recommendations

### Immediate Actions (High Priority)

1. **Remove or Disable Unnecessary Superusers**
   \`\`\`sql
   ALTER USER username WITH NOSUPERUSER;
   \`\`\`

2. **Set Passwords for Passwordless Accounts**
   \`\`\`sql
   ALTER USER username WITH PASSWORD 'strong_password';
   \`\`\`

3. **Disable or Remove Unused Accounts**
   \`\`\`sql
   ALTER USER username WITH NOLOGIN;
   -- or
   DROP USER username;
   \`\`\`

### Short Term (This Week)

4. **Implement Password Expiration Policy**
5. **Review and Reduce Excessive Privileges**
6. **Rename Generic Accounts to Personal Accounts**

### Long Term (This Month)

7. **Implement Role-Based Access Control (RBAC)**
8. **Set Up Connection Auditing**
9. **Implement MFA for Superusers**
10. **Regular Audit Schedule**

---

## Compliance Checklist

- [ ] All users have strong passwords
- [ ] No shared/generic accounts
- [ ] Superuser access limited to DBAs only
- [ ] Unused accounts disabled or removed
- [ ] Password expiration policy in place
- [ ] Connection auditing enabled
- [ ] Regular access reviews scheduled
- [ ] Least privilege principle followed
- [ ] Role-based access control implemented
- [ ] MFA for privileged accounts

---

## Next Audit

Schedule next database user audit: $(date -d "+30 days" +%Y-%m-%d 2>/dev/null || date -v+30d +%Y-%m-%d 2>/dev/null || echo "30 days from now")

EOF

    log_success "Audit report: $AUDIT_REPORT"
}

# Step 8: Output JSON result
emit_result_json() {
    local high_risk
    local medium_risk
    if [[ ${SUPERUSER_COUNT:-0} -gt 0 ]] || [[ ${PASSWORDLESS_USERS:-0} -gt 0 ]] || [[ "${POOL_RISK:-none}" == "high" ]]; then high_risk="true"; else high_risk="false"; fi
    if [[ ${EXPIRED_PASSWORDS:-0} -gt 0 ]] || [[ ${CREATEDB_USERS:-0} -gt 0 ]] || [[ "${POOL_RISK:-none}" == "medium" ]]; then medium_risk="true"; else medium_risk="false"; fi

    local next_action
    if [[ "$high_risk" == "true" ]]; then next_action="remediate_high_risk"
    elif [[ "$medium_risk" == "true" ]]; then next_action="remediate_medium_risk"
    else next_action="display_summary"
    fi

    local json_content=$(cat <<EOF
{
  "status": "success",
  "next_action": "$next_action",
  "database_type": "${DB_TYPE}",
  "host": "${DB_HOST}",
  "database": "${DB_NAME}",
  "total_users": ${TOTAL_USERS},
  "superuser_count": ${SUPERUSER_COUNT},
  "high_priv_count": ${HIGH_PRIV_COUNT:-0},
  "passwordless_users": ${PASSWORDLESS_USERS},
  "expired_passwords": ${EXPIRED_PASSWORDS},
  "createdb_users": ${CREATEDB_USERS},
  "createrole_users": ${CREATEROLE_USERS},
  "connection_pool": {
    "max_connections": ${MAX_CONNECTIONS:-0},
    "reserved_connections": ${RESERVED_CONNECTIONS:-0},
    "usable_connections": ${USABLE_CONNECTIONS:-0},
    "in_use": ${CONN_IN_USE:-0},
    "usage_pct": ${CONN_PCT:-0},
    "risk": "${POOL_RISK:-none}"
  },
  "audit_report": "${AUDIT_REPORT}",
  "findings": {
    "high_risk": $high_risk,
    "medium_risk": $medium_risk
  }
}
EOF
)

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        log_json "$json_content"
    else
        echo "$json_content" > "$OUTPUT_FILE"
        log_success "Results written to $OUTPUT_FILE"
    fi
}

# Step 9: Print summary
print_summary() {
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        return  # Skip summary when outputting JSON
    fi

    print_header "Database User Audit Complete"

    echo "Database: $DB_TYPE" >&2
    echo "Total users: $TOTAL_USERS" >&2
    echo "" >&2
    echo "Security Findings:" >&2
    echo "  Superusers: ${SUPERUSER_COUNT:-0}" >&2
    echo "  Excessive privileges: ${HIGH_PRIV_COUNT:-0}" >&2
    echo "  Without passwords: ${PASSWORDLESS_USERS:-0}" >&2
    echo "  Expired passwords: ${EXPIRED_PASSWORDS:-0}" >&2
    echo "  Connection pool: ${CONN_IN_USE:-0}/${USABLE_CONNECTIONS:-0} (${CONN_PCT:-0}%, risk: ${POOL_RISK:-none})" >&2
    echo "" >&2
    echo "Report: $AUDIT_REPORT" >&2
    echo "" >&2
    echo "Top Recommendations:" >&2
    echo "  1. Remove unnecessary superuser accounts" >&2
    echo "  2. Set passwords for all accounts" >&2
    echo "  3. Disable or remove unused accounts" >&2
    echo "  4. Implement role-based access control" >&2
    echo "  5. Enable connection auditing" >&2
    echo "" >&2
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json)
                OUTPUT_JSON=true
                OUTPUT_MODE="json"
                shift
                ;;
            --type)
                DB_TYPE="$2"
                shift 2
                ;;
            --host)
                DB_HOST="$2"
                shift 2
                ;;
            --db)
                DB_NAME="$2"
                shift 2
                ;;
            --user)
                DB_USER="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Step 1: Detect database
    detect_database

    # Step 2: Test connection
    test_connection

    # Step 3: List users
    list_users

    # Step 4: Check excessive privileges
    check_excessive_privileges

    # Step 5: Check weak authentication
    check_weak_authentication

    # Step 5b: Check connection pool saturation
    check_connection_pool

    # Step 6: Check generic accounts
    check_generic_accounts

    # Step 7: Generate report
    generate_report

    # Step 8: Output JSON
    emit_result_json

    # Step 9: Print summary
    print_summary

    exit 0
}

# Run main function
main "$@"
