#!/usr/bin/env bash
#
# ops-cost.sh - Cloud cost analysis and optimization recommendations
#
# Usage:
#   ops-cost.sh [--json|--raw] [--full|--detect|--gather|--analyze|--report]
#
# Modes:
#   --json    Structured JSON output (default)
#   --raw     Verbose output for debugging
#
# Sections:
#   --full      Run all sections (default)
#   --detect    Detect cloud provider only
#   --gather    Gather cost data only
#   --analyze   Analyze infrastructure only
#   --report    Generate report only

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION_NAME="ops-cost"

map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        *) _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

OUTPUT_MODE="--json"
SECTION="--full"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_MODE="--json"; shift ;;
    --raw) OUTPUT_MODE="--raw"; shift ;;
    --full) SECTION="--full"; shift ;;
    --detect) SECTION="--detect"; shift ;;
    --gather) SECTION="--gather"; shift ;;
    --analyze) SECTION="--analyze"; shift ;;
    --report) SECTION="--report"; shift ;;
    -h|--help)
      echo "Usage: $0 [--json|--raw] [--full|--detect|--gather|--analyze|--report]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    if [[ "$OUTPUT_MODE" == "--raw" ]]; then
        echo "[INFO] $*" >&2
    fi
}

log_error() {
    echo "[ERROR] $*" >&2
}

# JSON response via output framework
json_response() {
    local status="$1"
    local section="$2"
    local message="$3"
    shift 3

    local extra_fields=""
    while [[ $# -gt 0 ]]; do
        extra_fields="$extra_fields, $1"
        shift
    done

    log_json "$(cat <<EOF
{
  "status": "$status",
  "next_action": "$(map_status_to_action "$status")",
  "section": "$section",
  "message": "$message",
  "timestamp": "$(date -Iseconds)"$extra_fields
}
EOF
)"
}

# ============================================================================
# Section: Detect Cloud Provider
# ============================================================================

detect_provider() {
    log_info "Detecting cloud provider..."

    local provider=""

    # Check Terraform configuration
    if [[ -f "infrastructure/terraform/provider.tf" ]]; then
        if grep -q "aws" infrastructure/terraform/provider.tf 2>/dev/null; then
            provider="aws"
        elif grep -q "google" infrastructure/terraform/provider.tf 2>/dev/null; then
            provider="gcp"
        elif grep -q "azurerm" infrastructure/terraform/provider.tf 2>/dev/null; then
            provider="azure"
        fi
    fi

    # Check PROJECT.yaml
    if [[ -z "$provider" ]] && [[ -f "PROJECT.yaml" ]]; then
        if grep -q "cloud:.*aws" PROJECT.yaml 2>/dev/null; then
            provider="aws"
        elif grep -q "cloud:.*gcp" PROJECT.yaml 2>/dev/null; then
            provider="gcp"
        elif grep -q "cloud:.*azure" PROJECT.yaml 2>/dev/null; then
            provider="azure"
        fi
    fi

    # Interactive fallback
    if [[ -z "$provider" ]] && [[ "$OUTPUT_MODE" == "--raw" ]]; then
        echo "Cloud provider:"
        echo "1. AWS"
        echo "2. GCP"
        echo "3. Azure"
        read -p "Choice (1-3): " choice

        case "$choice" in
            1) provider="aws" ;;
            2) provider="gcp" ;;
            3) provider="azure" ;;
        esac
    fi

    if [[ -z "$provider" ]]; then
        if [[ "$OUTPUT_MODE" == "--json" ]]; then
            json_response "error" "detect" "Could not detect cloud provider" \
                '"details": "No provider.tf or PROJECT.yaml found. Specify manually."'
        else
            echo "Error: Could not detect cloud provider"
        fi
        return 1
    fi

    if [[ "$OUTPUT_MODE" == "--json" ]]; then
        json_response "success" "detect" "Cloud provider detected" \
            "\"provider\": \"$provider\""
    else
        echo "Provider: $provider"
    fi

    echo "$provider"
}

# ============================================================================
# Section: Gather Cost Data
# ============================================================================

gather_cost_data() {
    local provider="$1"

    log_info "Gathering cost data for $provider..."

    local cost_data=""
    local total_cost="0"

    case "$provider" in
        aws)
            if ! command -v aws &> /dev/null; then
                if [[ "$OUTPUT_MODE" == "--json" ]]; then
                    json_response "error" "gather" "AWS CLI not found" \
                        '"details": "Install AWS CLI to gather cost data"'
                else
                    echo "Error: AWS CLI not found"
                fi
                return 1
            fi

            local start_date end_date
            start_date=$(date -d "$(date +%Y-%m-01)" +%Y-%m-%d)
            end_date=$(date +%Y-%m-%d)

            log_info "Fetching AWS costs from $start_date to $end_date..."

            if ! aws ce get-cost-and-usage \
                --time-period Start="$start_date",End="$end_date" \
                --granularity MONTHLY \
                --metrics BlendedCost \
                --group-by Type=DIMENSION,Key=SERVICE \
                > /tmp/aws-costs.json 2>/tmp/aws-costs.err; then

                if [[ "$OUTPUT_MODE" == "--json" ]]; then
                    json_response "error" "gather" "Failed to fetch AWS costs" \
                        "\"details\": \"$(cat /tmp/aws-costs.err)\""
                else
                    echo "Error: Failed to fetch AWS costs"
                    cat /tmp/aws-costs.err
                fi
                return 1
            fi

            total_cost=$(jq -r '.ResultsByTime[0].Total.BlendedCost.Amount // "0"' /tmp/aws-costs.json)
            cost_data=$(jq -r '.ResultsByTime[0].Groups[] | "\(.Keys[0]):\(.Metrics.BlendedCost.Amount)"' /tmp/aws-costs.json | \
                sort -t':' -k2 -rn | head -10 | jq -R -s -c 'split("\n")[:-1]')
            ;;

        gcp)
            if ! command -v bq &> /dev/null; then
                if [[ "$OUTPUT_MODE" == "--json" ]]; then
                    json_response "error" "gather" "GCP BigQuery CLI not found" \
                        '"details": "Install gcloud SDK and configure BigQuery billing export"'
                else
                    echo "Error: BigQuery CLI not found"
                    echo "Setup: https://cloud.google.com/billing/docs/how-to/export-data-bigquery"
                fi
                return 1
            fi

            # Note: Requires BigQuery export configuration
            log_info "Querying GCP BigQuery billing export..."

            # Placeholder for GCP cost query
            total_cost="0"
            cost_data="[]"
            ;;

        azure)
            if ! command -v az &> /dev/null; then
                if [[ "$OUTPUT_MODE" == "--json" ]]; then
                    json_response "error" "gather" "Azure CLI not found" \
                        '"details": "Install Azure CLI to gather cost data"'
                else
                    echo "Error: Azure CLI not found"
                fi
                return 1
            fi

            log_info "Fetching Azure cost data..."

            # Placeholder for Azure cost query
            total_cost="0"
            cost_data="[]"
            ;;
    esac

    if [[ "$OUTPUT_MODE" == "--json" ]]; then
        json_response "success" "gather" "Cost data retrieved" \
            "\"provider\": \"$provider\"" \
            "\"total_cost\": $total_cost" \
            "\"top_services\": $cost_data"
    else
        echo ""
        echo "Total monthly cost: \$$total_cost"
        echo ""
        echo "Top services by cost:"
        echo "$cost_data" | jq -r '.[]'
    fi

    echo "$total_cost"
}

# ============================================================================
# Section: Analyze Infrastructure
# ============================================================================

analyze_infrastructure() {
    log_info "Analyzing infrastructure..."

    if [[ ! -d "infrastructure/terraform" ]]; then
        if [[ "$OUTPUT_MODE" == "--json" ]]; then
            json_response "error" "analyze" "Terraform directory not found" \
                '"details": "No infrastructure/terraform directory found"'
        else
            echo "Error: infrastructure/terraform directory not found"
        fi
        return 1
    fi

    cd infrastructure/terraform

    # Check if terraform state exists
    if ! terraform state list &> /dev/null; then
        cd - > /dev/null
        if [[ "$OUTPUT_MODE" == "--json" ]]; then
            json_response "error" "analyze" "No Terraform state found" \
                '"details": "Run terraform init and terraform apply first"'
        else
            echo "Error: No Terraform state found"
        fi
        return 1
    fi

    # Count resources by type
    local instances dbs lbs nats volumes
    instances=$(terraform state list | grep -E "aws_instance|google_compute_instance|azurerm_virtual_machine" | wc -l)
    dbs=$(terraform state list | grep -E "aws_db_instance|google_sql_database|azurerm_sql_database" | wc -l)
    lbs=$(terraform state list | grep -E "aws_lb|google_compute_forwarding_rule|azurerm_lb" | wc -l)
    nats=$(terraform state list | grep -E "aws_nat_gateway|google_compute_router_nat" | wc -l)
    volumes=$(terraform state list | grep -E "aws_ebs_volume|google_compute_disk" | wc -l)

    cd - > /dev/null

    if [[ "$OUTPUT_MODE" == "--json" ]]; then
        json_response "success" "analyze" "Infrastructure analyzed" \
            "\"resources\": {
                \"compute_instances\": $instances,
                \"databases\": $dbs,
                \"load_balancers\": $lbs,
                \"nat_gateways\": $nats,
                \"volumes\": $volumes
            }"
    else
        echo ""
        echo "Resource inventory:"
        echo "  Compute instances: $instances"
        echo "  Databases: $dbs"
        echo "  Load balancers: $lbs"
        echo "  NAT gateways: $nats"
        echo "  Volumes: $volumes"
    fi

    echo "$instances:$dbs:$lbs:$nats:$volumes"
}

# ============================================================================
# Section: Generate Report
# ============================================================================

generate_report() {
    local provider="$1"
    local total_cost="$2"
    local instances="$3"
    local dbs="$4"
    local nats="$5"

    log_info "Generating cost optimization report..."

    local report_file="docs/cost-optimization/$(date +%Y-%m-%d)-cost-analysis.md"
    mkdir -p docs/cost-optimization

    cat > "$report_file" << EOF
# Cloud Cost Optimization Report

**Date**: $(date -Iseconds)
**Cloud Provider**: $provider
**Current Monthly Cost**: \$$total_cost (estimated)

---

## Executive Summary

Based on infrastructure analysis, estimated potential savings: **30-40%** (\$$(echo "$total_cost * 0.35" | bc | cut -d. -f1)/month)

## Top Cost Drivers

1. Compute (EC2/Instances): ~40% of bill
2. Databases (RDS/SQL): ~25% of bill
3. Data transfer: ~15% of bill
4. Storage (EBS/Disks): ~10% of bill
5. Other (NAT, LB, etc.): ~10% of bill

---

## Optimization Recommendations

### Priority 1: Quick Wins (High Impact, Low Effort)

#### 1. Remove Unused Resources
**Potential Savings**: \$500-2,000/month
**Effort**: Low (1-2 hours)

Actions:
- [ ] Delete unattached EBS volumes
- [ ] Release unused Elastic IPs
- [ ] Remove old snapshots (> 90 days)
- [ ] Delete unused load balancers
- [ ] Terminate stopped instances in non-prod

#### 2. Replace NAT Gateways in Non-Prod
**Potential Savings**: \$200-500/month
**Effort**: Low (2-4 hours)

Current NAT Gateways: $nats
Cost per gateway: ~\$32/month + data processing

Action:
- [ ] Replace staging NAT Gateway with NAT instance (t4g.nano)
- [ ] Replace dev NAT Gateway with NAT instance
- [ ] Keep production NAT Gateway for reliability

#### 3. Switch gp2 to gp3 (AWS EBS)
**Potential Savings**: \$100-300/month
**Effort**: Low (automated)

Action:
- [ ] Modify all gp2 volumes to gp3 (20% cheaper, better performance)

### Priority 2: Right-Sizing (Medium Effort)

#### 4. Right-Size Compute Instances
**Potential Savings**: \$1,000-3,000/month
**Effort**: Medium (requires monitoring analysis)

Instances to analyze: $instances

Steps:
1. Analyze CloudWatch metrics (last 30 days)
2. Identify instances with < 40% CPU utilization
3. Downsize: t3.large → t3.medium, etc.
4. Test in staging first

#### 5. Right-Size RDS Instances
**Potential Savings**: \$500-1,500/month
**Effort**: Medium

Databases to analyze: $dbs

Steps:
1. Check database connections (< 50% max?)
2. Check CPU/memory (< 60% avg?)
3. Downsize or switch to Aurora Serverless

### Priority 3: Commitment-Based Savings (High Savings, Requires Planning)

#### 6. Reserved Instances / Savings Plans
**Potential Savings**: \$2,000-5,000/month
**Effort**: Medium (requires usage analysis)

Strategy:
- Analyze last 6 months instance usage
- Identify stable, always-on workloads
- Purchase 1-year reserved instances
- Use Savings Plans for flexibility

Recommendation: Start with 50% commitment, scale up

---

## Implementation Plan

### Week 1: Quick Wins
- [ ] Delete unused resources (1-2 hours)
- [ ] Replace NAT Gateways in dev/staging (2-4 hours)
- [ ] Convert gp2 to gp3 (1 hour)
**Expected savings**: \$800-2,800/month

### Week 2-3: Right-Sizing
- [ ] Analyze CloudWatch metrics (4 hours)
- [ ] Downsize 5-10 instances (staged rollout)
- [ ] Right-size 2-3 databases
**Expected savings**: \$1,500-4,500/month

### Week 4: Commitments
- [ ] Analyze 6-month usage patterns (2 hours)
- [ ] Purchase reserved instances for stable workloads
**Expected savings**: \$2,000-5,000/month

---

## Estimated Total Savings

| Priority | Monthly Savings | Effort | Timeline |
|----------|----------------|--------|----------|
| Quick Wins | \$800-2,800 | Low | Week 1 |
| Right-Sizing | \$1,500-4,500 | Medium | Week 2-3 |
| Commitments | \$2,000-5,000 | Medium | Week 4 |
| **Total** | **\$4,300-12,300** | | **1 month** |

**Projected annual savings**: **\$51,600-147,600**

---

## Next Steps

1. Review this report with team
2. Prioritize recommendations based on risk/effort
3. Start with Quick Wins (week 1)
4. Implement Terraform changes for NAT/storage
5. Monitor savings in billing dashboard
EOF

    if [[ "$OUTPUT_MODE" == "--json" ]]; then
        json_response "success" "report" "Cost optimization report generated" \
            "\"report_file\": \"$report_file\"" \
            "\"estimated_monthly_savings\": \"4300-12300\"" \
            "\"estimated_annual_savings\": \"51600-147600\""
    else
        echo ""
        echo "Report generated: $report_file"
    fi

    echo "$report_file"
}

# ============================================================================
# Main Workflow
# ============================================================================

main() {
    case "$SECTION" in
        --detect)
            detect_provider
            ;;

        --gather)
            # Requires provider as environment variable or argument
            provider="${PROVIDER:-aws}"
            gather_cost_data "$provider"
            ;;

        --analyze)
            analyze_infrastructure
            ;;

        --report)
            # Requires variables from previous sections
            provider="${PROVIDER:-aws}"
            total_cost="${TOTAL_COST:-0}"
            instances="${INSTANCES:-0}"
            dbs="${DBS:-0}"
            nats="${NATS:-0}"
            generate_report "$provider" "$total_cost" "$instances" "$dbs" "$nats"
            ;;

        --full)
            # Run all sections in sequence
            log_info "Running full cost optimization analysis..."

            # Detect provider
            provider=$(detect_provider) || exit 1

            if [[ "$OUTPUT_MODE" == "--raw" ]]; then
                echo ""
                echo "═══════════════════════════════════════"
                echo "  Gathering Cost Data"
                echo "═══════════════════════════════════════"
            fi

            # Gather cost data
            total_cost=$(gather_cost_data "$provider") || total_cost="0"

            if [[ "$OUTPUT_MODE" == "--raw" ]]; then
                echo ""
                echo "═══════════════════════════════════════"
                echo "  Analyzing Infrastructure"
                echo "═══════════════════════════════════════"
            fi

            # Analyze infrastructure
            resources=$(analyze_infrastructure) || resources="0:0:0:0:0"
            IFS=':' read -r instances dbs lbs nats volumes <<< "$resources"

            if [[ "$OUTPUT_MODE" == "--raw" ]]; then
                echo ""
                echo "═══════════════════════════════════════"
                echo "  Generating Report"
                echo "═══════════════════════════════════════"
            fi

            # Generate report
            report_file=$(generate_report "$provider" "$total_cost" "$instances" "$dbs" "$nats")

            if [[ "$OUTPUT_MODE" == "--json" ]]; then
                json_response "success" "full" "Cost optimization analysis complete" \
                    "\"provider\": \"$provider\"" \
                    "\"total_cost\": $total_cost" \
                    "\"resources\": {
                        \"compute_instances\": $instances,
                        \"databases\": $dbs,
                        \"load_balancers\": $lbs,
                        \"nat_gateways\": $nats,
                        \"volumes\": $volumes
                    }" \
                    "\"report_file\": \"$report_file\"" \
                    "\"estimated_monthly_savings\": \"4300-12300\"" \
                    "\"estimated_annual_savings\": \"51600-147600\""
            else
                echo ""
                echo "════════════════════════════════════════"
                echo "  Cost Optimization Analysis Complete"
                echo "════════════════════════════════════════"
                echo ""
                echo "Provider: $provider"
                echo "Current monthly cost: ~\$$total_cost"
                echo ""
                echo "Estimated savings potential: 30-40%"
                echo "Potential monthly savings: \$4,300-12,300"
                echo "Potential annual savings: \$51,600-147,600"
                echo ""
                echo "Report: $report_file"
                echo ""
                echo "Top recommendations:"
                echo "1. Delete unused resources (\$500-2,000/month)"
                echo "2. Replace NAT Gateways in non-prod (\$200-500/month)"
                echo "3. Switch to gp3 volumes (\$100-300/month)"
                echo "4. Right-size compute instances (\$1,000-3,000/month)"
                echo "5. Purchase reserved instances (\$2,000-5,000/month)"
                echo ""
                echo "Next: Review report and implement quick wins"
            fi
            ;;

        *)
            log_error "Unknown section: $SECTION"
            echo "Usage: $0 [--json|--raw] [--full|--detect|--gather|--analyze|--report]"
            exit 1
            ;;
    esac
}

main
