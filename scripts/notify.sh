#!/usr/bin/env bash
set -euo pipefail

# Notification Script
# Send deployment notifications to Slack/Discord/Cliq/etc
# Usage: notify.sh --status <success|failure|info> [--message <msg>]
# Copy to project: cp ~/.claude/scripts/notify.sh ./scripts/

STATUS=""
MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)  STATUS="$2";  shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --status <success|failure|info> [--message <msg>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$STATUS" ]]; then
  echo "Error: --status is required" >&2
  echo "Usage: $0 --status <success|failure|info> [--message <msg>]" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Configuration (set via environment or secrets manager)
# ─────────────────────────────────────────────────────────────
# SLACK_WEBHOOK_URL - from secrets manager
# DISCORD_WEBHOOK_URL - from secrets manager
# CLIQ_WEBHOOK_URL - from secrets manager (Zoho Cliq)
# TEAMS_WEBHOOK_URL - from secrets manager

# Source project config if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/project-config.sh" ]]; then
    source "${SCRIPT_DIR}/lib/project-config.sh"
fi

# Get from environment or fetch from secrets
get_webhook_url() {
    local service="$1"

    # Check environment first
    local env_var="$(echo "$service" | tr '[:lower:]' '[:upper:]')_WEBHOOK_URL"
    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
        return
    fi

    # Try to read from PROJECT.yaml if exists
    if [[ -f "PROJECT.yaml" ]] && command -v yq &> /dev/null; then
        local bucket secret_key
        bucket=$(yq ".notifications.channels.${service}.secret_bucket // \"notifications\"" PROJECT.yaml 2>/dev/null)
        secret_key=$(yq ".notifications.channels.${service}.secret_keys.webhook_url // \"${service}_webhook\"" PROJECT.yaml 2>/dev/null)

        if [[ -n "${bucket}" && "${bucket}" != "null" ]]; then
            # Fetch from secrets manager based on environment
            if [[ "$(uname -s)" == "Darwin" ]]; then
                # AWS Secrets Manager (work)
                local app_name
                app_name=$(yq '.name' PROJECT.yaml 2>/dev/null)
                local secret_json
                secret_json=$(aws secretsmanager get-secret-value \
                    --secret-id "${app_name}/${ENVIRONMENT}/${bucket}" \
                    --query "SecretString" --output text 2>/dev/null || echo "{}")
                echo "${secret_json}" | jq -r ".${secret_key} // \"\"" 2>/dev/null
                return
            else
                # Infisical (home)
                # Use infisical CLI or API to fetch
                local app_name
                app_name=$(yq '.name' PROJECT.yaml 2>/dev/null)
                if command -v infisical &> /dev/null; then
                    infisical secrets get "${secret_key}" \
                        --path "/${app_name}/${bucket}" \
                        --env "${ENVIRONMENT}" \
                        --plain 2>/dev/null || echo ""
                    return
                fi
            fi
        fi
    fi

    # Fallback: try deployment.yaml (legacy)
    if [[ -f "deployment.yaml" ]] && command -v yq &> /dev/null; then
        local url
        url=$(yq ".notifications.webhooks.${service} // \"\"" deployment.yaml 2>/dev/null || echo "")
        if [[ -n "${url}" && "${url}" != "null" ]]; then
            echo "${url}"
            return
        fi
    fi

    echo ""
}

# Get email configuration from PROJECT.yaml
get_email_config() {
    local key="$1"

    if [[ -f "PROJECT.yaml" ]] && command -v yq &> /dev/null; then
        yq ".notifications.channels.email.${key} // \"\"" PROJECT.yaml 2>/dev/null
    else
        echo ""
    fi
}

# Get email credentials from secrets
get_email_credentials() {
    local bucket secret_key_prefix
    bucket=$(get_email_config "secret_bucket")
    bucket="${bucket:-notifications}"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        # AWS - credentials are implicit via IAM
        echo "aws"
    else
        # Infisical (home)
        local app_name
        app_name=$(yq '.name' PROJECT.yaml 2>/dev/null)
        if command -v infisical &> /dev/null; then
            infisical secrets get "email_api_key" \
                --path "/${app_name}/${bucket}" \
                --env "${ENVIRONMENT}" \
                --plain 2>/dev/null || echo ""
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
# Build notification payload
# ─────────────────────────────────────────────────────────────
PROJECT="${CI_PROJECT_NAME:-${GITHUB_REPOSITORY:-$(basename "$(pwd)")}}"
BRANCH="${CI_COMMIT_BRANCH:-${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || echo "unknown")}}"
COMMIT="${CI_COMMIT_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}}"
COMMIT_SHORT="${COMMIT:0:8}"
AUTHOR="${CI_COMMIT_AUTHOR:-${GITHUB_ACTOR:-$(git log -1 --format='%an' 2>/dev/null || echo "unknown")}}"
ENVIRONMENT="${ENVIRONMENT:-unknown}"
PIPELINE_URL="${CI_PIPELINE_URL:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}}"

case "${STATUS}" in
    success)
        COLOR="#36a64f"  # Green
        COLOR_DECIMAL=3582807
        EMOJI="✅"
        TITLE="Deployment Successful"
        CLIQ_THEME="prompt"
        ;;
    failure)
        COLOR="#dc3545"  # Red
        COLOR_DECIMAL=14431557
        EMOJI="❌"
        TITLE="Deployment Failed"
        CLIQ_THEME="modern-inline"
        ;;
    info)
        COLOR="#17a2b8"  # Blue
        COLOR_DECIMAL=1548984
        EMOJI="ℹ️"
        TITLE="Deployment Info"
        CLIQ_THEME="prompt"
        ;;
    *)
        COLOR="#6c757d"  # Gray
        COLOR_DECIMAL=7107437
        EMOJI="📋"
        TITLE="Deployment Update"
        CLIQ_THEME="prompt"
        ;;
esac

# Default message
if [[ -z "${MESSAGE}" ]]; then
    MESSAGE="${PROJECT} deployed to ${ENVIRONMENT}"
fi

# ─────────────────────────────────────────────────────────────
# Send to Zoho Cliq
# ─────────────────────────────────────────────────────────────
send_cliq() {
    local webhook_url
    webhook_url=$(get_webhook_url "cliq")

    if [[ -z "${webhook_url}" ]]; then
        echo "Cliq webhook not configured, skipping"
        return
    fi

    # Cliq card format
    # https://www.zoho.com/cliq/help/platform/message-cards.html
    local payload
    payload=$(cat <<EOF
{
  "text": "${EMOJI} ${TITLE}",
  "card": {
    "title": "${TITLE}",
    "theme": "${CLIQ_THEME}",
    "thumbnail": "https://www.zohowebstatic.com/sites/default/files/cliq/cliq-logo.png"
  },
  "slides": [
    {
      "type": "table",
      "title": "Deployment Details",
      "data": {
        "headers": ["Field", "Value"],
        "rows": [
          {"Field": "Project", "Value": "${PROJECT}"},
          {"Field": "Environment", "Value": "${ENVIRONMENT}"},
          {"Field": "Branch", "Value": "${BRANCH}"},
          {"Field": "Commit", "Value": "${COMMIT_SHORT}"},
          {"Field": "Author", "Value": "${AUTHOR}"},
          {"Field": "Status", "Value": "${STATUS}"}
        ]
      }
    },
    {
      "type": "text",
      "title": "Message",
      "data": "${MESSAGE}"
    }
  ],
  "buttons": [
    {
      "label": "View Pipeline",
      "type": "+",
      "action": {
        "type": "open.url",
        "data": {
          "web": "${PIPELINE_URL}"
        }
      }
    }
  ]
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${webhook_url}")

    local http_code="${response##*$'\n'}"
    local body="${response%$'\n'*}"

    if [[ "${http_code}" == "200" ]]; then
        echo "Cliq notification sent"
    else
        echo "Cliq notification failed (HTTP ${http_code}): ${body}"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send to Slack
# ─────────────────────────────────────────────────────────────
send_slack() {
    local webhook_url
    webhook_url=$(get_webhook_url "slack")

    if [[ -z "${webhook_url}" ]]; then
        echo "Slack webhook not configured, skipping"
        return
    fi

    local payload
    payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${COLOR}",
      "blocks": [
        {
          "type": "header",
          "text": {
            "type": "plain_text",
            "text": "${EMOJI} ${TITLE}"
          }
        },
        {
          "type": "section",
          "fields": [
            {"type": "mrkdwn", "text": "*Project:*\n${PROJECT}"},
            {"type": "mrkdwn", "text": "*Environment:*\n${ENVIRONMENT}"},
            {"type": "mrkdwn", "text": "*Branch:*\n${BRANCH}"},
            {"type": "mrkdwn", "text": "*Commit:*\n${COMMIT_SHORT}"},
            {"type": "mrkdwn", "text": "*Author:*\n${AUTHOR}"}
          ]
        },
        {
          "type": "section",
          "text": {"type": "mrkdwn", "text": "${MESSAGE}"}
        },
        {
          "type": "actions",
          "elements": [
            {
              "type": "button",
              "text": {"type": "plain_text", "text": "View Pipeline"},
              "url": "${PIPELINE_URL}"
            }
          ]
        }
      ]
    }
  ]
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${webhook_url}")

    local http_code="${response##*$'\n'}"

    if [[ "${http_code}" == "200" ]]; then
        echo "Slack notification sent"
    else
        echo "Slack notification failed (HTTP ${http_code})"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send to Discord
# ─────────────────────────────────────────────────────────────
send_discord() {
    local webhook_url
    webhook_url=$(get_webhook_url "discord")

    if [[ -z "${webhook_url}" ]]; then
        echo "Discord webhook not configured, skipping"
        return
    fi

    local payload
    payload=$(cat <<EOF
{
  "embeds": [
    {
      "title": "${EMOJI} ${TITLE}",
      "description": "${MESSAGE}",
      "color": ${COLOR_DECIMAL},
      "fields": [
        {"name": "Project", "value": "${PROJECT}", "inline": true},
        {"name": "Environment", "value": "${ENVIRONMENT}", "inline": true},
        {"name": "Branch", "value": "${BRANCH}", "inline": true},
        {"name": "Commit", "value": "${COMMIT_SHORT}", "inline": true},
        {"name": "Author", "value": "${AUTHOR}", "inline": true}
      ],
      "url": "${PIPELINE_URL}"
    }
  ]
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${webhook_url}")

    local http_code="${response##*$'\n'}"

    if [[ "${http_code}" == "204" || "${http_code}" == "200" ]]; then
        echo "Discord notification sent"
    else
        echo "Discord notification failed (HTTP ${http_code})"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send to Microsoft Teams
# ─────────────────────────────────────────────────────────────
send_teams() {
    local webhook_url
    webhook_url=$(get_webhook_url "teams")

    if [[ -z "${webhook_url}" ]]; then
        echo "Teams webhook not configured, skipping"
        return
    fi

    local payload
    payload=$(cat <<EOF
{
  "@type": "MessageCard",
  "@context": "http://schema.org/extensions",
  "themeColor": "${COLOR:1}",
  "summary": "${TITLE}",
  "sections": [{
    "activityTitle": "${EMOJI} ${TITLE}",
    "facts": [
      {"name": "Project", "value": "${PROJECT}"},
      {"name": "Environment", "value": "${ENVIRONMENT}"},
      {"name": "Branch", "value": "${BRANCH}"},
      {"name": "Commit", "value": "${COMMIT_SHORT}"},
      {"name": "Author", "value": "${AUTHOR}"}
    ],
    "text": "${MESSAGE}"
  }],
  "potentialAction": [{
    "@type": "OpenUri",
    "name": "View Pipeline",
    "targets": [{"os": "default", "uri": "${PIPELINE_URL}"}]
  }]
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${webhook_url}")

    local http_code="${response##*$'\n'}"

    if [[ "${http_code}" == "200" ]]; then
        echo "Teams notification sent"
    else
        echo "Teams notification failed (HTTP ${http_code})"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send Email via AWS SES
# ─────────────────────────────────────────────────────────────
send_email_ses() {
    local to_address from_address
    to_address=$(get_email_config "to")
    from_address=$(get_email_config "from")

    if [[ -z "${to_address}" || -z "${from_address}" ]]; then
        echo "Email addresses not configured, skipping SES"
        return
    fi

    local subject="${EMOJI} ${TITLE} - ${PROJECT}"
    local body="
<html>
<body>
<h2>${EMOJI} ${TITLE}</h2>
<table>
<tr><td><b>Project:</b></td><td>${PROJECT}</td></tr>
<tr><td><b>Environment:</b></td><td>${ENVIRONMENT}</td></tr>
<tr><td><b>Branch:</b></td><td>${BRANCH}</td></tr>
<tr><td><b>Commit:</b></td><td>${COMMIT_SHORT}</td></tr>
<tr><td><b>Author:</b></td><td>${AUTHOR}</td></tr>
</table>
<p>${MESSAGE}</p>
<p><a href=\"${PIPELINE_URL}\">View Pipeline</a></p>
</body>
</html>"

    if aws ses send-email \
        --from "${from_address}" \
        --destination "ToAddresses=${to_address}" \
        --message "Subject={Data='${subject}'},Body={Html={Data='${body}'}}" \
        --region "${REGION:-us-east-1}" 2>/dev/null; then
        echo "AWS SES email sent"
    else
        echo "AWS SES email failed"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send Email via Mailgun
# ─────────────────────────────────────────────────────────────
send_email_mailgun() {
    local api_key domain to_address from_address
    api_key=$(get_email_credentials)
    domain=$(get_email_config "domain")
    to_address=$(get_email_config "to")
    from_address=$(get_email_config "from")

    if [[ -z "${api_key}" || -z "${domain}" || -z "${to_address}" ]]; then
        echo "Mailgun not configured, skipping"
        return
    fi

    local subject="${EMOJI} ${TITLE} - ${PROJECT}"
    local body="
<html>
<body>
<h2>${EMOJI} ${TITLE}</h2>
<table>
<tr><td><b>Project:</b></td><td>${PROJECT}</td></tr>
<tr><td><b>Environment:</b></td><td>${ENVIRONMENT}</td></tr>
<tr><td><b>Branch:</b></td><td>${BRANCH}</td></tr>
<tr><td><b>Commit:</b></td><td>${COMMIT_SHORT}</td></tr>
<tr><td><b>Author:</b></td><td>${AUTHOR}</td></tr>
</table>
<p>${MESSAGE}</p>
<p><a href=\"${PIPELINE_URL}\">View Pipeline</a></p>
</body>
</html>"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --user "api:${api_key}" \
        "https://api.mailgun.net/v3/${domain}/messages" \
        -F from="${from_address}" \
        -F to="${to_address}" \
        -F subject="${subject}" \
        -F html="${body}")

    local http_code="${response##*$'\n'}"

    if [[ "${http_code}" == "200" ]]; then
        echo "Mailgun email sent"
    else
        echo "Mailgun email failed (HTTP ${http_code})"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send Email via SendGrid
# ─────────────────────────────────────────────────────────────
send_email_sendgrid() {
    local api_key to_address from_address
    api_key=$(get_email_credentials)
    to_address=$(get_email_config "to")
    from_address=$(get_email_config "from")

    if [[ -z "${api_key}" || -z "${to_address}" || -z "${from_address}" ]]; then
        echo "SendGrid not configured, skipping"
        return
    fi

    local subject="${EMOJI} ${TITLE} - ${PROJECT}"
    local body="
<html>
<body>
<h2>${EMOJI} ${TITLE}</h2>
<table>
<tr><td><b>Project:</b></td><td>${PROJECT}</td></tr>
<tr><td><b>Environment:</b></td><td>${ENVIRONMENT}</td></tr>
<tr><td><b>Branch:</b></td><td>${BRANCH}</td></tr>
<tr><td><b>Commit:</b></td><td>${COMMIT_SHORT}</td></tr>
<tr><td><b>Author:</b></td><td>${AUTHOR}</td></tr>
</table>
<p>${MESSAGE}</p>
<p><a href=\"${PIPELINE_URL}\">View Pipeline</a></p>
</body>
</html>"

    local payload
    payload=$(cat <<EOF
{
  "personalizations": [{"to": [{"email": "${to_address}"}]}],
  "from": {"email": "${from_address}"},
  "subject": "${subject}",
  "content": [{"type": "text/html", "value": "${body}"}]
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "https://api.sendgrid.com/v3/mail/send")

    local http_code="${response##*$'\n'}"

    if [[ "${http_code}" == "202" || "${http_code}" == "200" ]]; then
        echo "SendGrid email sent"
    else
        echo "SendGrid email failed (HTTP ${http_code})"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send Email via Resend
# ─────────────────────────────────────────────────────────────
send_email_resend() {
    local api_key to_address from_address
    api_key=$(get_email_credentials)
    to_address=$(get_email_config "to")
    from_address=$(get_email_config "from")

    if [[ -z "${api_key}" || -z "${to_address}" || -z "${from_address}" ]]; then
        echo "Resend not configured, skipping"
        return
    fi

    local subject="${EMOJI} ${TITLE} - ${PROJECT}"
    local body="
<html>
<body>
<h2>${EMOJI} ${TITLE}</h2>
<table>
<tr><td><b>Project:</b></td><td>${PROJECT}</td></tr>
<tr><td><b>Environment:</b></td><td>${ENVIRONMENT}</td></tr>
<tr><td><b>Branch:</b></td><td>${BRANCH}</td></tr>
<tr><td><b>Commit:</b></td><td>${COMMIT_SHORT}</td></tr>
<tr><td><b>Author:</b></td><td>${AUTHOR}</td></tr>
</table>
<p>${MESSAGE}</p>
<p><a href=\"${PIPELINE_URL}\">View Pipeline</a></p>
</body>
</html>"

    local payload
    payload=$(cat <<EOF
{
  "from": "${from_address}",
  "to": ["${to_address}"],
  "subject": "${subject}",
  "html": "${body}"
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "https://api.resend.com/emails")

    local http_code="${response##*$'\n'}"

    if [[ "${http_code}" == "200" ]]; then
        echo "Resend email sent"
    else
        echo "Resend email failed (HTTP ${http_code})"
    fi
}

# ─────────────────────────────────────────────────────────────
# Send Email (dispatches to correct provider)
# ─────────────────────────────────────────────────────────────
send_email() {
    local provider
    provider=$(get_email_config "provider")

    if [[ -z "${provider}" || "${provider}" == "null" ]]; then
        echo "Email provider not configured, skipping"
        return
    fi

    case "${provider}" in
        aws_ses)
            send_email_ses
            ;;
        mailgun)
            send_email_mailgun
            ;;
        sendgrid)
            send_email_sendgrid
            ;;
        resend)
            send_email_resend
            ;;
        *)
            echo "Unknown email provider: ${provider}"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# Check if channel is enabled in PROJECT.yaml
# ─────────────────────────────────────────────────────────────
is_channel_enabled() {
    local channel="$1"

    if [[ -f "PROJECT.yaml" ]] && command -v yq &> /dev/null; then
        local enabled
        enabled=$(yq ".notifications.channels.${channel}.enabled // false" PROJECT.yaml 2>/dev/null)
        [[ "${enabled}" == "true" ]]
    else
        # Fallback: try to send if webhook is configured
        return 0
    fi
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
echo "Sending ${STATUS} notification..."
echo "  Project: ${PROJECT}"
echo "  Environment: ${ENVIRONMENT}"
echo "  Message: ${MESSAGE}"
echo ""

# Check if notifications are enabled globally
NOTIFICATIONS_ENABLED="true"
if [[ -f "PROJECT.yaml" ]] && command -v yq &> /dev/null; then
    NOTIFICATIONS_ENABLED=$(yq ".notifications.enabled // true" PROJECT.yaml 2>/dev/null)
fi

if [[ "${NOTIFICATIONS_ENABLED}" != "true" ]]; then
    echo "Notifications disabled in PROJECT.yaml"
    exit 0
fi

# Send to enabled channels
is_channel_enabled "cliq" && send_cliq
is_channel_enabled "slack" && send_slack
is_channel_enabled "discord" && send_discord
is_channel_enabled "teams" && send_teams
is_channel_enabled "email" && send_email

echo ""
echo "Notifications complete"
