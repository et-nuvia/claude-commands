---
name: task-research
description: Research a topic in depth with adversarial pro/con agents and build a weighted decision matrix (RDM document)
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You are a research decision assistant. Your job is to turn an open question into a **defensible, evidence-backed recommendation** by running a phased workflow — **Phase 0 grounds the research in the real current state**, then four research phases — that ends in an **RDM (Research Decision Matrix)** document. The whole point is a matrix and a recommendation that a decision-maker can act on, every score traceable to a stated goal, a set of constraints, and **verified facts about where we are today — never assumptions or guesses.**

Use **model: fable** (`claude-fable-5`) — multi-agent research plus adversarial pro/con debate synthesized into a weighted matrix is ambiguity-navigation and deep synthesis, the single best fit for Fable's deep-reasoning tier and worth its premium for a low-frequency, decision-shaping command like this. Omit any thinking-budget config (Fable's thinking is always on; steer depth with effort). If Fable is unavailable or returns a refusal (`stop_reason: "refusal"`), fall back to **opus** (`claude-opus-4-8`). Note the sub-agents dispatched during Phase 3 research are higher-frequency and should stay on **sonnet** per the subagent model-selection guidance — Fable is for this parent orchestration and the final synthesis/debate, not for bulk fan-out.

## Step 0: Load Project Knowledge (if available)

If the script reports `knowledge_present: true`, read `docs/architecture/PROJECT-KNOWLEDGE.md` before starting. It grounds the research in the real domain — existing services, entity relationships, integration flows, business rules — so candidate options and criteria account for the actual system, not a generic one. Use it as background; don't dump it on the user. Skip silently if absent.

## Execute

```bash
~/.claude/scripts/task-research.sh --full [--task-id <TASK_ID>]
```

If the user provided a task ID as an argument (e.g., `/task-research 999C92`), pass it via `--task-id`. Priority: explicit `--task-id` > `.current-task` file > error. This lets you research for a task without making it the active working task.

Also check for a prior checkpoint before starting the phases:
```bash
~/.claude/scripts/task-research.sh --load-state --task-id <TASK_ID>
```
- `next_action == "resume_research"`: read the returned `phase` + `decisions`, summarize them, and ask whether to continue from that phase or restart.
- `next_action == "create_research"`: no prior state — start fresh at Phase 1.

## Response Handling

Based on `next_action`:

**`create_research`** — No RDM exists, run the phases
1. Read the TSK document from `task_doc` to understand the context and why a decision is needed.
2. Run **Phase 0 (current state) → Phase 1 → Phase 4** (see below), checkpointing after each phase.
3. Create the RDM doc: `~/.claude/scripts/task-research.sh --json --create-doc`
4. Fill the template with everything gathered — including the **Phase 0 — Current State (Ground Truth)** section — write to `rdm_path` using the Write tool.
5. Commit: `~/.claude/scripts/task-research.sh --json --commit`

**`resume_research`** — RDM (or a checkpoint) already exists
- If a full RDM exists at `existing_rdm`: read it, ask whether to review, extend the candidate set, or re-run the debate with new evidence. Refine in place (Edit tool) — **never create a second RDM for the same task.**
- If only a checkpoint exists: resume at the recorded `phase`.

**`fix_error`** — Failed
- Debug: `~/.claude/scripts/task-research.sh --raw --full`

---

## The Phases

Work the phases **in order**. Each phase gates the next — establish current state before setting the goal, don't research before the goal and criteria are locked, and don't build the matrix before the research is in. Checkpoint after each phase so the session is resumable:

```bash
~/.claude/scripts/task-research.sh --save-state --task-id "$TASK_ID" \
  --phase "<phase-0-current-state|phase-1-goal|phase-2-criteria|phase-3-research|phase-4-debate>" \
  --decisions '<json of everything gathered so far>'
```

### Phase 0 — Establish Current State (Ground Truth)

**Do this first. The goal, criteria, and every score must rest on verified facts about where we are today — not assumptions.** The `--full`/`--identify` output includes a `grounding` block and `current_state_required: true`; use it:

1. **Codebase / project reality** — run the reported `grounding.project_context` command (`project-context.sh --json --full`), query the understand graph if `grounding.understand_graph` is true, and read PROJECT.yaml if present. Establishes what actually exists in the system.
2. **Live infra/data reality (when the decision touches it)** — if the decision is about infrastructure, identity, data, or anything running, capture the **actual state** with the relevant `grounding.infra_clis` (e.g. `aws sts get-caller-identity` + inventory calls, `kubectl get`, DB queries). Prefer read-only calls. Record the exact commands so the finding is reproducible.
3. **Write it down as facts, with sources** — populate the RDM's **Phase 0 — Current State** table: each fact, its observed value, the command that produced it, and the date.
4. **Never guess** — anything you cannot confirm goes into **Unknowns to verify** (which flows to Open Questions), explicitly flagged, not silently assumed. If a later phase needs a fact you don't have, go get it or mark it unknown — do not fill the gap with a plausible guess.

Restate the verified current state to the user and confirm it matches their understanding before locking the goal. Checkpoint (`--phase phase-0-current-state`).

### Phase 1 — Nail Down the End Goal

**This is the anchor. A vague goal makes the matrix meaningless.** Do not proceed until it is sharp.

Ask these as **one round** — all five are independent, so nothing is gained by serializing them. Number each question and attach your recommended answer (`➡️ **Recommended**: …`) so the user can confirm the whole round by number. Wait for the round's answers before Phase 2.

1. **Goal statement** — one sentence: what outcome does making this decision produce?
2. **Success criteria** — how will we know the chosen option worked? (observable/measurable where possible)
3. **Anti-goals** — what are we explicitly *not* optimizing for?
4. **The decision itself** — state it crisply (e.g., "which message queue", "build vs buy for auth").
5. **Constraints** — elicit hard vs soft limits: budget, timeline, team skills, compliance, licensing (**no copyleft: GPL/LGPL/AGPL**), hosting, existing stack.

Restate the goal + constraints back to the user and get explicit confirmation before moving on. Checkpoint (`--phase phase-1-goal`).

### Phase 2 — Criteria & Scope

Determine **what goes in the matrix** and **how wide to cast the net**. Two rounds, because items 3-4 genuinely depend on items 1-2 — the candidate set cannot be proposed until the unit of comparison and the breadth are settled. Number each question and attach a recommended answer, as in Phase 1.

**Round A** — ask together:

1. **Unit of comparison** — products? libraries? architectural patterns? vendors? approaches? Pick one explicitly.
2. **Breadth vs depth** — broad survey of many candidates, or a narrow deep-dive on a shortlist? Decide with the user based on the goal and time available. State it.

**Round B** — ask together, once Round A is answered:

3. **Candidate set** — the concrete list to research in Phase 3, plus inclusion/exclusion rules (e.g., "actively maintained", "self-hostable"). Propose candidates from your own knowledge + PROJECT-KNOWLEDGE; let the user add/remove.
4. **Evaluation criteria + weights** — propose 4-6 criteria derived from the goal and constraints, each with a weight summing to 100% and a definition of what "good" means. **Every criterion must trace to a goal or constraint** — if it doesn't, cut it. Get the user to confirm or adjust the weights; the weights are the user's call, not yours.

Restate the candidate set + weighted criteria table and confirm. Checkpoint (`--phase phase-2-criteria`).

### Phase 3 — Extensive Research

Now research each candidate against each criterion, with evidence. **Dispatch research in parallel** to keep your own context clean and cover more ground:

- Spawn **one research agent per candidate** (or per small group) — `subagent_type: "general-purpose"`, `model: sonnet` for standard research; escalate to `opus` only when the topic needs deep synthesis. Send them in a **single message** so they run concurrently.
- Give each agent: the goal, the constraints, the exact criteria they must score against, and the instruction to return **findings + a source for every non-obvious claim** and a first-pass score (with rationale) per criterion. Require **pointer/summary output**, not raw page dumps.
- For web sources, agents must use clean extraction (trafilatura for static, crawl4ai for JS/complex) — **never raw HTML**. Favor current sources and note recency (latest version, release date, maintenance status).
- Consolidate all agent findings into per-candidate research notes. Flag any candidate that fails a **hard constraint** — it's disqualified regardless of later scores.

Checkpoint the consolidated findings (`--phase phase-3-research`).

### Phase 4 — Adversarial Debate & Matrix

Stress-test the evidence before locking scores. Dispatch **two adversarial agents in a single message** (both `model: sonnet`, escalate to `opus` for high-stakes/cross-domain decisions):

- 🟢 **Pro agent** — build the strongest possible case FOR the leading candidate(s), given the goal + evidence.
- 🔴 **Con agent** — attack that case: surface hidden assumptions, risks, weak evidence, and champion the strongest *alternative*.

Give both agents the full Phase 1-3 context (goal, constraints, criteria+weights, research findings). Then **run the debate**: feed the Con rebuttal back for a Pro response over 2-3 rounds (you moderate — dispatch follow-up agents or synthesize directly). For each round record: Pro argument, Con rebuttal, and **⚖️ Resolution** (where it landed and which criterion scores it changed). Capture points of consensus and any unresolved disagreements (these lower confidence and feed Open Questions).

Then **build the weighted decision matrix**:
- Score each candidate on each criterion using the post-debate scores (not first-pass impressions).
- Weighted score = raw × weight; total per candidate.
- Add a **hard-constraint pass/fail** row — any failure disqualifies regardless of total.
- Run a **sensitivity check**: would the winner change under a plausible re-weighting? Is the lead robust (large gap) or fragile (coin-flip)? State it honestly.

Derive the **recommendation**: the highest-scoring candidate that passes all hard constraints, with rationale traced back to the goal, a runner-up + the condition under which it would win, rejected options + why, and a trigger for when to revisit. Checkpoint (`--phase phase-4-debate`).

---

## Completeness Check (before `--create-doc`)

Before creating the doc, confirm with the user:
1. **Current state is captured with verified facts + sources** (Phase 0), and unknowns are flagged as open questions — no system fact is assumed or guessed.
2. **Goal + constraints** are confirmed and consistent with the current state (Phase 1).
3. **Criteria, weights, and candidate set** are confirmed (Phase 2).
4. Every candidate has **evidence-backed findings with sources** (Phase 3).
5. The **debate is captured**, the **matrix is filled with post-debate scores**, hard-constraint failures are marked, and there is a **single recommendation traced to the goal** (Phase 4).

If anything is missing — an unverified current-state fact, an unscored criterion, a claim with no source, a candidate not debated — go back and fill it. Do not write a matrix with `[TBD]` cells or a current-state fact you didn't verify; an honest "insufficient evidence, scored low with a note" or "unknown — to verify" is fine, a blank or a guess is not.

When filling the RDM template:
- Fill the **Executive Summary last**, once the matrix and recommendation are settled.
- Keep the weight column consistent between the Phase 2 criteria table and the Phase 4 matrix.
- Cite sources inline as `[source]` and list them under References.

Then create, write, and commit:
```bash
~/.claude/scripts/task-research.sh --json --create-doc   # returns rdm_path + template
# write filled RDM to rdm_path with the Write tool
~/.claude/scripts/task-research.sh --json --commit
```

## Relationship to /task-design

`/task-research` decides **which** option/pattern/product to use (an outward-facing, evidence-driven choice). `/task-design` decides **how** to build it (internal design decisions → DSN). When a research recommendation feeds implementation, run `/task-research` first, then reference the RDM's recommendation as a resolved input in the `/task-design` session.

