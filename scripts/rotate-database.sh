#!/usr/bin/env bash
set -euo pipefail

# Database Secret Rotation Script (Dual-User Pattern)
# Handles zero-downtime database credential rotation
#
# Usage: ./scripts/rotate-database.sh [--dry-run] [--auto-rollback]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"
source "${SCRIPT_DIR}/lib/colors.sh"

DRY_RUN=false
AUTO_ROLLBACK=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-auto-rollback)
            AUTO_ROLLBACK=false
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

ENV=${ENVIRONMENT:-staging}
CONFIG=$(get_app_secrets_config)

APP_NAME=$(echo "$CONFIG" | jq -r '.app_name')
BACKEND=$(echo "$CONFIG" | jq -r '.secrets_backend')

# Get application instances from PROJECT.yaml or environment
INSTANCE_IPS=(${APP_INSTANCES:-localhost})

echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "${BLUE}  Database Secret Rotation${NC}"
echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "App: ${CYAN}${APP_NAME}${NC}"
echo "Environment: ${CYAN}${ENV}${NC}"
echo "Backend: ${CYAN}${BACKEND}${NC}"
echo "Dry run: ${CYAN}${DRY_RUN}${NC}"
echo ""

if [[ "$ENV" == "production" || "$ENV" == "prod" ]]; then
    echo "${RED}⚠️  PRODUCTION ROTATION${NC}"
    echo "This will rotate production database credentials."
    read -p "Type 'yes' to continue: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Aborted"
        exit 1
    fi
fi

# Step 1: Generate new database user and password
echo "${YELLOW}Step 1: Generate new credentials${NC}"
NEW_USER="${APP_NAME}_user_$(date +%Y%m%d_%H%M%S)"
NEW_PASS=$(openssl rand -base64 32)

echo "New user: ${GREEN}${NEW_USER}${NC}"
echo "New password: ${GREEN}[hidden]${NC}"

# Step 2: Get current secret
echo ""
echo "${YELLOW}Step 2: Fetch current secret${NC}"

if [[ "$BACKEND" == "aws" ]]; then
    SECRET_ID="${APP_NAME}/${ENV}/database"
    CURRENT_SECRET=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_ID" \
        --query SecretString \
        --output text)
else
    # Infisical
    CURRENT_SECRET=$(infisical secrets get DATA \
        --env "$ENV" \
        --path "/database" \
        --plain \
        --domain https://secrets.turnersrus.com/api)
fi

DB_HOST=$(echo "$CURRENT_SECRET" | jq -r .host)
DB_PORT=$(echo "$CURRENT_SECRET" | jq -r .port)
DB_NAME=$(echo "$CURRENT_SECRET" | jq -r .database)
OLD_USER=$(echo "$CURRENT_SECRET" | jq -r .app_username)
OLD_PASS=$(echo "$CURRENT_SECRET" | jq -r .app_password)

echo "Database: ${CYAN}${DB_NAME}${NC} on ${CYAN}${DB_HOST}:${DB_PORT}${NC}"
echo "Old user: ${CYAN}${OLD_USER}${NC}"

# Step 3: Create new database user
echo ""
echo "${YELLOW}Step 3: Create new database user${NC}"

if [[ "$DRY_RUN" == "false" ]]; then
    PGPASSWORD="$OLD_PASS" psql \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$OLD_USER" \
        -d "$DB_NAME" \
        <<EOF
-- Create new user
CREATE USER ${NEW_USER} WITH PASSWORD '${NEW_PASS}';

-- Grant connect
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${NEW_USER};

-- Grant schema usage
GRANT USAGE ON SCHEMA public TO ${NEW_USER};

-- Grant table permissions (DML only)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${NEW_USER};

-- Grant sequence permissions
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${NEW_USER};

-- Grant default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${NEW_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO ${NEW_USER};
EOF

    if [[ $? -eq 0 ]]; then
        echo "${GREEN}✓${NC} Created database user: ${NEW_USER}"
    else
        echo "${RED}✗${NC} Failed to create database user"
        exit 1
    fi
else
    echo "${CYAN}[DRY RUN]${NC} Would create user: ${NEW_USER}"
fi

# Step 4: Update secret with BOTH users
echo ""
echo "${YELLOW}Step 4: Update secret with dual users${NC}"

NEW_SECRET=$(cat <<EOF
{
  "host": "${DB_HOST}",
  "port": "${DB_PORT}",
  "database": "${DB_NAME}",
  "app_username": "${NEW_USER}",
  "app_password": "${NEW_PASS}",
  "app_username_old": "${OLD_USER}",
  "app_password_old": "${OLD_PASS}",
  "migration_username": "$(echo "$CURRENT_SECRET" | jq -r .migration_username)",
  "migration_password": "$(echo "$CURRENT_SECRET" | jq -r .migration_password)"
}
EOF
)

if [[ "$DRY_RUN" == "false" ]]; then
    if [[ "$BACKEND" == "aws" ]]; then
        echo "$NEW_SECRET" > /tmp/new_secret.json
        aws secretsmanager update-secret \
            --secret-id "$SECRET_ID" \
            --secret-string "file:///tmp/new_secret.json"
        rm /tmp/new_secret.json
    else
        # Infisical
        infisical secrets set "DATA=${NEW_SECRET}" \
            --env "$ENV" \
            --path "/database" \
            --domain https://secrets.turnersrus.com/api
    fi

    echo "${GREEN}✓${NC} Updated secret with dual users"
else
    echo "${CYAN}[DRY RUN]${NC} Would update secret"
fi

# Step 5: Trigger immediate refresh
echo ""
echo "${YELLOW}Step 5: Trigger immediate refresh on all instances${NC}"

trigger_refresh() {
    local all_success=true

    for IP in "${INSTANCE_IPS[@]}"; do
        local response=$(curl -s -X POST "http://${IP}:8000/secrets/refresh" 2>/dev/null || echo '{"status":"error"}')
        local status=$(echo "$response" | jq -r '.status // "error"')

        if [[ "$status" == "success" ]]; then
            echo "  ${IP}: ${GREEN}✓${NC} Refresh triggered"
        else
            echo "  ${IP}: ${RED}✗${NC} Refresh failed"
            all_success=false
        fi
    done

    [[ "$all_success" == "true" ]]
}

if [[ "$DRY_RUN" == "false" ]]; then
    if trigger_refresh; then
        echo "${GREEN}✓${NC} All instances triggered"
        echo "Waiting 3 seconds for refresh to complete..."
        sleep 3
    else
        echo "${RED}✗${NC} Some instances failed to trigger refresh"
        if [[ "$AUTO_ROLLBACK" == "true" ]]; then
            echo "Auto-rollback enabled, rolling back..."
            ${SCRIPT_DIR}/rollback-secret.sh database
        fi
        exit 1
    fi
else
    echo "${CYAN}[DRY RUN]${NC} Would trigger refresh"
fi

# Step 6: Verify new credentials work
echo ""
echo "${YELLOW}Step 6: Verify new credentials${NC}"

verify_credentials() {
    local all_healthy=true

    for IP in "${INSTANCE_IPS[@]}"; do
        local status=$(curl -s "http://${IP}:8000/status/secrets" 2>/dev/null || echo "{}")
        local db_status=$(echo "$status" | jq -r '.checks.database.status // "unknown"')
        local db_user=$(echo "$status" | jq -r '.checks.database.user // "unknown"')

        if [[ "$db_status" == "healthy" && "$db_user" == "$NEW_USER" ]]; then
            echo "  ${IP}: ${GREEN}✓${NC} Healthy (${db_user})"
        else
            echo "  ${IP}: ${RED}✗${NC} Unhealthy or wrong user"
            all_healthy=false
        fi
    done

    [[ "$all_healthy" == "true" ]]
}

if [[ "$DRY_RUN" == "false" ]]; then
    if verify_credentials; then
        echo "${GREEN}✓${NC} All instances verified with new credentials"
    else
        echo "${RED}✗${NC} Credential verification failed"
        if [[ "$AUTO_ROLLBACK" == "true" ]]; then
            echo ""
            echo "${RED}═══════════════════════════════════════════════════════${NC}"
            echo "${RED}  AUTO-ROLLBACK TRIGGERED${NC}"
            echo "${RED}═══════════════════════════════════════════════════════${NC}"
            "${SCRIPT_DIR}/rollback-secret.sh" database
            exit 1
        else
            echo "${RED}Manual rollback required:${NC}"
            echo "  ${SCRIPT_DIR}/rollback-secret.sh database"
            exit 1
        fi
    fi
else
    echo "${CYAN}[DRY RUN]${NC} Would verify credentials"
fi

# Step 7: Drop old user
echo ""
echo "${YELLOW}Step 7: Drop old database user${NC}"
echo "Waiting 60 seconds for final verification..."

if [[ "$DRY_RUN" == "false" ]]; then
    sleep 60

    PGPASSWORD="$NEW_PASS" psql \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$NEW_USER" \
        -d "$DB_NAME" \
        -c "DROP USER IF EXISTS ${OLD_USER};"

    echo "${GREEN}✓${NC} Dropped old user: ${OLD_USER}"
else
    echo "${CYAN}[DRY RUN]${NC} Would drop old user: ${OLD_USER}"
fi

# Step 8: Clean up secret (remove old user fields)
echo ""
echo "${YELLOW}Step 8: Clean up secret${NC}"

FINAL_SECRET=$(cat <<EOF
{
  "host": "${DB_HOST}",
  "port": "${DB_PORT}",
  "database": "${DB_NAME}",
  "app_username": "${NEW_USER}",
  "app_password": "${NEW_PASS}",
  "migration_username": "$(echo "$CURRENT_SECRET" | jq -r .migration_username)",
  "migration_password": "$(echo "$CURRENT_SECRET" | jq -r .migration_password)"
}
EOF
)

if [[ "$DRY_RUN" == "false" ]]; then
    if [[ "$BACKEND" == "aws" ]]; then
        echo "$FINAL_SECRET" > /tmp/final_secret.json
        aws secretsmanager update-secret \
            --secret-id "$SECRET_ID" \
            --secret-string "file:///tmp/final_secret.json"
        rm /tmp/final_secret.json
    else
        infisical secrets set "DATA=${FINAL_SECRET}" \
            --env "$ENV" \
            --path "/database" \
            --domain https://secrets.turnersrus.com/api
    fi

    echo "${GREEN}✓${NC} Cleaned up secret"
else
    echo "${CYAN}[DRY RUN]${NC} Would clean up secret"
fi

# Done
echo ""
echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo "${GREEN}  Rotation Complete!${NC}"
echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo "Old user: ${CYAN}${OLD_USER}${NC} (dropped)"
echo "New user: ${CYAN}${NEW_USER}${NC} (active)"
echo "Next rotation: $(date -d '+90 days' +%Y-%m-%d)"
