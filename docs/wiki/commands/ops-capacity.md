---
command: ops-capacity
group: ops
backing_script: ~/.claude/scripts/ops-capacity.sh
mutates: []
runtime: ~30-60s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /ops-capacity

Forecasts how long current infrastructure will last before it saturates, given
a growth rate and planning horizon. Input current load, monthly growth
percentage, and how many months to look ahead; output is a month-by-month
table showing when each resource hits its ceiling. Makes no changes to
infrastructure.

> **Note:** This command uses Opus for complex capacity analysis — expect
> slightly higher latency and cost compared to other ops commands.

---

## When to use it

- You need to justify a scaling decision to stakeholders with a written forecast
- After `/ops-scaling` recommends adding instances, to project when the new
  config will itself saturate
- Quarterly capacity planning review before budget cycles

## Usage

```bash
/ops-capacity [metric flags]
```

**Common invocations:**

```bash
/ops-capacity                                               # interactive prompts for all inputs
/ops-capacity --monitor prometheus --load 10000 \
              --rate 5 --months 12                         # fully programmatic
/ops-capacity --load 50000 --rate 8 --months 6            # partial; monitoring system prompted
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--monitor <system>` | No | Monitoring system in use (`prometheus`, `grafana`, `cloudwatch`, `datadog`, `none`). Prompted when omitted. |
| `--load <n>` | No | Current load expressed as users or requests per day. Prompted when omitted. |
| `--rate <pct>` | No | Expected monthly growth rate as a percentage (e.g., `5` for 5%). Prompted when omitted. |
| `--months <n>` | No | Forecast horizon in months. Prompted when omitted. |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse the forecast JSON | `brew install jq` / `apt install jq` |
| `aws` *(optional)* | Pull CloudWatch metrics when `--monitor cloudwatch` | `brew install awscli` |
| `gcloud` *(optional)* | Pull Cloud Monitoring metrics when `--monitor gcp` | cloud.google.com/sdk |

**Project files consumed:**

None — the command is self-contained. Inputs are supplied as flags or via
interactive prompts. A report file is written to `/tmp/` by the script.

## Backing script

**Script**: `~/.claude/scripts/ops-capacity.sh`

**Inputs:** `--full` (orchestrates all sections) with optional metric flags;
section flags `--collect`, `--analyze`, `--report` for targeted runs.
Accepts `--monitor`, `--load`, `--rate`, `--months`. Add `--raw` to bypass
JSON formatting.

**Outputs (structured JSON):**

- `next_action` ∈ {`gather_user_input`, `display_summary`, `fix_error`}
- `gather_user_input.section` ∈ {`collect`, `analyze`} — tells LLM which inputs are still needed
- `forecast_data[]` — month-by-month objects: `month`, `projected_load`,
  `cpu_pct`, `mem_pct`, `saturation_risk` (`low` | `medium` | `high` | `critical`)
- `saturation_month` — first month where any resource hits critical
- `report_path` — `/tmp/ops-capacity-<timestamp>.md`

**Invocation surface:**

```bash
~/.claude/scripts/ops-capacity.sh --full \
  --monitor prometheus --load 10000 --rate 5 --months 12
~/.claude/scripts/ops-capacity.sh --collect
~/.claude/scripts/ops-capacity.sh --analyze --load 10000 --rate 5 --months 12
~/.claude/scripts/ops-capacity.sh --report
~/.claude/scripts/ops-capacity.sh --raw --collect    # debug
~/.claude/scripts/ops-capacity.sh --raw --analyze
~/.claude/scripts/ops-capacity.sh --raw --report
```

## How it works

1. **Collect** — script checks for required inputs. If any are missing, returns
   `gather_user_input` with `section: collect`. LLM asks the user to select a
   monitoring system and provide current load, growth rate, and forecast months,
   then re-calls with the completed flags.
2. **Analyze** — Opus projects load month-by-month using compound growth, maps
   load to resource utilisation percentages, and assigns saturation risk levels.
   Identifies the first month each resource becomes `critical` (≥ 90%
   utilisation).
3. **Report** — script writes a Markdown report containing the forecast table,
   saturation timeline, and recommendations. Returns `display_summary`.
4. **Present** — LLM shows current load, growth rate, and the month-by-month
   table with risk colour-coding. Highlights the saturation month and suggests
   `/ops-scaling` to right-size before that date.

## Example workflows

### Scenario: Post-scaling forecast

```
/ops-scaling --cpu 85 --mem 70 --req-rate 500 --response-time 300 --instances 3
# Act on recommendation: scale to 5 instances
/ops-capacity --load 150000 --rate 10 --months 12
```

After scaling, immediately forecast when the new config will saturate.

### Scenario: Quarterly planning

```
/ops-capacity        # interactive; cover 12-month horizon
```

Run at the start of each quarter and attach the report to the planning doc.

### Scenario: Forecast output

```
/ops-capacity --monitor prometheus --load 10000 --rate 5 --months 6
```

```
Capacity Forecast
──────────────────────────────────────────────
Inputs:  Load 10,000 req/day  Growth 5%/mo  Horizon 6 months
Monitor: prometheus

Month   Projected Load   CPU     Mem     Risk
──────  ───────────────  ──────  ──────  ────────
+1      10,500           52%     61%     low
+2      11,025           55%     64%     low
+3      11,576           58%     68%     medium
+4      12,155           62%     71%     medium
+5      12,763           67%     75%     high
+6      13,401           72%     80%     high

Saturation month: none within 6-month horizon (CPU critical at ~+14 months)

Report: /tmp/ops-capacity-20260516-150802.md
Next: /ops-scaling to evaluate vertical vs horizontal before month 5.
```

## Notes & gotchas

- Growth rate is compounded month-over-month, not linear. A 5% monthly rate
  equals ~80% annual growth — verify the number is realistic before sharing
  the report with stakeholders.
- The model uses Opus for this command. On large forecast horizons (≥ 24 months)
  with complex analysis, latency can reach 60+ seconds.
- The script does not pull live metrics automatically; supply `--load` from your
  monitoring system or run `/ops-monitoring` first to get the current baseline.
- **If it fails:** rerun with `~/.claude/scripts/ops-capacity.sh --raw --collect`
  to confirm inputs parsed correctly, then `--raw --analyze` to isolate the
  calculation failure.
