# Command Pattern Catalog

Reference of recurring patterns across commands, identified during Phase 2 analysis of the top 20 most complex commands. Use these patterns when migrating commands to the "smart scripts, simple commands" architecture.

---

## 1. Status Handling Patterns

### Pattern A: Simple Status Check (most common)
Scripts return `status` + `next_action`. Command only needs two extractions.

**Current (anti-pattern)**:
```bash
RESULT=$(~/.claude/scripts/foo.sh)
STATUS=$(echo "$RESULT" | jq -r '.status')
case "$STATUS" in
  success)
    FIELD1=$(echo "$RESULT" | jq -r '.data.field1')
    FIELD2=$(echo "$RESULT" | jq -r '.data.field2')
    # 20 lines of logic
    ;;
  error)
    ERROR=$(echo "$RESULT" | jq -r '.message')
    # 10 lines of error handling
    ;;
esac
```

**Target**:
```bash
RESULT=$(~/.claude/scripts/foo.sh)
STATUS=$(echo "$RESULT" | jq -r '.status')
NEXT_ACTION=$(echo "$RESULT" | jq -r '.next_action')
MESSAGE=$(echo "$RESULT" | jq -r '.message')
```
Script returns `next_action` that tells the LLM exactly what to do. No case statement needed.

### Pattern B: Multi-Step Workflow
Commands that orchestrate multiple script calls in sequence.

**Used by**: deploy-to-stage, deploy-to-prod, task-start, task-close, release

**Target**: Each step returns `next_action`. Command documents the flow:
1. Call step 1 → follow `next_action`
2. Call step 2 → follow `next_action`
3. etc.

### Pattern C: Needs-Decision Response
Script can't proceed without user input.

**Used by**: task-start (branch exists), task-resume (multiple matches), task-capture (ambiguous source)

**Target**: Script returns `next_action: "needs_decision"` with `data.options[]` for the LLM to present to the user.

---

## 2. next_action Patterns

### Common Values (reuse when they fit)

| next_action | Meaning | Used by |
|-------------|---------|---------|
| `display_summary` | Show results to user | Most commands on success |
| `confirm_action` | Ask user before proceeding | deploy-to-prod, infra-apply |
| `fix_error` | Show error, suggest fix | Universal error path |
| `needs_decision` | Present options to user | task-start, task-resume |
| `sync_external` | Update Asana/GitLab/GitHub | task-close, task-hold, task-create |
| `run_tests` | Execute test suite | task-continue, deploy-to-stage |
| `create_document` | Generate a V4 document | deploy-risk, task-summary, task-code-review |
| `resolve_conflicts` | Handle merge conflicts | deploy-to-stage, git-merge |
| `retry_with_fix` | Fix issue and retry | Pipeline failures |
| `none` | No further action needed | Informational queries |

### Domain-Specific Values
- Deployment: `promote_image`, `run_smoke_tests`, `rollback`, `tag_release`
- Infrastructure: `apply_plan`, `review_changes`, `target_resource`
- Security: `remediate_vulnerability`, `review_findings`

---

## 3. Platform Routing Pattern

**Affected commands**: create-pr, review-code, review-mr, review-pr, task-code-review, pipeline-setup

**Anti-pattern**: Commands contain `if github... elif gitlab...` blocks.

**Target**: Scripts detect platform from PROJECT.yaml:
```bash
PLATFORM=$(yq e '.git.platform' PROJECT.yaml 2>/dev/null || echo "github")
```
Script handles platform-specific API calls internally. Command is platform-agnostic.

---

## 4. Configuration Loading Pattern

**Affected commands**: All commands that read PROJECT.yaml values.

**Anti-pattern**: Commands contain multiple `yq` calls or expect the LLM to read PROJECT.yaml.

**Target**: Scripts auto-read PROJECT.yaml in their preamble (lines 10-40):
```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [[ -f "${PROJECT_ROOT}/PROJECT.yaml" ]]; then
    CONFIG_VAR=$(yq e '.path.to.value' "${PROJECT_ROOT}/PROJECT.yaml" 2>/dev/null || echo "default")
fi
```

---

## 5. Document Generation Pattern

**Affected commands**: deploy-risk, task-summary, task-code-review, task-audit, rca-*

**Anti-pattern**: Commands contain document templates with variable substitution.

**Target**: Scripts generate documents using `new-doc.sh` and templates. Command just calls the script and tells user what was created.

---

## 6. Scoring/Analysis Pattern

**Affected commands**: task-verify, deploy-risk, db-performance, security-patch

**Anti-pattern**: Commands contain scoring matrices, weighted calculations, if/elif chains for grades.

**Target**: Scripts compute scores internally and return:
```json
{
  "next_action": "display_summary",
  "data": {
    "score": 85,
    "grade": "B+",
    "recommendation": "READY",
    "details": { "category1": 90, "category2": 80 }
  }
}
```

---

## 7. Integration Patterns

### Asana Sync
**Used by**: task-create, task-close, task-hold, task-update, task-fetch

Commands call MCP tools directly (Asana MCP). This stays in the command since MCP is LLM-invoked.
Scripts handle everything else (data preparation, status mapping).

### Pipeline Monitoring
**Used by**: deploy-to-stage, deploy-to-prod, release

Scripts call `pipeline-watch.sh`, `pipeline-status.sh`. Commands document when to check.

### Health Checks
**Used by**: deploy-to-stage, deploy-to-prod

Scripts call `check-health.sh`, `check-deployed-version.sh`. Commands document pass/fail handling.

---

## 8. Priority Categorization (All 100 Commands)

### P0 - Highest Impact (2 commands)
deploy-to-stage, deploy-to-prod

### P1 - Highest Usage (13 commands)
task-capture, task-close, task-code-review, task-continue (done), task-create,
task-execute, task-fetch, task-hold, task-resume,
task-start, task-summary, task-update, task-verify
<!-- task-risk merged into deploy-risk (commit 862e41c) -->


### P2 - High Usage (12 commands)
create-pr, deploy-ansible, deploy-risk, git-commit, git-merge, git-rebase,
task-plan, refactor, release, review-code, review-mr, review-pr

### P3 - Database (5 commands)
db-backup-verify, db-performance, db-restore, db-upgrade, db-user-audit

### P3 - Infrastructure (5 commands)
infra-apply, infra-destroy, infra-drift, infra-plan, infra-verify

### P3 - Operations (5 commands)
ops-capacity, ops-cost, ops-load-test, ops-monitoring, ops-scaling

### P3 - Security (6 commands)
security-access-review, security-compliance, security-patch, security-scan,
security-testing, security-user-audit

### P3 - Pipeline (4 commands)
pipeline-create, pipeline-optimize, pipeline-security, pipeline-setup

### P3 - Testing (6 commands)
test, test-e2e, test-run, test-smoke, test-smoke-eval, test-tdd

### P3 - RCA (4 commands)
rca-analyze, rca-pir, rca-timeline, rca-triage

### P3 - Planning (4 commands)
plan-mitigate-risks, plan-parse-issue, plan-product, task-audit

### P3 - Documentation & Code (8 commands)
docs, docs-verify, document-api, implement, review-implement, contributing,
makefile-init, dockerfile-build

### P3 - Utility (10 commands)
add-dependency, cleanproject, docker-hardening, explain-like-senior, find-todos,
fix-imports, fix-todos, format, generate-changelog, rotate-secret

### P3 - Simple/Minimal (9 commands)
execute-tasks, make-it-pretty, plan-product, predict-issues, remove-comments,
scaffold, session-end, session-start, understand

### P3 - Standalone (6 commands)
deployment-config, project-config, training-videos, todos-to-issues,
upgrade-dependencies, undo, review

**Total**: 2 (P0) + 14 (P1) + 12 (P2) + 72 (P3) = 100 commands
