---
command: ops-scaling
group: ops
backing_script: ~/.claude/scripts/ops-scaling.sh
mutates: []
runtime: ~15-30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /ops-scaling

Takes five current metrics (CPU, memory, request rate, response time, instance
count), runs a decision algorithm, and delivers a concrete recommendation:
horizontal scaling (add instances) or vertical scaling (upgrade instance size),
with a target instance count and a written report. Makes no changes to
infrastructure.

---

## When to use it

- CPU or memory is consistently high and you need a data-backed scaling decision
- Response times are degrading and you're unsure whether to scale out or up
- You want a point-in-time scaling report before a traffic event (launch, campaign)

## Usage

```bash
/ops-scaling [metric flags]
```

**Common invocations:**

```bash
/ops-scaling                                                 # interactive prompts for all metrics
/ops-scaling --cpu 85 --mem 70 --req-rate 500 \
             --response-time 300 --instances 3              # fully programmatic
/ops-scaling --cpu 60 --mem 90 --instances 2               # partial flags; remaining prompted
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--cpu <pct>` | No | Current CPU utilisation 0–100. Prompted when omitted. |
| `--mem <pct>` | No | Current memory utilisation 0–100. Prompted when omitted. |
| `--req-rate <n>` | No | Requests per second (or per minute). Prompted when omitted. |
| `--response-time <ms>` | No | P95 or average response time in milliseconds. Prompted when omitted. |
| `--instances <n>` | No | Current running instance count. Prompted when omitted. |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse the analysis JSON response | `brew install jq` / `apt install jq` |

**Project files consumed:**

None — the command is self-contained. Metrics are supplied as flags or via
interactive prompts. A report file is written to `/tmp/` by the script.

## Backing script

**Script**: `~/.claude/scripts/ops-scaling.sh`

**Inputs:** `--full` (orchestrates all sections); individual section flags
`--gather`, `--analyze`, `--report`. Metric flags `--cpu`, `--mem`,
`--req-rate`, `--response-time`, `--instances` accepted at any section. Add
`--raw` to bypass JSON formatting for debugging.

**Outputs (structured JSON):**

- `next_action` ∈ {`display_summary`, `fix_error`}
- `analysis.recommendation` — `Horizontal Scaling` | `Vertical Scaling`
- `analysis.bottleneck` — primary limiting resource (`CPU`, `Memory`, `Network`, `Mixed`)
- `analysis.recommended_instances` — target instance count (horizontal) or `n/a` (vertical)
- `report_path` — `/tmp/ops-scaling-<timestamp>.md`

**Invocation surface:**

```bash
~/.claude/scripts/ops-scaling.sh --full \
  --cpu 85 --mem 70 --req-rate 500 --response-time 300 --instances 3
~/.claude/scripts/ops-scaling.sh --raw --full    # debug
~/.claude/scripts/ops-scaling.sh --gather        # section: collect metrics interactively
~/.claude/scripts/ops-scaling.sh --analyze       # section: run decision algorithm only
~/.claude/scripts/ops-scaling.sh --report        # section: render report from analysis
~/.claude/scripts/ops-scaling.sh --raw --gather  # debug a specific section
```

## How it works

1. **Gather** — script collects the five metrics, either from CLI flags or by
   prompting the user. Validates that values are in range before proceeding.
2. **Analyze** — decision algorithm compares CPU and memory against saturation
   thresholds, factors in request rate and response time to classify the
   bottleneck, and outputs a recommendation with confidence level and target
   instance count.
3. **Report** — script writes a Markdown report to `/tmp/` summarising inputs,
   the recommendation, rationale, and suggested next steps. Returns
   `display_summary` with the report path.
4. **Present** — LLM surfaces the recommendation (`Horizontal` / `Vertical`),
   the identified bottleneck, and the target instance count. Suggests
   `/ops-capacity` for longer-horizon planning or `/ops-load-test` to validate
   the chosen configuration.

## Example workflows

### Scenario: Post-incident right-sizing

```
/ops-scaling --cpu 92 --mem 55 --req-rate 800 --response-time 450 --instances 2
/ops-capacity        # project how long before the new config saturates
```

Use immediately after a traffic spike to document the scaling decision.

### Scenario: Pre-event capacity check

```
/ops-load-test      # simulate expected traffic
/ops-scaling        # feed load-test metrics into the recommendation engine
```

Run before a product launch to confirm the scaling strategy holds under load.

### Scenario: Recommendation output

```
/ops-scaling --cpu 85 --mem 70 --req-rate 500 --response-time 300 --instances 3
```

```
Scaling Analysis
────────────────────────────────
Inputs:  CPU 85%  Mem 70%  Req/s 500  P95 300ms  Instances 3

Recommendation: Horizontal Scaling
Bottleneck:     CPU (primary) — approaching saturation
Target:         5 instances  (+2 from current 3)

Rationale:
  Memory headroom is adequate; adding instances distributes CPU load
  without requiring a larger instance type. At 500 req/s, 5 instances
  maintain CPU below 55% with 20% headroom for burst.

Report: /tmp/ops-scaling-20260516-142301.md
Next: /ops-capacity to forecast when 5 instances will saturate.
```

## Notes & gotchas

- Metrics are a point-in-time snapshot; run during a representative load
  window for meaningful results. Peaks and troughs give misleading output.
- The script does not read metrics from Prometheus or CloudWatch automatically —
  you supply them. Pair with `/ops-monitoring` to get the numbers first.
- **If it fails:** rerun with `~/.claude/scripts/ops-scaling.sh --raw --gather`
  to see unformatted output and confirm the metrics were parsed correctly.
  Out-of-range values (e.g., CPU > 100) cause validation errors at `--gather`.
