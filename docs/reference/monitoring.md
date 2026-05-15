# Application Monitoring Pattern

**Purpose**: Baseline monitoring to ensure applications and containers are healthy, performant, and can alert before issues become critical.

## Philosophy

**Proactive monitoring** catches issues before users notice:
- Containers are running and healthy
- Applications respond within acceptable time
- Resources (CPU/memory/disk) are within limits
- Logs show no critical errors
- External dependencies are reachable

**Three monitoring tiers:**
1. **Infrastructure**: Containers, networks, volumes
2. **Application**: Health endpoints, response times, error rates
3. **Business**: Feature-specific metrics (orders, users, transactions)

This guide focuses on tiers 1-2. Tier 3 is application-specific.

## Standard Monitoring Stack

**Required (All Projects):**
- Docker health checks (built-in)
- Application health endpoints (/health, /health/secrets)
- Log monitoring (stdout/stderr to centralized logging)

**Recommended (Production):**
- Prometheus + Grafana (metrics + visualization)
- Loki (log aggregation)
- Alertmanager (alerting)
- cAdvisor (container metrics)

**Optional (Advanced):**
- OpenTelemetry (distributed tracing)
- ELK Stack (Elasticsearch, Logstash, Kibana)
- DataDog, New Relic, or other SaaS solutions

## Docker Health Checks

Every service should define health checks in `docker-compose.yml`:

```yaml
services:
  backend:
    image: myapp/backend:latest
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  frontend:
    image: myapp/frontend:latest
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s

  postgres:
    image: postgres:16-alpine
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
```

**Monitoring health checks:**

```bash
# Check container health
docker compose ps

# Watch health status
watch -n 2 'docker compose ps'

# Get detailed health check output
docker inspect --format='{{json .State.Health}}' myapp-backend-1 | jq

# Filter unhealthy containers
docker compose ps --filter "health=unhealthy"
```

## Application Health Endpoints

All applications should implement these endpoints (see [Secret Rotation Patterns](patterns/secret-rotation.md)):

### GET /health (Basic Health)

**Purpose**: Quick check that service is alive and responding.

**Response time**: < 100ms

**Example response:**
```json
{
  "status": "healthy",
  "version": "1.2.3",
  "timestamp": "2024-02-20T15:30:00Z"
}
```

### GET /health/secrets (Secret Status)

**Purpose**: Track when secrets were loaded and next refresh time.

**Response time**: < 50ms (metadata only, no I/O)

**Example response:**
```json
{
  "secrets_loaded_at": "2024-02-20T15:25:00Z",
  "next_refresh_at": "2024-02-20T15:30:00Z",
  "refresh_interval_seconds": 300,
  "buckets_loaded": ["database", "redis", "api-keys"]
}
```

### GET /status/secrets (Active Validation)

**Purpose**: Actively test credentials work (database connections, API keys, etc.).

**Response time**: < 2 seconds (tests actual connectivity)

**Example response:**
```json
{
  "overall_status": "healthy",
  "checks": {
    "database": {
      "status": "healthy",
      "user": "myapp_user_20240220",
      "connection_time_ms": 45,
      "error": null
    },
    "redis": {
      "status": "healthy",
      "connection_time_ms": 12,
      "error": null
    },
    "stripe_api": {
      "status": "healthy",
      "test": "Retrieved account info",
      "error": null
    }
  }
}
```

### GET /metrics (Prometheus Format)

**Purpose**: Expose application metrics for Prometheus scraping.

**Response time**: < 200ms

**Example response:**
```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",path="/api/users",status="200"} 1234

# HELP http_request_duration_seconds HTTP request latency
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1"} 956
http_request_duration_seconds_bucket{le="0.5"} 1198
http_request_duration_seconds_bucket{le="1.0"} 1234

# HELP app_db_connections Active database connections
# TYPE app_db_connections gauge
app_db_connections 5
```

## Baseline Monitoring Script

**Location**: `scripts/monitor-health.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/project-config.sh"
source "${SCRIPT_DIR}/lib/colors.sh"

OUTPUT_FORMAT="human"
WATCH_MODE=false
WATCH_INTERVAL=5
ALERT_WEBHOOK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_FORMAT="$2"; shift 2 ;;
        --watch) WATCH_MODE=true; shift ;;
        --interval) WATCH_INTERVAL="$2"; shift 2 ;;
        --alert-webhook) ALERT_WEBHOOK="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

require_project_config

APP_NAME=$(get_config "name")
INSTANCE_IPS=(${APP_INSTANCES:-localhost})

check_health() {
    local timestamp=$(date -Iseconds)
    local all_healthy=true
    local issues=()

    # Check Docker containers
    local unhealthy_containers=$(docker compose ps --filter "health=unhealthy" --format json 2>/dev/null | jq -s 'length')

    if [[ ${unhealthy_containers:-0} -gt 0 ]]; then
        all_healthy=false
        issues+=("${unhealthy_containers} containers unhealthy")
    fi

    # Check application health endpoints
    for IP in "${INSTANCE_IPS[@]}"; do
        # Basic health
        health_response=$(curl -s -w "\n%{http_code}" "http://${IP}:8000/health" 2>/dev/null || echo -e "\n000")
        health_code="${health_response##*$'\n'}"

        if [[ "$health_code" != "200" ]]; then
            all_healthy=false
            issues+=("${IP}: /health returned ${health_code}")
        fi

        # Secret status
        secret_status=$(curl -s "http://${IP}:8000/status/secrets" 2>/dev/null || echo '{"overall_status":"unhealthy"}')
        overall=$(echo "$secret_status" | jq -r '.overall_status // "unknown"')

        if [[ "$overall" != "healthy" ]]; then
            all_healthy=false

            # Get specific failures
            failed=$(echo "$secret_status" | jq -r '.checks | to_entries[] | select(.value.status != "healthy") | .key' | tr '\n' ', ')
            issues+=("${IP}: secrets unhealthy (${failed%,})")
        fi
    done

    # Check resource usage
    for container in $(docker compose ps --format json | jq -r '.Name'); do
        stats=$(docker stats "$container" --no-stream --format "{{.CPUPerc}},{{.MemPerc}}" 2>/dev/null || echo "0%,0%")
        cpu=$(echo "$stats" | cut -d, -f1 | tr -d '%')
        mem=$(echo "$stats" | cut -d, -f2 | tr -d '%')

        # Alert if CPU > 80% or Memory > 90%
        if (( $(echo "$cpu > 80" | bc -l) )); then
            all_healthy=false
            issues+=("${container}: high CPU (${cpu}%)")
        fi

        if (( $(echo "$mem > 90" | bc -l) )); then
            all_healthy=false
            issues+=("${container}: high memory (${mem}%)")
        fi
    done

    # Check disk usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ $disk_usage -gt 85 ]]; then
        all_healthy=false
        issues+=("Disk usage high (${disk_usage}%)")
    fi

    # Check for recent errors in logs
    for service in $(docker compose config --services); do
        error_count=$(docker compose logs --tail=50 --since=5m "$service" 2>/dev/null | grep -ciE "(error|exception|fatal|panic)" || echo "0")

        if [[ $error_count -gt 10 ]]; then
            all_healthy=false
            issues+=("${service}: ${error_count} errors in last 5 minutes")
        fi
    done

    # Output results
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        cat <<EOF
{
  "timestamp": "${timestamp}",
  "status": "$([ "$all_healthy" == "true" ] && echo "healthy" || echo "unhealthy")",
  "app": "${APP_NAME}",
  "issues": $(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .),
  "issue_count": ${#issues[@]}
}
EOF
    else
        if [[ "$all_healthy" == "true" ]]; then
            echo "${GREEN}✓${NC} All systems healthy ($(date +%H:%M:%S))"
        else
            echo "${RED}✗${NC} Issues detected ($(date +%H:%M:%S)):"
            for issue in "${issues[@]}"; do
                echo "  ${RED}•${NC} $issue"
            done
        fi
    fi

    # Send alert if webhook configured and issues exist
    if [[ -n "$ALERT_WEBHOOK" && ${#issues[@]} -gt 0 ]]; then
        alert_payload=$(cat <<EOF
{
  "text": "⚠️ ${APP_NAME} Health Alert",
  "attachments": [{
    "color": "danger",
    "fields": [
      {"title": "Issues", "value": "${#issues[@]}"},
      {"title": "Details", "value": "$(printf '%s\\n' "${issues[@]}")"}
    ]
  }]
}
EOF
)
        curl -s -X POST -H "Content-Type: application/json" -d "$alert_payload" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
    fi

    # Return status
    [[ "$all_healthy" == "true" ]]
}

# Main execution
if [[ "$WATCH_MODE" == "true" ]]; then
    echo "${BLUE}Starting health monitor (interval: ${WATCH_INTERVAL}s)${NC}"
    echo "Press Ctrl+C to stop"
    echo ""

    while true; do
        check_health
        sleep "$WATCH_INTERVAL"
    done
else
    check_health
fi
```

## Prometheus + Grafana Setup

### docker-compose.monitoring.yml

```yaml
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    volumes:
      - grafana-data:/var/lib/grafana
      - ./monitoring/grafana/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./monitoring/grafana/datasources:/etc/grafana/provisioning/datasources:ro
    ports:
      - "3001:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD:-admin}
      - GF_USERS_ALLOW_SIGN_UP=false
    restart: unless-stopped

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports:
      - "8080:8080"
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    command:
      - '--path.rootfs=/host'
    volumes:
      - /:/host:ro,rslave
    ports:
      - "9100:9100"
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    volumes:
      - ./monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager-data:/alertmanager
    ports:
      - "9093:9093"
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--storage.path=/alertmanager'
    restart: unless-stopped

volumes:
  prometheus-data:
  grafana-data:
  alertmanager-data:
```

### monitoring/prometheus.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - '/etc/prometheus/alert-rules.yml'

scrape_configs:
  # Application metrics
  - job_name: 'backend'
    static_configs:
      - targets: ['backend:8000']
    metrics_path: '/metrics'

  - job_name: 'frontend'
    static_configs:
      - targets: ['frontend:3000']
    metrics_path: '/metrics'

  # Container metrics
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']

  # Host metrics
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']

  # Prometheus itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

### monitoring/alert-rules.yml

```yaml
groups:
  - name: application_alerts
    interval: 30s
    rules:
      # Service down
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Service {{ $labels.job }} is down"
          description: "{{ $labels.job }} has been down for more than 1 minute"

      # High error rate
      - alert: HighErrorRate
        expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate on {{ $labels.job }}"
          description: "Error rate is {{ $value | humanizePercentage }} over 5 minutes"

      # Slow response time
      - alert: SlowResponseTime
        expr: histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Slow response time on {{ $labels.job }}"
          description: "95th percentile latency is {{ $value }}s"

      # High CPU usage
      - alert: HighCPUUsage
        expr: container_cpu_usage_seconds_total > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.container_label_com_docker_compose_service }}"
          description: "CPU usage is {{ $value | humanizePercentage }}"

      # High memory usage
      - alert: HighMemoryUsage
        expr: (container_memory_usage_bytes / container_spec_memory_limit_bytes) > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.container_label_com_docker_compose_service }}"
          description: "Memory usage is {{ $value | humanizePercentage }}"

      # Database connection pool exhaustion
      - alert: DatabaseConnectionPoolExhausted
        expr: app_db_connections > 15
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Database connection pool near exhaustion"
          description: "{{ $value }} active connections (limit: 20)"

  - name: secrets_alerts
    interval: 60s
    rules:
      # Secret refresh overdue
      - alert: SecretRefreshOverdue
        expr: (time() - secrets_loaded_timestamp) > 600
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Secrets have not been refreshed"
          description: "Secrets last loaded {{ $value }}s ago (expected every 300s)"

      # Secret validation failing
      - alert: SecretValidationFailing
        expr: secret_validation_status{status="unhealthy"} > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Secret validation failing for {{ $labels.bucket }}"
          description: "Unable to validate {{ $labels.bucket }} credentials"
```

### monitoring/alertmanager.yml

```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'default'
  routes:
    - match:
        severity: critical
      receiver: 'critical'
      continue: true

    - match:
        severity: warning
      receiver: 'warning'

receivers:
  - name: 'default'
    webhook_configs:
      - url: 'http://backend:8000/webhooks/alerts'
        send_resolved: true

  - name: 'critical'
    webhook_configs:
      - url: 'http://backend:8000/webhooks/alerts/critical'
        send_resolved: true
    # Add Slack, PagerDuty, etc.
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-critical'
        title: 'Critical Alert'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

  - name: 'warning'
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-warning'
        title: 'Warning Alert'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'cluster', 'service']
```

## Log Monitoring

### Centralized Logging with Loki

**monitoring/loki.yml**:
```yaml
auth_enabled: false

server:
  http_listen_port: 3100

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
  chunk_idle_period: 5m
  chunk_retain_period: 30s

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 168h

storage_config:
  boltdb:
    directory: /tmp/loki/index

  filesystem:
    directory: /tmp/loki/chunks

limits_config:
  enforce_metric_name: false
  reject_old_samples: true
  reject_old_samples_max_age: 168h

chunk_store_config:
  max_look_back_period: 0s

table_manager:
  retention_deletes_enabled: true
  retention_period: 168h
```

### Add Loki to docker-compose.monitoring.yml

```yaml
  loki:
    image: grafana/loki:latest
    container_name: loki
    volumes:
      - ./monitoring/loki.yml:/etc/loki/loki.yml:ro
      - loki-data:/tmp/loki
    ports:
      - "3100:3100"
    command: -config.file=/etc/loki/loki.yml
    restart: unless-stopped

  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    volumes:
      - ./monitoring/promtail.yml:/etc/promtail/promtail.yml:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
    command: -config.file=/etc/promtail/promtail.yml
    depends_on:
      - loki
    restart: unless-stopped

volumes:
  loki-data:
```

### monitoring/promtail.yml

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    static_configs:
      - targets:
          - localhost
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*-json.log

    pipeline_stages:
      - json:
          expressions:
            output: log
            stream: stream
            attrs: attrs

      - json:
          expressions:
            tag: attrs.tag
          source: attrs

      - regex:
          expression: (?P<container_name>(?:[^|]*[^|]))
          source: tag

      - timestamp:
          format: RFC3339Nano
          source: time

      - labels:
          stream:
          container_name:

      - output:
          source: output
```

## Makefile Integration

```makefile
.PHONY: monitor
monitor:
	@./scripts/monitor-health.sh

.PHONY: monitor-watch
monitor-watch:
	@./scripts/monitor-health.sh --watch --interval 5

.PHONY: monitor-json
monitor-json:
	@./scripts/monitor-health.sh --output json

.PHONY: monitoring-up
monitoring-up:
	@docker compose -f docker-compose.monitoring.yml up -d
	@echo "Prometheus: http://localhost:9090"
	@echo "Grafana: http://localhost:3001 (admin/admin)"
	@echo "Alertmanager: http://localhost:9093"

.PHONY: monitoring-down
monitoring-down:
	@docker compose -f docker-compose.monitoring.yml down

.PHONY: monitoring-logs
monitoring-logs:
	@docker compose -f docker-compose.monitoring.yml logs -f

.PHONY: health-check
health-check:
	@echo "Container Health:"
	@docker compose ps
	@echo ""
	@echo "Application Health:"
	@curl -s http://localhost:8000/health | jq
	@echo ""
	@echo "Secret Status:"
	@curl -s http://localhost:8000/status/secrets | jq
```

## Alert Webhook Handler (Python)

```python
# src/routes/webhooks.py
from fastapi import APIRouter, BackgroundTasks
from pydantic import BaseModel
import logging

router = APIRouter(prefix="/webhooks")
logger = logging.getLogger(__name__)

class PrometheusAlert(BaseModel):
    status: str
    labels: dict
    annotations: dict
    startsAt: str
    endsAt: str | None = None

class AlertWebhook(BaseModel):
    receiver: str
    status: str
    alerts: list[PrometheusAlert]

@router.post("/alerts")
async def handle_alert(webhook: AlertWebhook, background_tasks: BackgroundTasks):
    """Handle Prometheus/Alertmanager webhooks"""

    for alert in webhook.alerts:
        severity = alert.labels.get("severity", "unknown")
        alertname = alert.labels.get("alertname", "unknown")

        logger.warning(
            f"Alert received: {alertname} (severity={severity}, status={alert.status})",
            extra={
                "alert": alertname,
                "severity": severity,
                "status": alert.status,
                "annotations": alert.annotations,
            }
        )

        # Add to background task queue for processing
        if alert.status == "firing":
            background_tasks.add_task(process_alert, alert)

    return {"status": "received", "count": len(webhook.alerts)}

@router.post("/alerts/critical")
async def handle_critical_alert(webhook: AlertWebhook):
    """Handle critical alerts with immediate action"""

    for alert in webhook.alerts:
        if alert.status == "firing":
            logger.critical(
                f"CRITICAL ALERT: {alert.labels.get('alertname')}",
                extra={"alert": alert.dict()}
            )

            # Send to external systems (PagerDuty, Slack, etc.)
            # await notify_oncall(alert)

    return {"status": "processed"}

async def process_alert(alert: PrometheusAlert):
    """Process alert in background"""
    # Custom alert handling logic
    # - Update incident tracking
    # - Trigger auto-remediation
    # - Send notifications
    pass
```

## PROJECT.yaml Configuration

```yaml
monitoring:
  enabled: true

  # Health check configuration
  health_checks:
    interval_seconds: 30
    timeout_seconds: 10
    retries: 3

  # Metrics
  metrics:
    enabled: true
    port: 8000
    path: /metrics

  # Alerting
  alerts:
    webhook_url: "http://backend:8000/webhooks/alerts"
    slack_webhook: "${SLACK_WEBHOOK_URL}"
    pagerduty_key: "${PAGERDUTY_KEY}"

  # Thresholds
  thresholds:
    cpu_percent: 80
    memory_percent: 90
    disk_percent: 85
    error_rate_5m: 0.05
    response_time_p95: 1.0

  # Log levels
  logging:
    level: INFO
    format: json
    retention_days: 7
```

## Monitoring Checklist

### Initial Setup
- [ ] Add Docker health checks to all services
- [ ] Implement /health, /health/secrets, /status/secrets endpoints
- [ ] Implement /metrics endpoint for Prometheus
- [ ] Create monitoring/prometheus.yml configuration
- [ ] Set up Grafana dashboards
- [ ] Configure Alertmanager with notification channels
- [ ] Deploy monitoring stack (docker-compose.monitoring.yml)

### Daily Checks
- [ ] All containers healthy (`docker compose ps`)
- [ ] No critical alerts in last 24h
- [ ] Error rates within normal range
- [ ] Response times acceptable

### Weekly Checks
- [ ] Review alert history and tune thresholds
- [ ] Check disk usage trends
- [ ] Review resource utilization
- [ ] Verify backup and log retention

### Monthly Checks
- [ ] Review and update dashboards
- [ ] Test alert delivery (fire test alert)
- [ ] Update monitoring documentation
- [ ] Review incident response times

## See Also

- [Smoke Testing Pattern](testing-smoke.md)
- [Secret Rotation Patterns](patterns/secret-rotation.md)
- [Docker Best Practices](docker.md)
- [CI/CD Pipeline Guide](pipelines.md)
