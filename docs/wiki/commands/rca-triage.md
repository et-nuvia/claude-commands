---
command: rca-triage
group: rca
backing_script: ~/.claude/scripts/rca-triage.sh
mutates: [files]
runtime: ~2-5min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /rca-triage

> Part of the [Incident Response workflow](../08-workflows.md#incident-response-rca).

Kicks off the incident response protocol: collects the essential facts about an
active incident (severity, affected service, impact, symptoms), classifies it
into a SEV tier with a matching response SLA, and writes an INC document to
anchor the rest of the investigation. This is always the first command in the
four-step RCA chain.

---

## When to use it

- An alert fired or a user reported a production outage and you need to open a formal incident
- You need to assign a severity level quickly (SEV1–SEV4) and know the expected response window
- You want a timestamped INC document before the team starts parallel investigation

## Usage

```bash
/rca-triage
```

**Common invocations:**

```bash
/rca-triage                  # default: interactive gather → INC document
/rca-triage --assess         # assessment only — print severity levels and required fields
/rca-triage --respond        # document prep only — print path and template without gathering
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form hint (e.g., "payment service down since 14:30"). Pre-populates the description field. |
| `--assess` | No | Run only the assessment phase; print severity thresholds, do not create a document. |
| `--respond` | No | Run only the document-prep phase; print the INC path and template. |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Determine repo root for document placement | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- INC document written to project docs directory using V4 naming convention (`<INCIDENT_ID>-<DATETIME>-INC-<description>.md`)

## Backing script

**Script**: `~/.claude/scripts/rca-triage.sh`

**Inputs:** No required flags. Accepts `--assess` and `--respond` section flags.
Gathers incident details interactively or from user input relayed by the LLM.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`gather_user_input`, `create_document`, `display_summary`, `fix_error`}
- When `create_document`: `incident.document_path`, `incident.id`, `incident.severity`,
  `incident.detected_time`, `incident.description`, `incident.impact`, `incident.service`
- When `gather_user_input`: `missing_fields[]`, prompt text for each

**Invocation surface:**

```bash
~/.claude/scripts/rca-triage.sh --full          # main entry
~/.claude/scripts/rca-triage.sh --assess        # severity assessment only
~/.claude/scripts/rca-triage.sh --respond       # document path + template only
~/.claude/scripts/rca-triage.sh --raw --full    # debug: bypass formatting
~/.claude/scripts/rca-triage.sh --raw --assess  # debug: assessment phase
```

## How it works

1. **Execute** — script runs `--full`; returns `next_action`.
2. **Gather input** — if `gather_user_input`, the LLM asks conversationally for:
   description, detected time (YYYY-MM-DD HH:MM), severity estimate, affected
   service, user impact count, and error symptoms. Script re-runs once input
   is provided.
3. **Classify severity** — script maps incident details to SEV1 (Critical, 15 min
   SLA) through SEV4 (Low, 1 day SLA) and records the response window.
4. **Create INC document** — when `create_document`, the LLM writes the INC file
   at `incident.document_path`, populating severity, detected time, description,
   impact, initial timeline entry, and immediate-action checklist.
5. **Display summary** — incident ID, document path, severity tier, SLA deadline,
   and recommended immediate action are shown to the user.
6. **Route to next step** — suggest `/rca-timeline` to begin reconstructing the
   event sequence.

## Example workflows

### Scenario: Full incident chain (SEV1 outage)

```
/rca-triage             # open incident, INC document
/rca-timeline           # reconstruct event sequence
/rca-analyze            # 5 Whys root cause analysis
/rca-pir                # post-incident review and action items
```

Run these four commands in order for every incident that warrants a formal review.
`/rca-triage` must be first — the INC document ID it creates is referenced by
the other three commands.

### Scenario: Triage only, hand off to on-call

```
/rca-triage
/rca-timeline           # colleague picks up from here
```

When you need to open the incident record and set severity before handing off
to another engineer for deep investigation.

### Scenario: Example output

```
/rca-triage
```

```
Incident opened: INC-2026-0516-001
  Severity:  SEV2 — High (response SLA: 1 hour)
  Service:   payments-api
  Detected:  2026-05-16 14:30
  Impact:    ~200 users unable to complete checkout
  Document:  docs/incidents/INC-2026-0516-001-20260516T1435-INC-payments-api-down.md

Immediate action: escalate to payments team lead, check recent deployments.

Next: /rca-timeline INC-2026-0516-001
```

## Notes & gotchas

- The INC document path uses V4 naming (`<ID>-<DATETIME>-INC-<slug>.md`). The
  incident ID generated here is the anchor for all downstream commands — keep it
  consistent.
- Severity can be adjusted after the fact; the SLA clock starts from `detected_time`,
  not from when you ran `/rca-triage`.
- Safe to run multiple times; each run creates a new INC document with a fresh ID.
- **If it fails:** rerun with `~/.claude/scripts/rca-triage.sh --raw --assess`
  to see unformatted output and identify which field collection step failed.
  For document-write errors, check that the target directory exists and is writable.
