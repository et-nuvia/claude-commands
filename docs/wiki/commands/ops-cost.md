---
command: ops-cost
group: ops
backing_script: ~/.claude/scripts/ops-cost.sh
mutates: []
runtime: ~45-120s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /ops-cost

Inspects the active cloud provider, inventories running resources (instances,
databases, NAT gateways, storage), then produces a prioritised list of cost
optimisation opportunities with estimated monthly savings. Makes no changes to
infrastructure.

> **Note:** This command uses Opus for cost analysis — expect slightly higher
> latency and cost compared to other ops commands.

---

## When to use it

- Monthly cloud bill increased unexpectedly and you need to know why
- Pre-budget review: quantify optimisation opportunities before committing to next quarter's spend
- After a major deployment, to confirm no orphaned resources were left running

## Usage

```bash
/ops-cost
```

**Common invocations:**

```bash
/ops-cost                         # auto-detect provider; full analysis
/ops-cost --provider aws          # skip detection, target AWS directly
/ops-cost --provider gcp          # target GCP
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--provider <name>` | No | Cloud provider to target (`aws`, `gcp`, `azure`). Auto-detected from CLI config when omitted. |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `aws` | Query AWS Cost Explorer, EC2, RDS, NAT inventory | `brew install awscli` |
| `gcloud` *(optional)* | Query GCP billing and compute inventory | cloud.google.com/sdk |
| `az` *(optional)* | Query Azure Cost Management | docs.microsoft.com/cli/azure |
| `jq` | Parse cost API responses and script JSON | `brew install jq` / `apt install jq` |

**Project files consumed:**

None — the command is self-contained. Reads cloud CLI config/credentials from
the environment. Report is written to `/tmp/` by the script.

## Backing script

**Script**: `~/.claude/scripts/ops-cost.sh`

**Inputs:** `--full` (orchestrates all sections); section flags `--detect`,
`--gather`, `--analyze`, `--report`. `--gather` accepts `--provider <name>`.
`--report` accepts `--provider`, `--total-cost`, `--instances`, `--dbs`,
`--nats`. Add `--raw` to bypass JSON formatting.

**Outputs (structured JSON):**

- `next_action` ∈ {`display_summary`, `fix_error`}
- `--detect` → `provider` (`aws` | `gcp` | `azure` | `unknown`), `authenticated`
- `--gather` → `resource_inventory{instances, databases, nat_gateways, storage_buckets}`, `total_monthly_cost`
- `--analyze` → `recommendations[]` each with `title`, `category`, `estimated_savings_low`, `estimated_savings_high`, `effort` (`low` | `medium` | `high`)
- `report_file` — `/tmp/ops-cost-<timestamp>.md`

**Invocation surface:**

```bash
~/.claude/scripts/ops-cost.sh --full
~/.claude/scripts/ops-cost.sh --detect
~/.claude/scripts/ops-cost.sh --gather --provider aws
~/.claude/scripts/ops-cost.sh --analyze
~/.claude/scripts/ops-cost.sh --report \
  --provider aws --total-cost 5000 --instances 10 --dbs 3 --nats 2
~/.claude/scripts/ops-cost.sh --raw --full      # debug
~/.claude/scripts/ops-cost.sh --raw --detect
~/.claude/scripts/ops-cost.sh --raw --gather
~/.claude/scripts/ops-cost.sh --raw --analyze
```

## How it works

1. **Detect** — script identifies the configured cloud provider from CLI
   credentials and confirms authentication is valid. Returns the provider
   name; fails fast with `fix_error` if credentials are absent.
2. **Gather** — script calls the provider's cost and inventory APIs to collect
   total monthly spend and a resource inventory (instances, RDS clusters, NAT
   gateways, storage buckets). Uses AWS Cost Explorer, GCP Billing API, or
   Azure Cost Management accordingly.
3. **Analyze** — Opus examines the inventory for common waste patterns:
   idle instances, oversized RDS, NAT gateway in single-AZ, orphaned storage,
   reserved-instance coverage gaps. Produces ranked recommendations with
   low/high savings estimates and implementation effort.
4. **Report** — script writes a Markdown cost report and returns `display_summary`
   with the report path.
5. **Present** — LLM surfaces total spend, resource counts, and the top
   recommendations sorted by estimated savings. Suggests implementing quick wins
   (low effort, high savings) first.

## Example workflows

### Scenario: Monthly cost review

```
/ops-cost           # inventory + recommendations
/ops-capacity       # check growth rate against budget trajectory
```

Run at the start of the month; share the report with the team.

### Scenario: Post-deployment orphan check

```
# deploy to staging
/ops-cost --provider aws    # confirm no unexpected resources spun up
```

Catch forgotten dev instances or untagged NAT gateways before the bill arrives.

### Scenario: Cost report output

```
/ops-cost
```

```
Cloud Cost Analysis — AWS
──────────────────────────────────────────────
Total monthly spend:  $4,820
Resources:  10 EC2  ·  3 RDS  ·  2 NAT GW  ·  14 S3 buckets

Top optimisation opportunities:

  1. Right-size 3 underutilised EC2 instances           $280–$420/mo  Effort: low
     (avg CPU < 5%; downgrade t3.large → t3.small)

  2. Convert 2 single-AZ NAT gateways to shared         $180–$240/mo  Effort: medium

  3. Delete 6 untagged S3 buckets (no reads in 90d)     $90–$150/mo   Effort: low

  4. Purchase Reserved Instances for stable workloads    $600–$900/mo  Effort: high

  Estimated total savings:  $1,150–$1,710/mo  (24–35% reduction)

Report: /tmp/ops-cost-20260516-093012.md
```

## Notes & gotchas

- AWS Cost Explorer must be enabled in the account (one-time setup via the
  console). Cost data has a 24-hour lag — today's spend is not visible until tomorrow.
- The `--gather` section makes read-only API calls. No resources are created,
  modified, or deleted at any point.
- On GCP, ensure the `billing.accounts.get` IAM permission is granted to the
  active service account; otherwise detection succeeds but gather fails.
- **If it fails:** rerun with `~/.claude/scripts/ops-cost.sh --raw --detect` to
  confirm the provider and credentials. If detection passes but gather fails,
  try `--raw --gather` — the most common cause is a missing IAM permission for
  the cost API.
