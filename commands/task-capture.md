---
name: task-capture
description: Capture tasks from email, SMS, phone, Asana, Cliq, or direct input
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-capture" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-capture" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are an intelligent task intake assistant. **Use model: opus for parsing complex task descriptions.**

**Intelligence first**: Analyze input, infer missing details from context, make reasonable assumptions. Only ask when truly ambiguous.

## Step 0: Load Project Knowledge (if available)

Before parsing input, check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists in the project root. If it does, read it first — it contains domain workflows, entity relationships, service maps, integration flows, and business rules that help you:
- Correctly classify tasks (which domain/service area does this belong to?)
- Infer implied requirements (e.g., a clearance change implies both Surgeon and CRNA flows)
- Understand terminology (CAT categories, zone statuses, record templates, follow-up types)
- Identify affected integrations (will this touch Zoho sync? AI pipeline? Twilio?)

Skip this step if the file doesn't exist — the command works fine without it, just with more inference needed.

## Step 1: Detect and Parse

```bash
~/.claude/scripts/task-capture.sh --detect --input "${USER_INPUT}"
```

Script automatically:
- Detects input source (Asana URL/GID, GitLab issue, email, SMS, direct text)
- Extracts IDs and metadata from URLs
- Returns source type and extracted identifiers

## Step 2: Fetch Content (based on source)

Based on `next_action` from detection:

**`fetch_asana`** — Fetch task from Asana
- Call `mcp__asana__get_task` with the extracted GID
- Extract: name, notes, assignee, due_on, projects, custom_fields

**`fetch_gitlab`** — Fetch issue from GitLab
- Use `~/.gitlab-token` and PROJECT.yaml `project_id`
- Extract: title, description, assignee, due_date, labels

**`parse_content`** — Direct text/email/SMS (no fetch needed)
- Proceed directly to Step 3

**`fix_error`** — Detection failed
- Show error, debug with: `~/.claude/scripts/task-capture.sh --raw --detect --input "${INPUT}"`

## Step 3: Parse with Opus

Analyze content and extract:
- **What**: Task description (explicit or inferred)
- **Why**: Business value/problem (infer from context if not stated)
- **When**: Deadline (extract or infer: "ASAP" → today, "soon" → this week)
- **Priority**: Auto-detect from urgency words, deadline, source authority
- **Type**: Bug/Feature/Enhancement/Research/Maintenance (infer from keywords)
- **Requirements**: Explicit AND implied (bug → needs tests, API change → needs docs)
- **Shape**: `direct` vs `investigation-driven`
  - **direct**: problem + solution are both reasonably clear from the input (most tasks). Fill Requirements/Implementation Approach normally.
  - **investigation-driven**: the user needs to **figure something out first, then design a fix based on findings**. Cues: "figure out why…", "find out if…", "investigate…", "diagnose…", "root cause…", type is Research, Type is Bug with unknown cause, or requirements start with "understand X before deciding Y". DO NOT fabricate specific implementation details — that's what the investigation produces. Instead, populate the TSK to support a two-phase flow (see next).

Prefer assumptions over questions. Default to Medium priority if ambiguous.

### Investigation-driven task population

When the shape is `investigation-driven`, stay within the existing TSK template — **do NOT invent a new document type**. Adjust how you fill the sections:

- **Summary / Context**: describe the problem + what we want to understand. Do not claim a root cause we haven't established.
- **Research Findings** section of the TSK: keep the section in the document (do not strip it) but leave it as "Investigation pending — will be populated during Phase 1" so `/task-plan` and `/task-continue` know where to write findings later.
- **Requirements → Functional/Technical/Acceptance Criteria**: capture only what's already known and stable. For everything contingent on investigation results, use phrasing like "Once investigation completes, implement the chosen remediation" — NOT speculative details.
- **Implementation Approach**: if the fix depends on what the investigation finds, write "Approach to be finalized in DSN after Phase 1 investigation" and list the candidate approaches you considered (even if the right one isn't known yet). This is what `/task-design` will turn into deferred decisions with triggers.

The downstream workflow is: `/task-capture` (this command, produces TSK with pending Research Findings) → `/task-design` (produces DSN with investigation decisions resolved + implementation decisions deferred with triggers) → `/task-plan` (produces PLN with Phase 1 = investigation, design-refinement step, then implementation phases). All within the existing TSK/DSN/PLN triad.

## Step 4: Reserve TSK Path (NO write yet)

```bash
~/.claude/scripts/task-capture.sh --create-doc --title "${TASK_TITLE}" --description "${TASK_DESCRIPTION}"
```

**`write_document`** — Response contains `task_id`, `filepath`, and `template`.

**Do NOT write the file yet.** Hold the `task_id`, `filepath`, and `template` in context. Step 5 creates the external task first so that its ID/URL can be baked into the TSK template before the single Write call in Step 6. This avoids the "write, then patch external tracking" double-write pattern.

## Step 5: Create External Tracking FIRST (if configured)

```bash
~/.claude/scripts/task-capture.sh --sync-external --task-id "${TASK_ID}"
```

**`skipped`** (backend is `taskforge` or unconfigured) — No external sync needed. Fall through to Step 6 with the `external_tracking` section blank.

**`needs_llm`** (backend is `asana`) — Create Asana task BEFORE writing the TSK file:
- Call `mcp__asana__create_task` with task title, description, project → capture the returned Asana GID and permalink URL
- Set custom fields (Priority, Status, Requesting User) via `mcp__asana__update_custom_field`
- Record Asana GID and URL for Step 6
- Use `~/.claude/templates/external-notes.md` for Asana description format

**`needs_llm`** (backend is `gitlab`) — Create GitLab issue BEFORE writing the TSK file:
- Use `~/.gitlab-token` and PROJECT.yaml `git.repo`
- Create issue with title, description, labels → capture the issue number and URL
- Record issue info for Step 6

If source IS Asana/GitLab (fetched in Step 2): use its existing GID/number directly — no create call needed, just capture the IDs for Step 6.

External sync is best-effort, but if it fails: do NOT proceed to Step 6. Retry the MCP call, or abort capture. Writing a TSK without the external ID when one was expected leaves orphaned local state. If external sync genuinely cannot succeed, the user should explicitly opt-out (re-run without backend configured).

## Step 6: Write TSK Document (single atomic write)

With the TSK template from Step 4 and (if applicable) the external ID/URL from Step 5:

- Fill in all content sections (Summary, Context, Requirements, Technical Details) with the parsed task data
- Populate the **External Tracking** section with the Asana GID/URL or GitLab issue number/URL captured in Step 5 (or leave blank if `skipped`)
- **Research Findings section handling** (based on `shape` from Step 3):
  - `direct` shape → follow the template's conditional comment and **remove the entire Research Findings section** (heading, content, separator).
  - `investigation-driven` shape → **keep** the section and replace its body with the single line: `Investigation pending — will be populated during Phase 1 of the plan.` Leave Investigation Date as a placeholder `YYYY-MM-DD`. This tells `/task-design` and `/task-plan` that this task needs an investigation phase.
- **Implementation Approach section** (investigation-driven only): list the candidate approaches we considered with brief pros/cons, then set **Decision**: `To be finalized in DSN after Phase 1 investigation`. Do NOT pick an option speculatively.
- Leave Testing/Deployment/Timeline sections as template defaults
- Write the completed document to `filepath` using the Write tool — **this is the only write for the TSK**

## Step 7: Present Summary

Report: task ID, title, priority, source, file path. Suggest `/task-start <id>` as next step.

## Section Resumption

```bash
~/.claude/scripts/task-capture.sh --detect --input "${INPUT}"    # Retry detection
~/.claude/scripts/task-capture.sh --parse --input "${INPUT}"     # Retry parsing
~/.claude/scripts/task-capture.sh --create-doc                   # Retry doc creation
~/.claude/scripts/task-capture.sh --sync-external                # Retry external sync
```

## Debugging

```bash
~/.claude/scripts/task-capture.sh --raw --detect --input "${INPUT}"
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-capture" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
