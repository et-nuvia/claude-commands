# Command Catalog

Every slash command has a dedicated wiki page under
[`docs/wiki/commands/`](https://github.com/et-nuvia/claude-commands/tree/main/docs/wiki/commands).
Each page follows the same structure (see
[`_TEMPLATE.md`](https://github.com/et-nuvia/claude-commands/blob/main/docs/wiki/commands/_TEMPLATE.md)):
YAML frontmatter → lede → optional config callout → When to use it · Usage ·
Arguments · Dependencies · Backing script · How it works · Example workflows ·
Notes & gotchas.

> **Tip.** Read the frontmatter first. `requires_project_yaml`,
> `project_yaml_fields`, `mutates`, `destructive`, and `runtime` answer most
> pre-flight questions without scrolling.

---

## Task Lifecycle

Capture → plan → start → work → hold/resume → close. Most require
`PROJECT.yaml` with `task_management.*` fields.

- [`/task-capture`](commands/task-capture.md) — Capture tasks from email, SMS, voice, or direct input
- [`/task-fetch`](commands/task-fetch.md) — List tasks assigned to you in Asana/GitLab
- [`/task-start`](commands/task-start.md) — Create branch/worktree, sync tracker, boot environment
- [`/task-plan`](commands/task-plan.md) — Break a task into a plan with subtasks and estimates
- [`/task-design`](commands/task-design.md) — Interactive design brainstorming session, produces a DSN doc
- [`/task-continue`](commands/task-continue.md) — Resume work, write tests, validate, update plan, commit
- [`/task-audit`](commands/task-audit.md) — Audit task progress, coverage, and project-wide impact
- [`/task-hold`](commands/task-hold.md) — Pause while waiting on a dependency; preserves the branch
- [`/task-resume`](commands/task-resume.md) — Resume an on-hold or completed task with new input
- [`/task-close`](commands/task-close.md) — Complete or defer; updates external systems and cleans up
- [`/task-summary`](commands/task-summary.md) — Generate the executive SUM document
- [`/task-code-review`](commands/task-code-review.md) — Generate the CRV code/security review document

## Deploy

Deployment lifecycle from risk analysis through staging and production
promotion. `deploy-to-prod` is destructive.

- [`/deploy-risk`](commands/deploy-risk.md) — Score deployment risk; writes an RSK document
- [`/deployment-config`](commands/deployment-config.md) — Show/validate the deployment config from PROJECT.yaml
- [`/deploy-to-stage`](commands/deploy-to-stage.md) — Stage deploy with merge, smoke, and E2E
- [`/deploy-to-prod`](commands/deploy-to-prod.md) — **Destructive.** Prod deploy with promotion, smoke, auto-rollback
- [`/deploy-ansible`](commands/deploy-ansible.md) — Run Ansible playbooks against an environment

## Infrastructure (Terraform)

Plan → apply → verify → drift → destroy. `infra-apply` and `infra-destroy`
are destructive.

- [`/infra-plan`](commands/infra-plan.md) — Preview infrastructure changes
- [`/infra-apply`](commands/infra-apply.md) — **Destructive.** Apply a plan to live infrastructure
- [`/infra-verify`](commands/infra-verify.md) — Confirm infra is linked and accessible
- [`/infra-drift`](commands/infra-drift.md) — Detect drift between code and live state
- [`/infra-destroy`](commands/infra-destroy.md) — **Destructive.** Tear down Terraform-managed resources

## Database

Backup, restore, performance, schema, user audit. `db-restore` and
`db-upgrade` are destructive.

- [`/db-backup-verify`](commands/db-backup-verify.md) — Verify backup integrity and test restoration
- [`/db-restore`](commands/db-restore.md) — **Destructive.** Restore a database from backup
- [`/db-performance`](commands/db-performance.md) — Diagnose slow queries, indexes, configuration
- [`/db-upgrade`](commands/db-upgrade.md) — **Destructive.** Plan and execute major version upgrades
- [`/db-schema-sync`](commands/db-schema-sync.md) — Detect schema changes and sync to Open Metadata
- [`/db-user-audit`](commands/db-user-audit.md) — Audit DB users, roles, and permissions

## Audit (Read-only Scorecards)

Two-phase: deterministic scan + LLM analysis. All read-only.

- [`/pipeline-audit`](commands/pipeline-audit.md) — Score CI/CD pipeline against project + industry standards
- [`/docker-audit`](commands/docker-audit.md) — Score Docker/Compose against project standards
- [`/makefile-audit`](commands/makefile-audit.md) — Score Makefile implementation against the standard
- [`/testing-audit`](commands/testing-audit.md) — Score test implementation against standards
- [`/security-audit`](commands/security-audit.md) — Vulnerabilities, compliance, secrets, access
- [`/network-audit`](commands/network-audit.md) — Capture and analyze network activity (HAR) via Playwright

## RCA / Incident Response

Sequential protocol: triage → timeline → analyze → PIR. All write incident
documents.

- [`/rca-triage`](commands/rca-triage.md) — Initial triage, assessment, and INC document
- [`/rca-timeline`](commands/rca-timeline.md) — Reconstruct event sequence from logs
- [`/rca-analyze`](commands/rca-analyze.md) — 5 Whys root cause analysis
- [`/rca-pir`](commands/rca-pir.md) — Post-incident review and close-out

## Git Operations

Local git + GitHub/GitLab API wrappers.

- [`/git-commit`](commands/git-commit.md) — Split changes into single-purpose conventional commits
- [`/git-merge`](commands/git-merge.md) — Merge a source branch into a target branch
- [`/git-rebase`](commands/git-rebase.md) — Rebase with validation and conflict handling
- [`/create-pr`](commands/create-pr.md) — Open a PR with summary and test plan
- [`/review-pr`](commands/review-pr.md) — AI-powered PR/MR review with security scan

## Ops / Platform

Monitoring, scaling, capacity, cost, load. Mostly read-only.

- [`/ops-monitoring`](commands/ops-monitoring.md) — Configure Prometheus, Grafana, alerts
- [`/ops-scaling`](commands/ops-scaling.md) — Recommend horizontal vs vertical scaling
- [`/ops-capacity`](commands/ops-capacity.md) — Forecast resource needs from growth trends
- [`/ops-cost`](commands/ops-cost.md) — Analyze cloud costs and suggest optimizations
- [`/ops-load-test`](commands/ops-load-test.md) — Plan and run load tests (k6, Locust, JMeter)

## Code Quality / Dev Tooling

Thin, single-phase wrappers around tools.

- [`/format`](commands/format.md) — Auto-format with the project's configured formatter
- [`/refactor`](commands/refactor.md) — Refactor with session continuity and validation
- [`/test-tdd`](commands/test-tdd.md) — Generate failing tests for the TDD red phase
- [`/docs-verify`](commands/docs-verify.md) — Update docs to match code behavior
- [`/cleanproject`](commands/cleanproject.md) — Clean dev artifacts while preserving working code
- [`/add-dependency`](commands/add-dependency.md) — Add a dep with license + security scan
- [`/upgrade-dependencies`](commands/upgrade-dependencies.md) — Upgrade all deps to latest compatible
- [`/ci-lint-local`](commands/ci-lint-local.md) — Pre-push validation of CI/Docker/Compose configs

## Generators / Scaffolders

Produce file artifacts.

- [`/dockerfile-build`](commands/dockerfile-build.md) — Generate a hardened multi-stage Dockerfile
- [`/makefile-init`](commands/makefile-init.md) — Generate hierarchical Makefiles
- [`/pipeline-create`](commands/pipeline-create.md) — Generate GitHub Actions or GitLab CI pipeline
- [`/review-implement`](commands/review-implement.md) — Implement fixes from a review/task list

## Project / Config Management

Read and write project-level configuration.

- [`/project-config`](commands/project-config.md) — Manage PROJECT.yaml (init/show/validate)
- [`/project-context`](commands/project-context.md) — Compact structural summary of the project
- [`/setup-secrets`](commands/setup-secrets.md) — Set up Infisical project, folders, and `.secrets/`
- [`/rotate-secret`](commands/rotate-secret.md) — Manage secret rotation with reminders

## Architecture

Discover deepening candidates, grill them, explore interfaces. Produces ARC
documents and ADRs; updates PROJECT-KNOWLEDGE.md.

- [`/arch-explore`](commands/arch-explore.md) — Find codebase-wide architectural deepening candidates
- [`/arch-grill`](commands/arch-grill.md) — Grill a candidate; update PROJECT-KNOWLEDGE.md; write ADRs
- [`/arch-interfaces`](commands/arch-interfaces.md) — Explore alternative interface shapes via parallel sub-agents

## Outliers / Specialized

Commands that don't fit a larger group.

- [`/contributing`](commands/contributing.md) — Project onboarding and contribution strategy
- [`/plan-progress`](commands/plan-progress.md) — Check plan progress; mark items complete
- [`/plan-mitigate-risks`](commands/plan-mitigate-risks.md) — Plan and implement deployment risk mitigations from an RSK doc
- [`/analyze-conversations`](commands/analyze-conversations.md) — Mine Claude transcripts for patterns
- [`/training-videos`](commands/training-videos.md) — Produce training videos with synchronized voiceover
- [`/praxis-contract`](commands/praxis-contract.md) — Query the Praxis API for endpoint contracts
- [`/todos-to-issues`](commands/todos-to-issues.md) — Convert TODO comments to GitHub/GitLab issues

---

## Catalog generation

This page is maintained by hand for now. Each command page carries machine-
readable YAML frontmatter (`command`, `group`, `backing_script`, `mutates`,
`runtime`, `destructive`, `requires_project_yaml`, `project_yaml_fields`,
`requires_project_knowledge`, `project_knowledge_sections`) so a future
`scripts/build-catalog.sh` can regenerate this index from the source pages.
