# Task Management Guidelines

Comprehensive guide for capturing, planning, executing, and completing tasks using the V4 documentation system.

**Quick Reference**: See [CLAUDE.md](../CLAUDE.md) for highlights that survive compaction

---

## Table of Contents

1. [Overview](#overview)
2. [Task Lifecycle](#task-lifecycle)
3. [Commands Reference](#commands-reference)
4. [Document Templates](#document-templates)
5. [File Naming Conventions](#file-naming-conventions)
6. [Integration with External Systems](#integration-with-external-systems)
7. [Best Practices](#best-practices)
8. [Quick Reference](#quick-reference)

---

## Overview

### Philosophy

This task management system provides:
- **Unified capture** from multiple sources (email, SMS, Asana, GitLab, GitHub, Cliq)
- **Environment-aware** operations (macOS/work vs WSL/home)
- **Structured documentation** using V4 naming and templates
- **Complete lifecycle** from capture through completion
- **External integration** with task tracking systems
- **Git workflow** integration with branch management
- **Knowledge preservation** with completed documents

### Key Principles

1. **Document everything** - Even simple tasks get documented
2. **Single source of truth** - Task documents are authoritative
3. **External system sync** - Keep Asana/GitLab/GitHub updated
4. **No secrets in docs** - Only references, never actual credentials
5. **Work preservation** - Never lose work (branches, hold state)
6. **Conventional commits** - NO "Co-Authored-By: Claude"

---

## Task Lifecycle

```
CAPTURE → PLAN (optional) → START → WORK → [HOLD (optional)] → CLOSE
```

### Phase 1: Capture

**Command**: `/task-capture [description]` or `/task-fetch`

**Sources**:
- Email (paste or Gmail API)
- SMS (paste or Twilio API)
- Voice transcription
- Asana task (ID or URL)
- GitLab issue (#ID or URL)
- GitHub issue (#ID or URL)
- Cliq message (paste)
- Direct input (type description)

**Process**:
1. Detect source and environment (macOS=work, WSL=home)
2. Fetch content if external source
3. Parse with Opus to extract:
   - Requirements (explicit and inferred)
   - Priority (Critical/High/Medium/Low)
   - Complexity (XS/S/M/L/XL)
   - Ambiguities needing clarification
   - Affected systems/components
4. Create V4 TSK document with next task ID
5. Update DOCUMENT-INDEX.md

**Output**: `docs/active/2026-02/A3F2B9-2602031430-TSK-description.md`

---

### Phase 2: Plan (Optional)

**Command**: `/task-plan [SEQUENCE]`

**When to Use**: Complex tasks requiring investigation or multi-step implementation

**Process**:
1. Load task document
2. Break down into phases with:
   - Objectives
   - Steps
   - Success criteria
   - Time estimates
3. Identify resources, risks, decision points
4. Create PLN document with same task ID

**Output**: `docs/active/2026-02/A3F2B9-2602031430-PLN-description.md`

---

### Phase 3: Start

**Command**: `/task-start [SEQUENCE or path]`

**Process**:
1. Load task document (by sequence or path)
2. Check for on-hold status (offer to resume if held)
3. Verify clean git status (no uncommitted changes)
4. Pull latest from remote (stay current)
5. Create feature branch: `{type}/{issue}-{slug}`
   - Types: feature/, fix/, refactor/, test/, docs/, chore/
   - Slug: first 3-4 words, lowercase, hyphens, max 40 chars
6. Start Docker services (if PROJECT.yaml configured)
7. Run database migrations (if needed)
8. Update dependencies (if changed)
9. Create `.current-task` tracking file

**Branch Naming Examples**:
- `feature/23-add-dark-mode`
- `fix/45-database-connection-error`
- `refactor/67-simplify-auth-logic`

---

### Phase 4: Work

**Developer Actions**:
1. Implement task following requirements
2. Create commits with conventional commit messages
3. NO "Co-Authored-By: Claude" in commits
4. Run tests (coverage >= 80%)
5. Update task document with progress
6. Create PR/MR when ready for review

**Commit Format**:
```
type(scope): description

Body paragraph explaining why this change is needed.

Refs #23
```

**Types**: feat, fix, refactor, test, docs, chore, style, perf

---

### Phase 5: Hold (Optional)

**Command**: `/task-hold [SEQUENCE]`

**When to Use**:
- Waiting for customer response
- Blocked by external dependency
- Need information from another team
- Temporarily paused but want to preserve work

**Process**:
1. Gather hold reason (what are we waiting for?)
2. Capture who we're waiting on and expected date
3. Update TSK document with hold metadata
4. **Automatically create summary document** (SUM) for stakeholder communication
5. Commit all changes to feature branch
6. Merge feature branch to main (work preserved)
7. Push both branch and main to remote
8. Update external systems with "on-hold" label

**Key Features**:
- Branch preserved for later resumption
- **Summary document automatically created** showing hold status and context
- When running `/task-start SEQUENCE` later, system detects hold
- Offers to checkout preserved branch
- All context restored

---

### Phase 6: Close

**Command**: `/task-close [SEQUENCE or none]`

**Completion Options**:
1. **Completed** - Task is done
2. **Deferred** - Task postponed for later

#### If Completed

**Process**:
1. Verify acceptance criteria met
2. Capture progress summary and learnings
3. Update task document with completion details
4. Find related PR/MR and link it
5. Update external systems:
   - Close issue in GitHub/GitLab
   - Mark complete in Asana
   - Post comment with PR link
6. Move ALL task documents (TSK, FND, FIX, etc.) to `docs/completed/`
7. Update DOCUMENT-INDEX.md
8. Commit completed documents
9. Optional: Stop Docker services, delete branch, cleanup

#### If Deferred

**Process**:
1. Capture deferral reason and blocker details
2. Update task document in place (don't move to completed)
3. Document work completed so far
4. Update external systems with "deferred" label
5. Keep branch (may resume later)

---

## Commands Reference

### `/task-capture` - Capture from Any Source

**Purpose**: Convert tasks from any source into structured V4 documents

**Usage**:
```bash
/task-capture Add authentication system
/task-capture                 # Then paste email/SMS/etc
```

**Sources Supported**: Direct input, email, SMS, voice, Asana, Cliq

---

### `/task-fetch` - List Assigned Tasks

**Purpose**: Retrieve all tasks assigned to you

**Usage**:
```bash
/task-fetch                   # All open tasks
/task-fetch --status all      # Open + closed
/task-fetch --project work    # Filter by project
```

**Backend**: Asana (work) or GitLab (home)

---

### `/task-create` - Create in External System

**Purpose**: Create new task in Asana or GitLab

**Usage**:
```bash
/task-create
# Prompted for: title, description, due date, project, priority
```

---

### `/task-start` - Begin Work

**Purpose**: Set up environment and start working on task

**Usage**:
```bash
/task-start 23               # By task ID
/task-start docs/active/.../TSK-file.md
```

---

### `/task-hold` - Pause Work

**Purpose**: Put task on hold while waiting for something

**Usage**:
```bash
/task-hold                   # Current task
/task-hold 23               # Specific sequence
```

**Automatic Actions**:
- ✅ Creates summary document (SUM) showing on-hold status
- Preserves feature branch for later resumption
- Merges work to main branch (no work lost)
- Updates external systems with "on-hold" label

---

### `/task-summary` - Create Summary Document

**Purpose**: Create comprehensive summary document for any task

**Usage**:
```bash
/task-summary 23             # By task ID
/task-summary                # Current task
/task-summary docs/active/.../TSK-file.md
```

**When to Use**:
- Post-completion: Summarize for stakeholders
- On-hold tasks: Communicate status
- Incidents: Create incident summary
- Project reviews: Create retrospective summary
- Ad-hoc: Anytime you want to share task status

**Generates**:
- Summary document (SUM) following task-SUM template
- Non-technical executive-level overview
- Impact analysis and key results
- Learnings and best practices

---

### `/task-code-review` - Create Code Review Document

**Purpose**: Create comprehensive code review document for any task

**Usage**:
```bash
/task-code-review 23             # By task ID
/task-code-review                # Current task
/task-code-review docs/active/.../TSK-file.md
```

**When to Use**:
- Pre-merge review: Review PR/MR before merging
- Post-merge audit: Document review for audit trail
- Security audit: Dedicated security-focused review
- Performance review: Performance-specific analysis
- Architecture review: Complex changes requiring assessment
- Knowledge sharing: Document review patterns for team

**Generates**:
- Code review document (CRV) following task-CRV template
- Code quality assessment with strengths and concerns
- Security vulnerability analysis and best practices
- Performance review and optimization suggestions
- Testing coverage evaluation
- Documentation completeness check
- Requested changes (must fix/recommended/nice to have)
- Approval status and sign-off

---

### `/task-update` - Update Task Plan with Progress

**Purpose**: Update a task's plan document with actual work completed and progress

**Usage**:
```bash
/task-update 23             # By task ID
/task-update                # Current task
/task-update docs/active/.../TSK-file.md
```

**When to Use**:
- Progress checkpoints: After completing phases or milestones
- Blocker identification: When encountering unexpected issues
- Timeline adjustments: When actual progress differs from estimates
- Scope changes: When requirements or approach changes
- Regular sync: Daily or weekly progress updates
- Before closure: Final update before task completion

**Updates**:
- Progress against original objectives
- Work completed since plan creation
- Approach adjustments and changes
- Blockers and mitigations
- Updated timeline and effort estimates
- Remaining work breakdown
- Success criteria status
- Next steps and priorities

---

### `/task-continue` - Resume Work and Validate Tests

**Purpose**: Resume work on a task, ensure tests are written for work done, validate all tests pass, update plan with progress, and commit changes

**Usage**:
```bash
/task-continue                  # Current task
/task-continue 23               # By task ID
/task-continue docs/active/.../TSK-file.md
```

**When to Use**:
- Resume work from where you left off
- Sync progress after completing functionality
- Ensure test coverage for implemented work
- Validate code quality before moving on
- Commit work with comprehensive context
- Next session: Resume with full state preservation
- Continuation sessions: Maintain synchronized documentation

**Validates**:
- ✅ Tests **written** for work done in this session (not just checked)
- ✅ All tests **pass** without failures
- ✅ Coverage meets project minimum standards
- ✅ Tests comprehensively cover implemented functionality

**Updates**:
- Task plan with progress and work summary
- Git commits with detailed context (functionality, tests, coverage, blockers)
- Document index with new/modified files
- Comprehensive progress tracking for future reference

**Important**: Tests are mandatory. Work cannot proceed without:
1. Test files modified/created in this session
2. All tests passing
3. Coverage meeting or exceeding project minimum

---

### `/task-close` - Complete or Defer

**Purpose**: Mark task as finished or postponed

**Usage**:
```bash
/task-close                 # Current task
/task-close 23              # Specific sequence
```

**Automatic Actions** (When Completed):
- ✅ Creates summary document (SUM) for stakeholder communication
- Verifies all acceptance criteria
- Finds and links PR/MR
- Updates external systems
- Moves ALL documents to `docs/completed/`
- Captures learnings and progress

---

## Document Templates

### Template Types Overview

| Type | Code | Purpose | Auto-Created |
|------|------|---------|--------------|
| Task | TSK | Main work item | On capture |
| Fix | FIX | Solution implementation | Manual |
| Findings | FND | Investigation results | Manual |
| Plan | PLN | Planning/investigation | Manual |
| Incident | INC | Production incident | Manual |
| Root Cause | RCA | Post-incident analysis | Manual |
| Deployment | DEP | Deployment guide | Manual |
| Code Review | CRV | Code quality/security review | Manual |
| Summary | SUM | Executive-level overview | On hold/close |
| Response | RSP | Customer communication | Manual |
| Service | SVC | Service documentation | Manual |

### Summary Documents (SUM)

**What Are They?**
Executive-level, non-technical summaries of work items. Automatically created when tasks are put on hold or completed, or manually created for stakeholder communication.

**Smart Incremental Summaries**:
- When previous summary documents exist, new summaries are **incremental** (focus on work since last summary)
- When no previous summaries exist, new summaries are **comprehensive** (summarize all task documents)
- Previous summary documents are **linked** in each new summary for complete history
- This prevents duplicate information and keeps summaries concise and relevant

**Auto-Created When**:
- ✅ Task is put on hold (`/task-hold`) - creates incremental/comprehensive SUM showing on-hold status
- ✅ Task is completed (`/task-close`) - creates incremental/comprehensive SUM showing completion

**Manual Creation**:
- Create anytime with `/task-summary [SEQUENCE]`
- Useful for incident communication, project reviews, or mid-task stakeholder updates
- Automatically detects and links to previous summaries

**Key Sections**:
- Executive summary (2-3 sentences)
- Previous summary documents (links if they exist, or "first summary" message)
- Situation and timeline
- Impact analysis
- What was accomplished (detailed or incremental based on context)
- Key results and learnings
- Going forward plans

**Audience**: Non-technical stakeholders, executives, project managers

**Summary Type Indicator**:
- **Comprehensive (initial summary)** - First summary for the task, covers everything
- **Incremental (since last summary)** - Builds on previous summaries, focuses on new work

### Code Review Documents (CRV)

**What Are They?**
Comprehensive code quality and security reviews of pull requests, merge requests, or branches. Created manually to document code assessments for audit trails, pre-merge review, or knowledge sharing.

**Review Types**:
- **Peer review** - General code quality and patterns
- **Security audit** - Security vulnerability analysis
- **Performance review** - Optimization opportunities
- **Architecture review** - Complex changes and design patterns
- **Full comprehensive review** - All aspects covered

**Manual Creation**:
- Create anytime with `/task-code-review [SEQUENCE]`
- Automatically detects current PR/MR from branch
- Can review specific PR/MR by providing URL
- Auto-analyzes PR/MR diff and files changed

**Key Sections**:
- What was reviewed (PR/MR reference, scope, files changed)
- Summary assessment (code quality, security, performance, testing, documentation)
- Code quality review (architecture, design, patterns)
- Security review (vulnerabilities, best practices)
- Performance review (efficiency, load/scale)
- Testing review (coverage, test quality, gaps)
- Documentation review (code docs, type safety)
- Requested changes (blocking/recommended/nice to have)
- Approval status and sign-off by reviewers

**Audience**: Development team, reviewers, architects, security team

**Review Metadata**:
- **Reviewer**: GitHub handle or name of reviewer
- **Review Duration**: Time spent reviewing
- **Issues Found**: Count by severity (critical/high/medium/low)
- **Previous Reviews**: Links to earlier reviews of same task

### Document Template Details

See templates folder (`~/.claude/templates/task-*.md`) for full structures:
- `task-TSK.md` - Main task template
- `task-FIX.md` - Fix implementation
- `task-FND.md` - Investigation findings
- `task-PLN.md` - Planning document
- `task-INC.md` - Incident report
- `task-RCA.md` - Root cause analysis
- `task-DEP.md` - Deployment guide
- `task-CRV.md` - Code review (comprehensive quality/security assessment)
- `task-SUM.md` - Executive summary (used for auto-created summaries)
- `task-RSP.md` - Communication document
- `task-SVC.md` - Service documentation

---

## File Naming Conventions

### Task Document Format

```
<TASK_ID>-<DATETIME>-<TYPE>-<description>.md
```

**Components**:
- **TASK_ID**: 6 uppercase hex chars (e.g. A3F2B9), computed from datetime+description
- **DATETIME**: YYMMDDHHMM (2602031430 = Feb 3, 2026 14:30)
- **TYPE**: TSK|FIX|FND|PLN|INC|RCA|DEP|SUM|RSP|SVC
- **description**: first-3-4-words-lowercase-hyphens (max 40 chars)

**Examples**:
```
A3F2B9-2602031430-TSK-add-user-authentication.md
0023-2602031500-PLN-investigate-auth-options.md
0023-2602031600-FIX-implement-jwt-authentication.md
```

---

### Document Storage Structure

```
docs/
├── active/                          # Work in progress
│   ├── 2026-02/                  # Range folder
│   │   ├── 0001-2602031430-TSK-feature-name.md
│   │   └── 0023-2602031500-PLN-investigation-plan.md
│   └── 0100-0199/
│
├── completed/                       # Finished work
│   ├── 2026-02/
│   │   └── 0001-2602031500-TSK-feature-name.md
│   └── 0100-0199/
│
├── reference/                       # Reusable docs
│   └── SVC-auth-service.md
│
├── SEQUENCE-TRACKER.md             # Auto-generated work item index
└── DOCUMENT-INDEX.md               # Index of all documents
```

---

## Integration with External Systems

### Environment Detection

**Work (macOS)**:
- Primary: Asana
- Secondary: GitHub
- Auth: `~/.asana-token`, `gh auth`

**Home (WSL)**:
- Primary: GitLab
- Secondary: Asana (if configured)
- Auth: `~/.gitlab-token`, `~/.asana-token`

---

### PROJECT.yaml Configuration

```yaml
task_management:
  backend: asana              # or gitlab
  asana:
    workspace_id: "123456"
    default_project: "Engineering"
  gitlab:
    project_id: "group/project"
    default_labels:
      - "task"
      - "engineering"
```

---

### Authentication Setup

#### Asana (Work)
```bash
# Get PAT from Asana Settings → Apps → Developer Apps
echo "YOUR_TOKEN" > ~/.asana-token
chmod 600 ~/.asana-token
```

#### GitLab (Home)
```bash
# Get PAT from GitLab Settings → Access Tokens
echo "YOUR_TOKEN" > ~/.gitlab-token
chmod 600 ~/.gitlab-token
```

---

## Best Practices

### Task Capture

1. **Always use Opus** for parsing complex descriptions
2. **Document the source** - Email, SMS, Asana, GitHub, GitLab
3. **Infer priority from multiple signals** - urgency, deadline, source, impact
4. **Identify ALL ambiguities** - Better to over-clarify than assume

### Task Lifecycle

1. **Create TSK on capture** - Document all work
2. **Create PLN if needed** - Complex tasks benefit from planning
3. **Start branch only when ready** - Don't start until you can focus
4. **Commit frequently** - Small, meaningful commits
5. **Update progress log** - Timestamped notes in TSK document
6. **Link PR in completion** - Easy traceability
7. **Capture learnings** - What went well, what to improve
8. **Auto-summaries created** - SUM documents generated automatically on hold/close
9. **Manual summary anytime** - Use `/task-summary` for ad-hoc stakeholder communication

### Branch Management

1. **One branch per sequence** - Don't reuse branches
2. **Follow naming convention** - `type/issue-slug` (max 63 chars)
3. **Rebase from main before PR** - Keep history clean
4. **No force pushes** - Unless explicitly requested
5. **Preserve on hold** - Don't delete branches marked on-hold
6. **Delete after merge** - Clean up merged feature branches

### Git Commits

1. **NO "Co-Authored-By: Claude"** - CRITICAL: Never add AI attribution
2. **Conventional commits** - `type(scope): description`
3. **Single purpose per commit** - One logical change
4. **Link to task** - Reference issue in body: `Refs #23`
5. **Squash before PR** - Clean history

### External System Sync

1. **Always capture source** - GitHub/GitLab/Asana URL in task document
2. **Update on state changes** - Hold, defer, complete
3. **Post completion comment** - Include PR link and summary
4. **Add appropriate labels** - "on-hold", "deferred", "completed"
5. **Close when done** - Mark complete in external system

---

## Quick Reference

### Commands Cheat Sheet

```bash
# ===== LIST & FETCH =====
/task-fetch                   # Fetch from backend

# ===== PARSE & CAPTURE =====
/task-capture #123            # Parse GitHub/GitLab issue
/task-capture https://...     # Parse from URL
/task-capture [description]   # Capture direct input

# ===== CREATE =====
/task-create                 # Create in Asana/GitLab

# ===== LIFECYCLE =====
/task-start 23               # Start by sequence
/task-hold                   # Hold current task (auto-creates summary)
/task-close                  # Close current task (auto-creates summary)

# ===== SUMMARY & COMMUNICATION =====
/task-summary 23             # Create summary document for task
/task-summary                # Create summary for current task
```

---

### File Naming Quick Reference

```
Format: <TASK_ID>-<DATETIME>-<TYPE>-<description>.md

Components:
- TASK_ID: 6 uppercase hex chars (000000-FFFFFF)
- DATETIME: YYMMDDHHMM
- TYPE: TSK|FIX|FND|PLN|INC|RCA|DEP|SUM|RSP|SVC
- description: first-3-4-words-lowercase-hyphens (max 40 chars)

Examples:
- A3F2B9-2602031430-TSK-add-user-authentication.md
- 0023-2602031500-PLN-investigate-auth-options.md
```

---

### Branch Naming Quick Reference

```
Format: {type}/{issue}-{slug}

Types: feature/, fix/, refactor/, test/, docs/, chore/

Examples:
- feature/23-add-dark-mode
- fix/45-database-connection-error
```

---

### Priority Determination

**Critical (P0)**: Urgent, production issue, immediate
- Keywords: urgent, critical, ASAP, production down
- Deadline: Today
- Impact: Service down, data loss, security breach

**High (P1)**: Important, this week
- Keywords: important, high priority
- Deadline: This week
- Impact: Blocking work, customer-facing

**Medium (P2)**: This sprint/month
- Keywords: should, would be good
- Deadline: This month
- Impact: Improvement, tech debt

**Low (P3)**: Backlog
- Keywords: nice to have, someday
- Deadline: No deadline
- Impact: Minor improvement

---

## See Also

- **CLAUDE.md**: Quick reference highlights
- **SEQUENCE-TRACKER.md**: Next available task ID
- **DOCUMENT-INDEX.md**: Index of all task documents
- **PROJECT.yaml**: Project-specific configuration
- **Templates**: `~/.claude/templates/task-*.md`
- **Commands**: `~/.claude/commands/task*.md`

---

**Last Updated**: 2026-02-05
**Maintained By**: Claude Code Task Management System
