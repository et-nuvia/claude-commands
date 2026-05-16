---
command: ops-load-test
group: ops
backing_script: ~/.claude/scripts/ops-load-test.sh
mutates: [files]
runtime: ~5-30min (test duration varies)
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - docker.services
requires_project_knowledge: none
project_knowledge_sections: []
---

# /ops-load-test

Walks through load test design, generates a test script for k6, Locust, or
JMeter, executes the test against a target URL, then produces a structured
performance report. You end with a concrete pass/fail verdict against your SLO
targets and a generated test script committed to the repo.

> **Config:** PROJECT.yaml **optional** — reads `docker.services` to suggest
> the base URL for local service targets

---

## When to use it

- Before deploying to production, to validate that the service meets latency and
  throughput SLOs under expected traffic
- After `/ops-scaling` recommends a new instance count, to confirm the target
  configuration actually holds
- Regression check: confirm a recent change didn't introduce a throughput bottleneck

## Usage

```bash
/ops-load-test [free-form description]
```

**Common invocations:**

```bash
/ops-load-test                                       # interactive; prompted for all parameters
/ops-load-test "100 users, 5 minutes, staging API"  # hint passed to planning phase
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form description of the test scenario. Used to pre-fill tool, URL, VU count, and duration prompts. |
| `--tool <name>` | No | Force tool selection: `k6` (default), `locust`, `jmeter`. |
| `--target-url <url>` | No | Base URL to test (e.g., `https://staging.api.example.com`). |
| `--vus <n>` | No | Number of virtual users / concurrent connections. |
| `--duration <time>` | No | Test duration (e.g., `5m`, `300s`). |
| `--ramp-up <time>` | No | Ramp-up period before full VU count is reached (e.g., `30s`). |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `k6` *(recommended)* | Execute load test scripts | `brew install k6` / k6.io/docs |
| `locust` *(optional)* | Python-based load testing | `pip install locust` |
| `jmeter` *(optional)* | GUI + CLI load testing | jmeter.apache.org |
| `jq` | Parse script JSON responses | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `docker.services` used to suggest local base URLs.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `load-tests/` — directory where generated test scripts are written
- `/tmp/ops-load-test-result.json` — written by the script for the LLM phase

## Backing script

**Script**: `~/.claude/scripts/ops-load-test.sh`

**Inputs:** `--full` (orchestrates all sections); section flags `--select-tool`,
`--generate-script`, `--run-test`, `--generate-report`. `--generate-script`
requires `--tool`, `--target-url`, `--vus`, `--duration`, `--ramp-up`. Add
`--json` or `--raw` to control output format.

**Outputs (structured JSON):**

- `next_action` ∈ {`gather_user_input`, `display_summary`, `fix_error`}
- `gather_user_input.section` ∈ {`select-tool`, `define-scenario`} — tells LLM which inputs are needed
- `--generate-script` → `test_script` path, `tool`, `scenario_summary`
- `--run-test` → `test_results` path, `tool`, `section`
- `--generate-report` → `report_file` path, `p95_latency_ms`, `throughput_rps`,
  `error_rate_pct`, `verdict` (`pass` | `fail`)

**Invocation surface:**

```bash
~/.claude/scripts/ops-load-test.sh --full
~/.claude/scripts/ops-load-test.sh --select-tool
~/.claude/scripts/ops-load-test.sh --json --generate-script \
  --tool k6 --target-url https://staging.api.example.com \
  --vus 50 --duration 5m --ramp-up 30s
~/.claude/scripts/ops-load-test.sh --run-test
~/.claude/scripts/ops-load-test.sh --generate-report
~/.claude/scripts/ops-load-test.sh --raw --run-test    # debug
```

## How it works

1. **Select tool** — if `$ARGUMENTS` contains enough hints the script pre-fills
   suggestions; otherwise returns `gather_user_input` with `section: select-tool`.
   LLM presents tool options (k6 recommended for simplicity) and collects
   target URL, VU count, duration, and ramp-up period.
2. **Generate script** — script writes a ready-to-run test script to `load-tests/`
   (e.g., `load-tests/api-k6.js`). The script includes ramp-up, steady state,
   and ramp-down stages plus threshold assertions for P95 latency and error rate.
3. **Run test** — script executes the generated test file using the selected tool
   and captures raw results to `/tmp/`. Returns `display_summary` with the
   results path when complete.
4. **Generate report** — script parses raw results into a structured summary:
   P95 and P99 latency, throughput (req/s), error rate, and a `pass` / `fail`
   verdict against the thresholds declared in the test script.
5. **Present** — LLM surfaces the verdict, key metrics, and the report path.
   On `fail`, suggests where to look (error logs, `/ops-scaling` for throughput
   failures, code profiling for latency failures).

## Example workflows

### Scenario: Pre-production validation

```
/ops-load-test "200 users, 10 minutes, staging API"
/ops-scaling --cpu 78 --mem 65 --req-rate 200 --response-time 180 --instances 3
/deploy-to-prod
```

Run the load test against staging, feed the metrics to `/ops-scaling`, confirm
the recommendation, then deploy.

### Scenario: Validating a new instance count

```
/ops-scaling                # recommends scaling to 5 instances
# act on recommendation; redeploy
/ops-load-test              # validate the new config holds
```

Close the feedback loop: scale → test → confirm.

### Scenario: Report output

```
/ops-load-test --tool k6 --target-url https://staging.api.example.com \
               --vus 50 --duration 5m --ramp-up 30s
```

```
Load Test — k6
──────────────────────────────────────────────
Target:   https://staging.api.example.com
Config:   50 VUs  ·  5m duration  ·  30s ramp-up

Results:
  Throughput:   312 req/s
  P95 latency:  148ms   (threshold: 200ms)  PASS
  P99 latency:  220ms
  Error rate:   0.2%    (threshold: 1%)     PASS

Verdict: PASS

Test script: load-tests/api-k6.js
Results:     /tmp/ops-load-test-20260516-161204.json
Report:      /tmp/ops-load-test-20260516-161204.md
```

## Notes & gotchas

- Run against staging, not production. Load tests generate artificial traffic
  that can trigger autoscaling, exhaust connection pools, or surface rate limits
  in production dependencies.
- k6 is the recommended default: single binary, JavaScript, excellent JSON
  output. Locust requires Python; JMeter requires Java — both add setup friction.
- Test duration counts wall clock time including ramp-up and ramp-down. A `5m`
  test with `30s` ramp-up runs for 5 minutes total, not 5 minutes at full load.
- Generated test scripts are written to `load-tests/` in the project root.
  Commit them so the test is reproducible.
- **If it fails:** if the test run itself errors (not a perf failure), rerun
  with `~/.claude/scripts/ops-load-test.sh --raw --run-test` to see the raw
  tool output. Common causes: k6 not on `PATH`, target URL unreachable,
  firewall blocking the load-test host.
- **Environment difference:** on macOS (work), k6 is available via Homebrew.
  On WSL (home), install via the official k6 apt repository:
  `sudo apt install k6` after adding the k6 key.
