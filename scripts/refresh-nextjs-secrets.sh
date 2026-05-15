#!/usr/bin/env bash
# refresh-nextjs-secrets.sh
# Refreshes Next.js secrets by replacing placeholders in template files
#
# Next.js bakes environment variables at build time, so we need to:
# 1. Keep template files with __SECRET_BUCKET_KEY__ placeholders
# 2. Fetch current secrets from AWS/Infisical
# 3. Use sed to replace placeholders
# 4. Optionally restart the Next.js process
#
# Usage: ./scripts/refresh-nextjs-secrets.sh
# Requires: PROJECT.yaml, jq, yq, aws-cli or infisical-cli

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"

require_project_config

# Configuration from PROJECT.yaml
APP_NAME=$(get_app_name)
ENV="${ENVIRONMENT:-development}"
BACKEND=$(get_secrets_backend)

# Infisical configuration (from PROJECT.yaml)
INFISICAL_PROJECT_ID=$(get_config '.secrets.infisical.project_id' '')

# Next.js specific config
TEMPLATE_DIR=$(get_config '.secrets.refresh.strategies.nextjs.template_dir' '.secrets-templates')
RESTART_CMD=$(get_config '.secrets.refresh.strategies.nextjs.restart_command' '')

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refreshing Next.js secrets for ${APP_NAME}/${ENV}..."

# Check template directory exists
if [[ ! -d "$TEMPLATE_DIR" ]]; then
    echo "Error: Template directory '${TEMPLATE_DIR}' not found"
    echo "Create it with: mkdir -p ${TEMPLATE_DIR}"
    echo "Then copy your .env files: cp .env.local ${TEMPLATE_DIR}/.env.local.template"
    echo "And replace values with placeholders like: __SECRET_DATABASE_HOST__"
    exit 1
fi

# Get required buckets
BUCKETS=$(yq '.secrets.required[]' PROJECT.yaml 2>/dev/null || echo "")
if [[ -z "$BUCKETS" ]]; then
    echo "Warning: No secrets.required buckets defined in PROJECT.yaml"
    exit 0
fi

# Temporary file for building sed commands
SED_SCRIPT=$(mktemp)
trap "rm -f ${SED_SCRIPT}" EXIT

echo "Fetching secrets from ${BACKEND}..."

for bucket in $BUCKETS; do
    echo "  - Fetching bucket: ${bucket}"

    # Fetch bucket JSON based on backend
    if [[ "$BACKEND" == "aws" ]]; then
        SECRETS=$(aws secretsmanager get-secret-value \
            --secret-id "${APP_NAME}/${ENV}/${bucket}" \
            --query SecretString --output text 2>/dev/null || echo "{}")
    else
        # Infisical - get the DATA secret which contains JSON
        SECRETS=$(infisical secrets get DATA \
            --projectId "${INFISICAL_PROJECT_ID}" \
            --env "${ENV}" \
            --path "/${APP_NAME}/${bucket}" \
            --plain 2>/dev/null || echo "{}")
    fi

    # Skip if empty
    if [[ "$SECRETS" == "{}" || -z "$SECRETS" ]]; then
        echo "    Warning: Bucket '${bucket}' is empty or not found"
        continue
    fi

    # Parse each key from the bucket JSON and create sed commands
    # Placeholder format: __SECRET_BUCKET_KEY__
    for key in $(echo "$SECRETS" | jq -r 'keys[]'); do
        value=$(echo "$SECRETS" | jq -r ".${key}")
        # Escape special characters for sed
        escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
        # Create placeholder: __SECRET_DATABASE_HOST__ for bucket=database, key=host
        placeholder="__SECRET_$(echo "$bucket" | tr '[:lower:]' '[:upper:]')_$(echo "$key" | tr '[:lower:]' '[:upper:]')__"
        echo "s|${placeholder}|${escaped_value}|g" >> "$SED_SCRIPT"
    done
done

# Process each target file
TARGET_FILES=$(yq '.secrets.refresh.strategies.nextjs.target_files[]' PROJECT.yaml 2>/dev/null || echo ".env.local")
if [[ -z "$TARGET_FILES" ]]; then
    TARGET_FILES=".env.local"
fi

echo "Updating target files..."
for target in $TARGET_FILES; do
    template="${TEMPLATE_DIR}/${target}.template"

    if [[ ! -f "$template" ]]; then
        echo "  - Skipping ${target}: template not found at ${template}"
        continue
    fi

    echo "  - ${target}"
    sed -f "$SED_SCRIPT" "$template" > "${target}"
done

# Restart if configured
if [[ -n "$RESTART_CMD" && "$RESTART_CMD" != "null" ]]; then
    echo "Restarting Next.js: ${RESTART_CMD}"
    eval "$RESTART_CMD" || echo "Warning: Restart command failed"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Secret refresh complete!"
