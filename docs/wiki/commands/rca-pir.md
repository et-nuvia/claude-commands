---
command: rca-pir
group: rca
backing_script: ~/.claude/scripts/rca-pir.sh
mutates: [files]
runtime: ~5-15min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /rca-pir

Generates the post-incident review (PIR) document: the structured retrospective
that closes the loop on a resolved incident. It gathers what went well, what
could improve, and the full action item list; synthesizes this into a shareable
PIR document for stakeholders and the team. This is the final step in the
four-command RCA chain — run it after `/rca-analyze` has identified the root cause.

> **Note:** This command requests the `opus` model for comprehensive retrospective
> synthesis. The PIR is a team-facing artifact; shallow analysis produces action
> items that don't stick.

---

## When to use it

- The incident is resolved and you are ready to document the retrospective before memory fades
- You need a shareable document with action items, owners, and timelines to send to stakeholders
- You want to formally close the incident record opened by `/rca-triage`

## Usage

```bash
/rca-pir [incident-id]
```

**Common invocations:**

```bash
/rca-pir                         # default: full gather → PIR document
/rca-pir INC-2026-0516-001       # pass incident ID to pre-populate gather
/rca-pir --gather                # gather incident info only, no document generation
/rca-pir --generate              # generate PIR document from completed gather
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Incident ID (e.g., `INC-2026-0516-001`). Pre-populates gather phase. |
| `--gather` | No | Run only the gather phase; collect PIR inputs without generating the document |
| `--generate` | No | Generate the PIR document from previously gathered data |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Correlate resolution commits and deploy timestamps | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- INC document (from `/rca-triage`) — read for incident ID, severity, and detected time
- RCA document (from `/rca-analyze`) — read for root cause and preliminary action items
- PIR document written to project docs directory using V4 naming
  (`<ID>-<DATETIME>-PIR-<description>.md` or similar)

## Backing script

**Script**: `~/.claude/scripts/rca-pir.sh`

**Inputs:** No required flags for `--full`. Section flags `--gather` and
`--generate` run individual phases.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `fix_error`}
- When `display_summary`: `incident_id`, `duration`, `pir_path`, `action_items[]`

**Invocation surface:**

```bash
~/.claude/scripts/rca-pir.sh --full        # main entry
~/.claude/scripts/rca-pir.sh --gather      # gather phase only
~/.claude/scripts/rca-pir.sh --generate    # document generation only
~/.claude/scripts/rca-pir.sh --raw --full  # debug: bypass formatting
```

## How it works

1. **Gather** — script interactively collects (or confirms from prior documents):
   incident ID, start and end times, total duration, severity, summary, root
   cause (carried from `/rca-analyze`), impact, what went well during the
   response, and what could be improved.
2. **Synthesize** — LLM (using opus) reviews the gathered inputs alongside the
   INC and RCA documents, identifies patterns across the "what went well" and
   "what could improve" responses, and elevates the highest-value action items
   with suggested owners and timelines.
3. **Generate PIR document** — script writes the PIR file with: executive summary,
   incident timeline (high level), root cause, impact assessment, response
   retrospective (went well / could improve), and a prioritized action item table
   with owners, priorities, and due dates.
4. **Display summary** — LLM reports incident ID, total duration, PIR document
   path, and action item count. Suggests reviewing with the team and assigning
   owners in the tracker (Asana or GitLab).

## Example workflows

### Scenario: Full incident chain (in sequence)

```
/rca-triage             # open incident, assign SEV, write INC document
/rca-timeline           # reconstruct event sequence
/rca-analyze            # 5 Whys root cause analysis
/rca-pir                # post-incident review and action items
```

`/rca-pir` is the final step. Run it within 24–48 hours of resolution while the
team's memory of the response is fresh. The PIR document it produces is the
artifact shared with stakeholders and used to track corrective actions.

### Scenario: Rapid PIR for a low-severity incident

```
/rca-triage             # SEV3 or SEV4 — INC document, no formal timeline needed
/rca-analyze            # lightweight 5 Whys
/rca-pir                # PIR to close the record
```

For SEV3/4 incidents where a full timeline reconstruction is not warranted,
skip `/rca-timeline` and run triage → analyze → PIR.

### Scenario: Example output

```
/rca-pir INC-2026-0516-001
```

```
PIR complete: INC-2026-0516-001
  Duration:  2h 14m (14:30 → 16:44)
  Severity:  SEV2
  Document:  docs/incidents/INC-2026-0516-001-20260516T1630-PIR-payments-api.md

  Action items: 4
    [P1] Scale connection pool with worker count — platform team — due 2026-05-23
    [P1] Add pool saturation alert — observability team — due 2026-05-23
    [P2] Load-test staging at peak concurrency — QA — due 2026-05-30
    [P3] Document pool sizing guide in runbook — any — due 2026-06-06

Next: assign action items in Asana / GitLab and schedule team review.
```

## Notes & gotchas

- **Use opus.** Retrospective synthesis across multiple incident documents and
  free-form team input requires deeper reasoning to surface patterns and propose
  meaningful corrective actions.
- Run `/rca-pir` while memories are fresh — within 24–48 hours of resolution.
  "What went well" and "what could improve" inputs gathered a week later are
  significantly less specific.
- `--generate` requires `--gather` to have run first in the same session; state
  is not persisted between separate invocations.
- The PIR action items are a starting point. Assign owners and due dates in your
  task tracker (Asana or GitLab) as a follow-up — the PIR document alone does not
  create trackable tasks.
- **If it fails:** rerun with `~/.claude/scripts/rca-pir.sh --raw --full` to see
  unformatted output. If gather cannot locate the INC or RCA documents, verify
  the incident ID matches what was created by `/rca-triage` and that the docs
  directory is accessible from the working directory.
