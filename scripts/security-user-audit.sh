#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# security-user-audit.sh - Audit application users stored in database
#
# This script audits application-level user accounts (not database users).
# Analyzes users, roles, permissions, and organizational access from application tables.
#
# Usage:
#   ~/.claude/scripts/security-user-audit.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --detect:    Detect database and schema
#   --discover:  Discover application schema and tables
#   --analyze:   Analyze user accounts and identify issues
#   --report:    Generate audit report
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: security-user-audit.sh --json --full
#   2. If error: Returns JSON with error details
#   3. LLM can retry with --raw for more debugging info
#   4. Or LLM runs specific --section after fixing issue

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, detect, discover, analyze, report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Database connection
DB_TYPE=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""

# Schema mapping
USERS_TABLE=""
ROLES_TABLE=""
ORGS_TABLE=""
ID_COL=""
EMAIL_COL=""
ACTIVE_COL=""
LAST_LOGIN_COL=""
CREATED_COL=""
MFA_COL=""
ORG_ID_COL=""
ROLE_COL=""

# Audit metrics
TOTAL_USERS=0
ACTIVE_USERS=0
INACTIVE_USERS=0
OLD_ACCOUNTS=0
NO_MFA=0
ADMIN_USERS=0
ORPHANED=0
DUPLICATE_COUNT=0

# Temp files
TEMP_DIR="/tmp/security-user-audit-$$"
mkdir -p "$TEMP_DIR"

cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Detect database and schema
section_detect() {
    log "${BLUE}Detecting Database and Schema${NC}"

    # Try to load from PROJECT.yaml
    if [[ -f "PROJECT.yaml" ]]; then
        DB_TYPE=$(yaml_get '.database.type' PROJECT.yaml)
        DB_HOST=$(yaml_get '.database.connection.host' PROJECT.yaml)
        DB_PORT=$(yaml_get '.database.connection.port' PROJECT.yaml)
        DB_NAME=$(yaml_get '.database.connection.database' PROJECT.yaml)
        DB_USER=$(yaml_get '.database.connection.user' PROJECT.yaml)

        # Try to detect schema from PROJECT.yaml
        USERS_TABLE=$(yaml_get '.database.schema.users_table' PROJECT.yaml)
        ROLES_TABLE=$(yaml_get '.database.schema.roles_table' PROJECT.yaml)
        ORGS_TABLE=$(yaml_get '.database.schema.organizations_table' PROJECT.yaml)
    fi

    # Filter out "null" values
    [[ "$DB_TYPE" == "null" ]] && DB_TYPE=""
    [[ "$DB_HOST" == "null" ]] && DB_HOST=""
    [[ "$DB_PORT" == "null" ]] && DB_PORT=""
    [[ "$DB_NAME" == "null" ]] && DB_NAME=""
    [[ "$DB_USER" == "null" ]] && DB_USER=""
    [[ "$USERS_TABLE" == "null" ]] && USERS_TABLE=""
    [[ "$ROLES_TABLE" == "null" ]] && ROLES_TABLE=""
    [[ "$ORGS_TABLE" == "null" ]] && ORGS_TABLE=""

    # If not found, return error for LLM to handle
    if [[ -z "$DB_TYPE" ]]; then
        exit_with_json "error" "Database configuration not found in PROJECT.yaml" \
            "Please configure database settings in PROJECT.yaml or run with --raw for interactive mode"
    fi

    # Set default port if not specified
    if [[ -z "$DB_PORT" ]]; then
        case "$DB_TYPE" in
            postgresql) DB_PORT=5432 ;;
            mysql) DB_PORT=3306 ;;
            *) DB_PORT="" ;;
        esac
    fi

    log "${GREEN}✓${NC} Database detected: $DB_TYPE"
    log "   Host: $DB_HOST"
    log "   Port: $DB_PORT"
    log "   Database: $DB_NAME"
    log "   User: $DB_USER"

    # If running only this section, return now
    if [[ "$SECTION" == "detect" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "detect",
  "message": "Database configuration detected",
  "next_action": "display_summary",
  "database": {
    "type": "$DB_TYPE",
    "host": "$DB_HOST",
    "port": $DB_PORT,
    "name": "$DB_NAME",
    "user": "$DB_USER"
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Section 2: Discover application schema
section_discover() {
    log "${BLUE}Discovering Application Schema${NC}"

    # List all tables
    local all_tables=""
    if [[ "$DB_TYPE" == "postgresql" ]]; then
        all_tables=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" 2>"$TEMP_DIR/psql-error.txt")

        if [[ $? -ne 0 ]]; then
            exit_with_json "error" "Failed to connect to database" "$(cat "$TEMP_DIR/psql-error.txt")"
        fi
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        all_tables=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -D "$DB_NAME" -Nse \
            "SHOW TABLES;" 2>"$TEMP_DIR/mysql-error.txt")

        if [[ $? -ne 0 ]]; then
            exit_with_json "error" "Failed to connect to database" "$(cat "$TEMP_DIR/mysql-error.txt")"
        fi
    else
        exit_with_json "error" "Unsupported database type: $DB_TYPE" \
            "Supported types: postgresql, mysql"
    fi

    echo "$all_tables" > "$TEMP_DIR/all-tables.txt"
    log "Available tables: $(echo "$all_tables" | wc -l)"

    # Auto-detect users table if not configured
    if [[ -z "$USERS_TABLE" ]]; then
        for table in "users" "user" "accounts" "auth_user" "app_users"; do
            if echo "$all_tables" | grep -q "^${table}$"; then
                USERS_TABLE="$table"
                log "${GREEN}✓${NC} Found users table: $USERS_TABLE"
                break
            fi
        done

        if [[ -z "$USERS_TABLE" ]]; then
            exit_with_json "error" "Could not auto-detect users table" \
                "Please configure database.schema.users_table in PROJECT.yaml\nAvailable tables:\n$all_tables"
        fi
    fi

    # Auto-detect roles table
    if [[ -z "$ROLES_TABLE" ]]; then
        for table in "roles" "user_roles" "auth_roles" "app_roles"; do
            if echo "$all_tables" | grep -q "^${table}$"; then
                ROLES_TABLE="$table"
                log "${GREEN}✓${NC} Found roles table: $ROLES_TABLE"
                break
            fi
        done
    fi

    # Auto-detect organizations table
    if [[ -z "$ORGS_TABLE" ]]; then
        for table in "organizations" "orgs" "companies" "tenants" "clients"; do
            if echo "$all_tables" | grep -q "^${table}$"; then
                ORGS_TABLE="$table"
                log "${GREEN}✓${NC} Found organizations table: $ORGS_TABLE"
                break
            fi
        done
    fi

    # Inspect users table schema
    log "Inspecting $USERS_TABLE schema..."

    if [[ "$DB_TYPE" == "postgresql" ]]; then
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "\\d $USERS_TABLE" > "$TEMP_DIR/users-schema.txt" 2>&1

        # Auto-detect column names
        ID_COL=$(grep -E "^\s+(id|user_id)\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "id")
        EMAIL_COL=$(grep -E "^\s+email\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "email")
        ACTIVE_COL=$(grep -E "^\s+(active|enabled|is_active)\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "")
        LAST_LOGIN_COL=$(grep -E "^\s+(last_login|last_sign_in|last_login_at)\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "")
        CREATED_COL=$(grep -E "^\s+(created_at|created|registration_date)\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "")
        MFA_COL=$(grep -E "^\s+(mfa|mfa_enabled|two_factor|2fa|totp_enabled)\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "")
        ORG_ID_COL=$(grep -E "^\s+(organization_id|org_id|company_id|tenant_id)\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "")
        ROLE_COL=$(grep -E "^\s+(role|user_role|role_name)\s+" "$TEMP_DIR/users-schema.txt" | awk '{print $1}' | head -1 || echo "")
    fi

    log "${GREEN}✓${NC} Schema discovery complete"
    log "   ID column: $ID_COL"
    log "   Email column: $EMAIL_COL"
    log "   Active column: ${ACTIVE_COL:-<not found>}"
    log "   Last login column: ${LAST_LOGIN_COL:-<not found>}"
    log "   MFA column: ${MFA_COL:-<not found>}"

    # If running only this section, return now
    if [[ "$SECTION" == "discover" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "discover",
  "message": "Application schema discovered",
  "next_action": "display_summary",
  "schema": {
    "users_table": "$USERS_TABLE",
    "roles_table": "${ROLES_TABLE:-null}",
    "organizations_table": "${ORGS_TABLE:-null}",
    "columns": {
      "id": "$ID_COL",
      "email": "$EMAIL_COL",
      "active": "${ACTIVE_COL:-null}",
      "last_login": "${LAST_LOGIN_COL:-null}",
      "created": "${CREATED_COL:-null}",
      "mfa": "${MFA_COL:-null}",
      "organization_id": "${ORG_ID_COL:-null}",
      "role": "${ROLE_COL:-null}"
    }
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Section 3: Analyze user accounts
section_analyze() {
    log "${BLUE}Analyzing User Accounts${NC}"

    if [[ "$DB_TYPE" != "postgresql" ]]; then
        exit_with_json "error" "Only PostgreSQL is currently supported for analysis" \
            "MySQL support coming soon"
    fi

    # Total users
    TOTAL_USERS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT count(*) FROM $USERS_TABLE;" 2>/dev/null || echo "0")
    log "Total users: $TOTAL_USERS"

    # Active vs inactive
    if [[ -n "$ACTIVE_COL" ]]; then
        ACTIVE_USERS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM $USERS_TABLE WHERE $ACTIVE_COL = true;" 2>/dev/null || echo "0")
        INACTIVE_USERS=$((TOTAL_USERS - ACTIVE_USERS))
        log "  Active: $ACTIVE_USERS"
        log "  Inactive: $INACTIVE_USERS"
    fi

    # Users without recent login
    if [[ -n "$LAST_LOGIN_COL" ]]; then
        OLD_ACCOUNTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM $USERS_TABLE WHERE $LAST_LOGIN_COL < now() - interval '90 days' OR $LAST_LOGIN_COL IS NULL;" 2>/dev/null || echo "0")
        log "  No login in 90+ days: $OLD_ACCOUNTS"

        # Get list of inactive users
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tA << EOF > "$TEMP_DIR/inactive-users.txt" 2>/dev/null || true
SELECT $ID_COL, $EMAIL_COL, $LAST_LOGIN_COL
FROM $USERS_TABLE
WHERE $LAST_LOGIN_COL < now() - interval '90 days' OR $LAST_LOGIN_COL IS NULL
ORDER BY $LAST_LOGIN_COL NULLS FIRST
LIMIT 50;
EOF
    fi

    # Users without MFA
    if [[ -n "$MFA_COL" ]]; then
        NO_MFA=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM $USERS_TABLE WHERE $MFA_COL = false OR $MFA_COL IS NULL;" 2>/dev/null || echo "0")
        log "  Without MFA: $NO_MFA"
    fi

    # Duplicate email addresses
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tA << EOF > "$TEMP_DIR/duplicate-emails.txt" 2>/dev/null || true
SELECT $EMAIL_COL, count(*) as account_count
FROM $USERS_TABLE
GROUP BY $EMAIL_COL
HAVING count(*) > 1
ORDER BY count(*) DESC;
EOF
    DUPLICATE_COUNT=$(cat "$TEMP_DIR/duplicate-emails.txt" | wc -l)

    if [[ $DUPLICATE_COUNT -gt 0 ]]; then
        log "${YELLOW}⚠${NC} Found $DUPLICATE_COUNT duplicate email addresses"
    fi

    # Users without organizations (orphaned)
    if [[ -n "$ORG_ID_COL" ]]; then
        ORPHANED=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM $USERS_TABLE WHERE $ORG_ID_COL IS NULL;" 2>/dev/null || echo "0")

        if [[ $ORPHANED -gt 0 ]]; then
            log "${YELLOW}⚠${NC} Found $ORPHANED users without organization"
        fi
    fi

    # Admin/superuser accounts
    if [[ -n "$ROLE_COL" ]]; then
        ADMIN_USERS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM $USERS_TABLE WHERE $ROLE_COL IN ('admin', 'superuser', 'administrator', 'root');" 2>/dev/null || echo "0")

        if [[ $ADMIN_USERS -gt 0 ]]; then
            log "  Admin/superuser accounts: $ADMIN_USERS"

            # Get list of admin users
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tA << EOF > "$TEMP_DIR/admin-users.txt" 2>/dev/null || true
SELECT $ID_COL, $EMAIL_COL, $ROLE_COL
FROM $USERS_TABLE
WHERE $ROLE_COL IN ('admin', 'superuser', 'administrator', 'root');
EOF
        fi
    fi

    log "${GREEN}✓${NC} Analysis complete"

    # If running only this section, return now
    if [[ "$SECTION" == "analyze" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "analyze",
  "message": "User account analysis complete",
  "next_action": "display_summary",
  "metrics": {
    "total_users": $TOTAL_USERS,
    "active_users": ${ACTIVE_USERS:-null},
    "inactive_users": ${INACTIVE_USERS:-null},
    "old_accounts_90_days": ${OLD_ACCOUNTS:-null},
    "without_mfa": ${NO_MFA:-null},
    "admin_accounts": ${ADMIN_USERS:-null},
    "orphaned_users": ${ORPHANED:-0},
    "duplicate_emails": $DUPLICATE_COUNT
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Section 4: Generate audit report
section_report() {
    log "${BLUE}Generating Audit Report${NC}"

    local audit_dir="docs/database-audits"
    mkdir -p "$audit_dir"

    local report_file="$audit_dir/$(date +%Y-%m-%d)-app-user-audit.md"

    cat > "$report_file" << EOF
# Application User Audit Report

**Date**: $(date -Iseconds)
**Database**: $DB_TYPE ($DB_NAME)
**Users Table**: $USERS_TABLE

---

## Executive Summary

- **Total users**: $TOTAL_USERS
- **Active users**: ${ACTIVE_USERS:-N/A}
- **Inactive users**: ${INACTIVE_USERS:-N/A}
- **Inactive 90+ days**: ${OLD_ACCOUNTS:-N/A}
- **Without MFA**: ${NO_MFA:-N/A}
- **Admin accounts**: ${ADMIN_USERS:-N/A}
- **Orphaned users**: ${ORPHANED:-0}
- **Duplicate emails**: ${DUPLICATE_COUNT:-0}

---

## Security Findings

### High Risk Issues

$(if [[ ${OLD_ACCOUNTS:-0} -gt 0 ]]; then
  cat << 'INACTIVE'
#### Inactive Accounts (90+ days)

Found ${OLD_ACCOUNTS} accounts with no recent login.

**Risk**: Stale accounts increase attack surface
**Recommendation**: Disable accounts inactive > 90 days

\`\`\`
$(cat "$TEMP_DIR/inactive-users.txt" | head -20 2>/dev/null || echo "Details not available")
\`\`\`
INACTIVE
fi)

$(if [[ ${NO_MFA:-0} -gt 0 ]]; then
  cat << 'NOMFA'
#### Users Without MFA

Found ${NO_MFA} users without multi-factor authentication.

**Risk**: Accounts vulnerable to credential stuffing
**Recommendation**: Require MFA for all users
NOMFA
fi)

$(if [[ ${DUPLICATE_COUNT:-0} -gt 0 ]]; then
  cat << 'DUPES'
#### Duplicate Email Addresses

Found ${DUPLICATE_COUNT} duplicate email addresses.

**Risk**: Potential account confusion or bypass
**Recommendation**: Enforce unique email constraint

\`\`\`
$(cat "$TEMP_DIR/duplicate-emails.txt" 2>/dev/null || echo "Details not available")
\`\`\`
DUPES
fi)

### Medium Risk Issues

$(if [[ ${ADMIN_USERS:-0} -gt 5 ]]; then
  echo "#### Excessive Admin Accounts"
  echo ""
  echo "Found ${ADMIN_USERS} admin/superuser accounts."
  echo ""
  echo "**Recommendation**: Review and reduce admin access"
  echo ""
fi)

$(if [[ ${ORPHANED:-0} -gt 0 ]]; then
  echo "#### Orphaned Users"
  echo ""
  echo "Found ${ORPHANED} users without organization assignment."
  echo ""
  echo "**Recommendation**: Assign to organizations or remove"
  echo ""
fi)

---

## Recommendations

### Immediate Actions (High Priority)

1. **Disable Inactive Accounts**
   \`\`\`sql
   UPDATE $USERS_TABLE
   SET ${ACTIVE_COL:-active} = false
   WHERE ${LAST_LOGIN_COL:-last_login} < now() - interval '90 days'
     AND ${ACTIVE_COL:-active} = true;
   \`\`\`

2. **Enforce MFA for All Users**
   - Enable MFA requirement in application settings
   - Notify users to enable MFA
   - Set deadline for MFA enrollment

3. **Fix Duplicate Emails**
   \`\`\`sql
   -- Add unique constraint
   ALTER TABLE $USERS_TABLE ADD CONSTRAINT unique_email UNIQUE ($EMAIL_COL);
   \`\`\`

### Short Term (This Week)

4. **Review Admin Accounts**
   - Verify each admin account is necessary
   - Demote unnecessary admin privileges
   - Implement admin approval workflow

5. **Clean Up Orphaned Accounts**
   - Assign to default organization or delete

6. **Implement Account Expiration Policy**
   - Automatically disable accounts after 90 days inactivity
   - Send reminder emails at 60 and 80 days

---

## Compliance Checklist

- [ ] All users have unique email addresses
- [ ] MFA required for all accounts
- [ ] Inactive accounts (90+ days) disabled
- [ ] Admin access reviewed and justified
- [ ] No orphaned accounts
- [ ] Password policy enforced
- [ ] Session timeouts configured
- [ ] Audit logging enabled
- [ ] Regular access reviews scheduled
- [ ] Offboarding process documented

---

## Next Audit

Schedule next application user audit: $(date -d "+30 days" +%Y-%m-%d)

EOF

    log "${GREEN}✓${NC} Audit report generated: $report_file"

    # If running only this section, return now
    if [[ "$SECTION" == "report" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "report",
  "message": "Audit report generated",
  "next_action": "display_summary",
  "report_file": "$report_file",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --detect) SECTION="detect"; shift ;;
            --discover) SECTION="discover"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --report) SECTION="report"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        detect)
            section_detect
            ;;
        discover)
            section_detect  # Prerequisites first
            section_discover
            ;;
        analyze)
            section_detect
            section_discover
            section_analyze
            ;;
        report)
            # Assume analysis already done
            section_report
            ;;
        full)
            section_detect
            section_discover
            section_analyze
            section_report

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": "success",
  "message": "Application user audit complete",
  "next_action": "display_summary",
  "sections_completed": ["detect", "discover", "analyze", "report"],
  "metrics": {
    "total_users": $TOTAL_USERS,
    "active_users": ${ACTIVE_USERS:-null},
    "inactive_users": ${INACTIVE_USERS:-null},
    "old_accounts_90_days": ${OLD_ACCOUNTS:-null},
    "without_mfa": ${NO_MFA:-null},
    "admin_accounts": ${ADMIN_USERS:-null},
    "orphaned_users": ${ORPHANED:-0},
    "duplicate_emails": $DUPLICATE_COUNT
  },
  "report_file": "docs/database-audits/$(date +%Y-%m-%d)-app-user-audit.md",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
