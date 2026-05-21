# Comparison: Eric's Command/Script System vs obra/superpowers

**Date:** 2026-03-11
**Superpowers version:** 5.0.1 (~77k stars, MIT license)
**Eric's system:** 119 commands, 179+ scripts, BATS test suite

---

## Executive Summary

These are fundamentally different approaches to the same problem: **making AI agents produce better software**.

- **Superpowers** is a **methodology framework** — it tells the agent *how to think* about work (brainstorm → plan → TDD → review → complete). It's lightweight, portable across agents (Claude Code, Cursor, Codex, Gemini CLI), and focused on process discipline.
- **Eric's system** is a **production automation platform** — it tells the agent *how to execute* work through structured bash scripts that handle real-world complexity (Asana sync, deployment pipelines, secrets management, database operations). It's deep, opinionated, and tightly integrated with specific infrastructure.

They barely overlap in implementation but significantly overlap in intent. The best outcome is borrowing ideas from each.

---

## Architecture Comparison

| Aspect | Eric's System | Superpowers |
|--------|--------------|-------------|
| **Core unit** | Bash scripts + markdown commands | Markdown skills (process docs) |
| **Logic location** | Scripts (bash with JSON output) | In the LLM's reasoning (guided by markdown) |
| **Output format** | Structured JSON with `next_action` | Prose/artifacts (specs, plans, code) |
| **State management** | `.current-task`, branch names, PLN docs | Git worktrees, plan files |
| **Integration** | Asana, GitLab, GitHub, Invoice Ninja MCPs | Git worktrees, subagent dispatch |
| **Testing** | BATS test suite for scripts | No tests for the skills themselves |
| **Platform** | Claude Code only | Claude Code, Cursor, Codex, Gemini CLI, OpenCode |
| **Installation** | Manual ~/.claude setup | Plugin marketplace (`/plugin install`) |
| **Scope** | Full SDLC + ops + infrastructure | Development workflow only |

---

## What Eric Has That Is Better

### 1. Deterministic Script Execution (Major Advantage)

Eric's scripts do the heavy lifting in bash, returning structured JSON. The LLM interprets results but doesn't execute logic. This means:
- **Reproducible outcomes** — same inputs produce same outputs regardless of model temperature
- **Testable** — BATS tests validate every script path
- **Debuggable** — `--raw` flag shows exactly what happened
- **No hallucination risk** in execution logic

Superpowers relies entirely on the LLM following prose instructions, which means every execution is probabilistic. There's no way to test that the agent will actually follow the brainstorming process correctly every time.

### 2. Section-Based Resumption (Major Advantage)

Scripts support `--section` flags for granular re-entry:
```bash
task-start.sh --json --verify --task-id ABC123  # Resume from verify step
```

If something fails at step 3 of 6, the LLM can fix the issue and resume from step 3 without re-running steps 1-2. Superpowers has no equivalent — if a plan execution fails mid-task, the agent restarts from scratch or improvises.

### 3. External System Integration (Major Advantage)

Eric's system integrates with:
- **Asana** (task management, custom fields, status sync)
- **GitLab CI / GitHub Actions** (pipeline monitoring, job logs)
- **Invoice Ninja** (time tracking, billing)
- **Infisical / AWS Secrets Manager** (secrets rotation)
- **Docker** (container execution, health checks)
- **Databases** (backup/restore, schema sync, user audit)

Superpowers has zero external integrations. It's purely about the development process within a git repo.

### 4. Production Operations Coverage (Major Advantage)

119 commands covering deployment, infrastructure, incident response, security scanning, database operations, monitoring, capacity planning. Superpowers covers none of this — it stops at "code is written and reviewed."

### 5. PROJECT.yaml Configuration (Advantage)

Single source of truth for project configuration that scripts read automatically. No environment variables to manage, no manual configuration per-project. Superpowers has no project configuration concept.

### 6. Testing Infrastructure (Advantage)

BATS test suite validates script behavior. You can verify that `task-close.sh` returns the right `next_action` for every error path. Superpowers skills are untested markdown — there's no automated way to verify the brainstorming skill actually produces good specs.

### 7. Structured Error Recovery (Advantage)

The `next_action` pattern provides deterministic error handling:
- `fix_error` → debug and retry specific section
- `confirm_action` → ask user for decision
- `resolve_conflicts` → handle merge conflicts
- `sync_asana` → trigger MCP operations

Superpowers error handling is "the agent figures it out" — which sometimes works and sometimes doesn't.

---

## What Superpowers Has That Is Better

### 1. Brainstorming & Design Phase (Major Advantage)

Superpowers' `brainstorming` skill is sophisticated:
- Asks questions **one at a time** (not a wall of questions)
- Proposes 2-3 approaches with trade-offs
- Presents design in sections for incremental approval
- Runs an automated spec review loop before moving on
- Saves a spec document as artifact

Eric's system jumps straight from task capture to planning/execution. There's no structured design thinking phase. The `/task-plan` command exists but it's plan-focused, not design-focused.

**Brainstorm idea:** Add a `task-design` or `task-brainstorm` skill that forces collaborative exploration before creating the PLN document.

### 2. Anti-Rationalization Patterns (Major Advantage)

Superpowers includes tables of thoughts the agent might have that indicate it's about to skip the process:

| Thought | Reality |
|---------|---------|
| "This is just a simple fix" | Simple fixes cause the most bugs |
| "I already know what to do" | Confidence without evidence is dangerous |
| "Tests would slow me down" | Tests prevent rework that's even slower |

This is psychologically clever — it pre-emptively addresses the LLM's tendency to take shortcuts. Eric's system enforces discipline through deterministic scripts rather than persuasion, but there are gaps where the LLM makes judgment calls (e.g., deciding to skip tests, writing sloppy commit messages).

**Brainstorm idea:** Add rationalization guards to CLAUDE.md for known failure modes.

### 3. Subagent-Driven Development with Two-Stage Review (Advantage)

Superpowers' SDD pattern:
1. Dispatch fresh subagent per task (clean context)
2. Subagent implements
3. Spec reviewer subagent checks compliance
4. Code quality reviewer subagent checks craftsmanship
5. Fixes applied, re-reviewed until clean

Eric's system has `/task-code-review` as a manual invocation, not an automatic gate in the execution pipeline. (`/task-feature-review` was previously planned alongside it but has been removed — see commit `e5f0c7b`.) The two-stage review concept — spec compliance + code quality — is still a good separation of concerns even with a single command, since the reviewer subagent prompt can address both axes.

**Brainstorm idea:** Make code review automatic in `/task-continue` after each subtask completion, using subagent dispatch.

### 4. TDD as Iron Law (Advantage)

Superpowers treats TDD as an absolute constraint: "NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST. If you wrote code before the test, delete it and start over."

Eric's CLAUDE.md mentions TDD and has testing requirements, but it's not enforced at the process level. A script could theoretically write code without tests and nothing would stop it until `/task-audit`.

**Brainstorm idea:** Add a TDD enforcement gate to `task-continue.sh` — before allowing code changes, require a failing test commit first.

### 5. Graphviz Flow Diagrams (Minor Advantage)

Skills include decision trees as dot notation digraphs. This gives the LLM an unambiguous visual flow to follow. Eric's commands use prose descriptions which are more prone to misinterpretation.

**Brainstorm idea:** Add flow diagrams to command descriptions for complex multi-branch workflows.

### 6. Platform Portability (Advantage for Adoption, Not for Eric)

Superpowers works across Claude Code, Cursor, Codex, Gemini CLI, and OpenCode. Eric's system is Claude Code-specific. This matters for adoption/community but not necessarily for Eric's personal productivity.

### 7. Session Start Hook (Clever Mechanism)

Superpowers uses a hook to inject the `using-superpowers` meta-skill into every session automatically. This ensures the agent always checks for relevant skills before acting. Eric's system relies on CLAUDE.md which is always loaded, so functionally equivalent — but the hook approach is more modular.

### 8. Lightweight Installation (Advantage for Others)

`/plugin install superpowers` vs. copying 300+ files into ~/.claude. For community adoption, Superpowers wins. For Eric's use case (personal productivity system), this doesn't matter.

---

## What Is Similar

### 1. Plan-Then-Execute Workflow
Both enforce structured planning before implementation:
- **Eric:** `/task-capture` → PLN document → `/task-start` → `/task-continue` (follows plan)
- **Superpowers:** `/brainstorm` → spec → `/write-plan` → `/execute-plan`

Eric's is more automated (scripts track progress), Superpowers is more collaborative (brainstorming phase).

### 2. Git Worktree Usage
Both use git worktrees for isolated work:
- **Eric:** Worktree support in scripts, branch naming conventions
- **Superpowers:** Dedicated `using-git-worktrees` skill with safety checks

### 3. Code Review Integration
Both have code review workflows:
- **Eric:** `/task-code-review`, `/review-code`, `/review-pr`, `/review-mr`
- **Superpowers:** `requesting-code-review` + `receiving-code-review` skills, code-reviewer agent

Superpowers' two-skill approach (requesting vs receiving) is interesting — it separates the act of asking for review from handling feedback.

### 4. Conventional Commits
Both enforce conventional commit format. Eric's is more strictly enforced through scripts (`git-commit.sh`).

### 5. YAGNI / Minimal Changes
Both emphasize not over-engineering:
- **Eric:** "ONLY make changes necessary to accomplish the task"
- **Superpowers:** "YAGNI" as explicit principle in planning

### 6. Verification Before Completion
Both require verification:
- **Eric:** `/task-verify`, `/task-audit` with structured scoring
- **Superpowers:** `verification-before-completion` skill ("No completion claims without fresh evidence")

### 7. Debugging Methodology
Both have systematic debugging:
- **Eric:** `test-diagnose.sh` with structured output, retry budgets
- **Superpowers:** `systematic-debugging` skill (investigate → hypothesize → fix → verify)

Eric's is more tool-driven, Superpowers is more methodology-driven.

---

## Brainstorming: Ideas to Improve Eric's System

### High Impact, Moderate Effort

1. **Add a Design/Brainstorming Phase**
   - New command: `/task-design` between capture and planning
   - Forces exploration of approaches before committing to a plan
   - One question at a time (not a wall), 2-3 approach proposals
   - Saves a DSN (Design) document as artifact
   - PLN document references the approved design

2. **Automatic Code Review Gate in task-continue**
   - After each subtask completion, dispatch a review subagent
   - Two-pass: spec compliance (does it match the PLN?) + code quality
   - Block progress until review passes
   - Add `--skip-review` flag for trivial changes

3. **TDD Enforcement in task-continue**
   - Before allowing production code changes, check for a failing test commit
   - Script verifies: "Is there a test file change in the staging area without corresponding production code?"
   - `next_action: "write_test_first"` if production code detected without test

4. **Anti-Rationalization Guards in CLAUDE.md**
   - Add a "Common Shortcuts to Avoid" section
   - "If you're thinking 'this is too simple for a plan' — it's not"
   - "If you're thinking 'I'll add tests after' — write them now"
   - "If you're thinking 'I know what the error is without reading logs' — read the logs"

### Medium Impact, Low Effort

5. **Decision Flow Diagrams in Commands**
   - Add Graphviz dot notation to complex commands (task-continue, task-close, deploy-to-prod)
   - Gives the LLM unambiguous decision trees
   - Could be generated from existing `next_action` mappings

6. **Spec Review Loop**
   - After creating a PLN document, automatically review it:
     - Are all subtasks small enough (< 30 min)?
     - Does each subtask have clear acceptance criteria?
     - Are dependencies ordered correctly?
   - Script: `plan-review.sh --json --plan-file <path>`

7. **Fresh Context for Complex Tasks**
   - Borrow the "dispatch fresh subagent per task" pattern
   - For subtasks that are architecturally complex, dispatch a subagent with only the relevant context
   - Prevents context pollution from previous subtask work

### Lower Impact, Worth Considering

8. **Skill Metadata (YAML Frontmatter)**
   - Add `name`, `description`, `triggers` frontmatter to commands
   - Enables better auto-discovery ("which command handles deployment risk?")
   - Could power a `/help-find` command

9. **Session Start Context Injection**
   - Hook that runs on session start to inject current task context
   - Auto-loads .current-task, shows progress summary
   - Saves the "what was I working on?" question every session

10. **Parallel Agent Dispatch Skill**
    - When facing 2+ independent problems, explicitly dispatch agents in parallel
    - Eric's system already supports this via Agent tool, but a structured skill could standardize when/how to parallelize

---

## Summary Matrix

| Capability | Eric | Superpowers | Winner |
|-----------|------|-------------|--------|
| Design/brainstorming | Absent | Excellent | Superpowers |
| Planning | Good (PLN docs) | Good (plan files) | Tie |
| TDD enforcement | Mentioned, not enforced | Iron law | Superpowers |
| Execution tracking | Excellent (section-based) | Basic (checklist) | Eric |
| Error recovery | Excellent (next_action) | Ad-hoc | Eric |
| Code review | Manual trigger | Automatic gate | Superpowers |
| External integrations | Extensive | None | Eric |
| Deployment/ops | Comprehensive | None | Eric |
| Testing of the system itself | BATS suite | None | Eric |
| Anti-rationalization | Implicit (scripts enforce) | Explicit (tables) | Superpowers |
| Portability | Claude Code only | 5+ platforms | Superpowers |
| Configuration | PROJECT.yaml | None needed | Eric |
| Debugging methodology | Tool-driven | Process-driven | Tie |
| Verification | Structured scoring | Evidence-based | Tie |
| Community/ecosystem | Personal | 77k stars, marketplace | Superpowers |
| Depth of coverage | Full SDLC + ops | Dev workflow only | Eric |
| Determinism/reliability | High (bash scripts) | Low (LLM-dependent) | Eric |

---

## Bottom Line

Eric's system is **operationally superior** — it handles the full lifecycle from task capture through production deployment with deterministic, testable scripts. Superpowers is **methodologically superior** — it handles the *thinking* phase (design, TDD discipline, review gates) better than anything Eric currently has.

The highest-value improvements would be:
1. **Brainstorming/design phase** (steal from Superpowers)
2. **Automatic code review gates** (steal from Superpowers)
3. **TDD enforcement at the script level** (steal the iron law concept, implement deterministically)
4. **Anti-rationalization guards** (steal the psychology, add to CLAUDE.md)

These four additions would combine Eric's execution strength with Superpowers' process discipline.
