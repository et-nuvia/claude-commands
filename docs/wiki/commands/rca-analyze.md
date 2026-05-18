---
command: rca-analyze
group: rca
backing_script: ~/.claude/scripts/rca-analyze.sh
mutates: [files]
runtime: ~5-15min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /rca-analyze

> Part of the [Incident Response workflow](../08-workflows.md#incident-response-rca).

Conducts a structured root cause analysis using the 5 Whys methodology: gathers
the incident facts (or reads them from the existing INC document), walks through
iterative causal questioning until a systemic root cause is reached, identifies
contributing factors, and writes an RCA report document. This is the analytical
core of the incident response chain — run it after `/rca-timeline` so the causal
chain is grounded in confirmed events.

> **Note:** This command requests the `opus` model for complex causal reasoning.
> Invoke it explicitly — shallow analysis risks misidentifying the root cause.

---

## When to use it

- A timeline exists and you are ready to reason about *why* the incident happened
- You need a defensible, methodology-backed root cause to present to leadership or share with customers
- You want corrective action items derived from the causal chain, not just from symptoms

## Usage

```bash
/rca-analyze [incident-id]
```

**Common invocations:**

```bash
/rca-analyze                         # default: full interactive gather → 5 Whys → RCA report
/rca-analyze INC-2026-0516-001       # pass incident ID to pre-populate gather phase
/rca-analyze --gather                # gather incident details only, no analysis
/rca-analyze --analyze               # run 5 Whys only (requires prior gather)
/rca-analyze --report                # generate RCA document from completed analysis
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Incident ID (e.g., `INC-2026-0516-001`). Pre-populates gather phase. |
| `--gather` | No | Run only the gather phase; collect incident details without analyzing |
| `--analyze` | No | Run only the 5 Whys phase; requires prior `--gather` output |
| `--report` | No | Generate the RCA document from completed analysis data |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Correlate causal chain with commit/deploy history | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- INC document (from `/rca-triage`) — read for incident metadata
- Timeline document (from `/rca-timeline`) — read as factual input for 5 Whys
- RCA report written to project docs directory using V4 naming
  (`<ID>-<DATETIME>-RCA-<description>.md`)

## Backing script

**Script**: `~/.claude/scripts/rca-analyze.sh`

**Inputs:** No required flags for `--full`. Section flags `--gather`, `--analyze`,
`--report` run individual phases.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `fix_error`}
- When `display_summary`: `incident_id`, `problem` (statement), `root_cause`
  (the terminal Why), `contributing_factors[]`, `report_path`, `action_items[]`

**Invocation surface:**

```bash
~/.claude/scripts/rca-analyze.sh --full       # main entry
~/.claude/scripts/rca-analyze.sh --gather     # gather only
~/.claude/scripts/rca-analyze.sh --analyze    # 5 Whys only
~/.claude/scripts/rca-analyze.sh --report     # document generation only
~/.claude/scripts/rca-analyze.sh --raw --full # debug: bypass formatting
```

## How it works

1. **Gather** — script collects or confirms incident details: problem statement,
   affected service, start/end times, user impact, and a reference to the
   existing INC and timeline documents.
2. **5 Whys analysis** — LLM (using opus) iterates: "Why did X happen? → Y.
   Why did Y happen? → Z." until a root cause that is systemic or structural
   is reached (typically 4–6 iterations). The LLM surfaces assumptions that
   need verification and flags branches where the causal chain is uncertain.
3. **Contributing factors** — additional causal paths that are real but not
   the primary root cause are captured separately (e.g., monitoring gap that
   delayed detection, process gap that allowed the deploy through).
4. **Report generation** — the script writes an RCA document containing:
   problem statement, 5 Whys chain, root cause, contributing factors, and an
   initial corrective-action list with owners and priorities.
5. **Display summary** — LLM reports incident ID, the root cause in one sentence,
   report path, and action item count. Suggests reviewing the doc with the team
   and running `/rca-pir` to formalize the post-incident review.

## Example workflows

### Scenario: Full incident chain (in sequence)

```
/rca-triage             # open incident, assign SEV, write INC document
/rca-timeline           # reconstruct event sequence
/rca-analyze            # 5 Whys root cause analysis
/rca-pir                # post-incident review and action items
```

`/rca-analyze` is step 3. The timeline from step 2 provides the factual input
that grounds the 5 Whys chain. Run `/rca-pir` immediately after to capture the
team's retrospective while the analysis is fresh.

### Scenario: Deep-dive on a recurring incident

```
/rca-analyze INC-2026-0516-001   # this incident
# compare with prior RCA docs manually
/rca-pir
```

Use when an incident type has occurred before and you want to verify the
root cause has actually changed (or discover that a previous fix was incomplete).

### Scenario: Example output

```
/rca-analyze INC-2026-0516-001
```

```
RCA complete: INC-2026-0516-001
  Root cause:  Database connection pool exhausted — pool size was not scaled
               with the worker count increase shipped in v2.14.0 (2026-05-15).
  Contributing factors:
    • No connection pool saturation alert configured
    • Staging load does not replicate peak production concurrency
  Action items: 3 (1 critical, 2 medium)
  Report: docs/incidents/INC-2026-0516-001-20260516T1520-RCA-connection-pool.md

Next: /rca-pir INC-2026-0516-001
```

## Notes & gotchas

- **Use opus.** The source command explicitly requires it. Complex causal chains
  with multiple interacting systems will produce shallow or incorrect root causes
  with a less capable model.
- The 5 Whys chain is most reliable when the timeline from `/rca-timeline` is
  complete. Running `/rca-analyze` before the timeline is filled in tends to
  produce speculative chains that require revisiting.
- `--analyze` and `--report` depend on `--gather` having run first in the same
  session; state is not persisted between separate invocations.
- Corrective action items in the RCA report are preliminary — the PIR (`/rca-pir`)
  is where they are prioritized, assigned, and tracked.
- **If it fails:** rerun with `~/.claude/scripts/rca-analyze.sh --raw --full`
  to see unformatted output. If the gather phase cannot locate the INC document,
  verify the incident ID matches what `/rca-triage` created.
