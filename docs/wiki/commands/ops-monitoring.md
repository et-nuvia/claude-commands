---
command: ops-monitoring
group: ops
backing_script: ~/.claude/scripts/ops-monitoring.sh
mutates: [files]
runtime: ~30-90s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - docker.services
requires_project_knowledge: none
project_knowledge_sections: []
---

# /ops-monitoring

Detects the existing monitoring stack (Prometheus, Grafana, or cloud-native),
then generates service-specific scrape configs, alert rules, and dashboard
definitions for a named service. Leaves nothing to guess: you finish with
committed config files and a clear view of what to wire up next.

> **Config:** PROJECT.yaml **optional** — reads `docker.services` to infer
> which services are candidates for instrumentation

---

## When to use it

- A new service needs Prometheus scrape targets and alert rules added
- Grafana dashboards are missing for a service and need to be generated from scratch
- You want to audit which services currently have monitoring configured

## Usage

```bash
/ops-monitoring [service-name]
```

**Common invocations:**

```bash
/ops-monitoring                         # auto-detect stack; prompted for service
/ops-monitoring api                     # detect + generate for a known service
/ops-monitoring api --stack prometheus  # skip detection, use specified stack
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Service name to monitor. Prompted interactively when omitted. |
| `--stack <name>` | No | Override detected stack (`prometheus`, `grafana`, `cloudwatch`). |
| `--service-type <type>` | No | One of `web_api`, `worker`, `database`, `queue`, `custom`. Prompted when omitted. |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `docker` + `docker compose` (V2) | Inspect running services for detection | Docker Desktop / Engine |
| `jq` | Parse script JSON responses | `brew install jq` / `apt install jq` |
| `prometheus` / `promtool` *(optional)* | Validate generated scrape config | prometheus.io/download |
| `grafana-cli` *(optional)* | Validate dashboard JSON | grafana.com |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `docker.services` used to enumerate candidates.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `prometheus.yml` / `docker-compose.yml` — read during detection; alert rules and scrape configs written here
- `/tmp/ops-monitoring-result.json` — written by the script for the LLM phase

## Backing script

**Script**: `~/.claude/scripts/ops-monitoring.sh`

**Inputs:** `--detect` (no further args); `--generate --service-name <s> --service-type <t> --monitoring-stack <stack>`; `--verify --service-name <name>`; optional `--json` / `--raw`.

**Outputs (structured JSON):**

- `next_action` ∈ {`gather_user_input`, `configure_monitoring`, `display_summary`, `fix_error`}
- `--detect` → `monitoring_stack`, `services[]`, `config_paths{}`
- `--generate` → `files_written[]`, `alert_rules_count`, `dashboard_uid`
- `--verify` → `service`, `scrape_target_reachable`, `alerts_loaded`, `dashboard_present`

**Invocation surface:**

```bash
~/.claude/scripts/ops-monitoring.sh --detect
~/.claude/scripts/ops-monitoring.sh --json --generate \
  --service-name api --service-type web_api --monitoring-stack prometheus
~/.claude/scripts/ops-monitoring.sh --verify --service-name api
~/.claude/scripts/ops-monitoring.sh --raw --detect          # debug
~/.claude/scripts/ops-monitoring.sh --raw --verify --service-name api
```

## How it works

1. **Detect** — script scans running containers and config files to identify the
   monitoring stack in use (Prometheus, Grafana, CloudWatch) and lists candidate
   services. Returns `gather_user_input` when detection succeeds, or
   `configure_monitoring` when no stack is found.
2. **Collect inputs** — if the LLM received `gather_user_input`, it presents the
   detected stack and service list, then asks the user to pick a service and its
   type (`web_api`, `worker`, `database`, `queue`, `custom`).
3. **Generate** — script produces scrape configs (Prometheus targets), alert
   rules (latency, error rate, saturation), and a Grafana dashboard definition.
   Files are written to the project config paths discovered in step 1.
4. **Verify** — script checks that the scrape target is reachable, alerts loaded
   correctly, and the dashboard UID exists. Returns `display_summary` on success.
5. **Summary** — LLM presents the list of written files and suggests next steps
   (restart Prometheus, import the dashboard, add `/ops-scaling` if CPU alerts fire).

## Example workflows

### Scenario: First-time monitoring setup

```
/ops-monitoring api     # generate prometheus + grafana config for the API
/ops-scaling            # pull metrics in immediately after confirming targets
```

Wire up Prometheus targets once, then use `/ops-scaling` to act on them.

### Scenario: Monitoring a new worker service

```
/ops-monitoring
```

```
Detected stack: prometheus + grafana
Services found: api, worker, db, redis

Which service to monitor? worker
Service type? (web_api / worker / database / queue / custom): worker

Generating monitoring config for "worker" (type: worker)...

Files written:
  prometheus/targets/worker.yml     (scrape config, 15s interval)
  prometheus/rules/worker.yml       (5 alert rules: queue_depth, lag, error_rate, saturation, oom)
  grafana/dashboards/worker.json    (dashboard UID: worker-overview)

Verification:
  Scrape target reachable:  yes
  Alerts loaded:            5/5
  Dashboard present:        yes

Next: restart Prometheus to activate new rules, then import the dashboard.
```

### Scenario: Audit existing coverage

```
/ops-monitoring         # run detect only; review services list for gaps
```

Compare the `services[]` list against what you know should be monitored.

## Notes & gotchas

- Only files related to monitoring config are written — no application code is touched.
- If Docker is not running, detection falls back to file-based discovery; the
  `services[]` list may be incomplete.
- Restarting Prometheus is required after generating new rule files; the script
  does not restart containers automatically.
- **If it fails:** rerun with `~/.claude/scripts/ops-monitoring.sh --raw --detect`
  to see unformatted output. For verify failures: `--raw --verify --service-name <name>`.
  If Prometheus isn't found, ensure the container is up and `prometheus.yml` exists
  in the project root or a `monitoring/` subdirectory.
