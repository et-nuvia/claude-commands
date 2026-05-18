---
command: rca-timeline
group: rca
backing_script: ~/.claude/scripts/rca-timeline.sh
mutates: [files]
runtime: ~3-10min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /rca-timeline

> Part of the [Incident Response workflow](../08-workflows.md#incident-response-rca).

Reconstructs the sequence of events surrounding an incident by pulling from
available log sources, deployment records, and alert history, then writes a
chronological timeline document. Run this after `/rca-triage` opens the
incident — the timeline it produces becomes the factual backbone for the
root cause analysis that follows.

---

## When to use it

- An INC document exists and you need to establish *what happened and when* before diving into root cause
- You want a single document that correlates logs, deploys, and alerts across the incident window
- You need timestamps filled in before running `/rca-analyze`

## Usage

```bash
/rca-timeline [incident-id]
```

**Common invocations:**

```bash
/rca-timeline                                           # default: prompts for incident details
/rca-timeline INC-2026-0516-001                         # specify incident ID directly
/rca-timeline --gather --incident INC-2026-0516-001 \
  --start "2026-05-16 14:00" --end "2026-05-16 16:00"  # full parameters, skip prompts
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Incident ID (e.g., `INC-2026-0516-001`). Skips the ID prompt. |
| `--incident <ID>` | No | Explicit incident ID for section-flag invocations |
| `--start <YYYY-MM-DD HH:MM>` | No | Incident window start time |
| `--end <YYYY-MM-DD HH:MM>` | No | Incident window end time |
| `--gather` | No | Run only parameter gathering; no collection or generation |
| `--collect` | No | Run only log and event collection against a gathered window |
| `--generate` | No | Run only document generation from previously collected data |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Pull deployment and commit history for the incident window | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- INC document (from `/rca-triage`) — referenced for incident metadata
- Timeline document written to project docs directory using V4 naming
  (`<ID>-<DATETIME>-RCA-timeline.md` or similar)

## Backing script

**Script**: `~/.claude/scripts/rca-timeline.sh`

**Inputs:** No required flags for `--full`. Section flags accept
`--incident <ID>`, `--start <time>`, `--end <time>`.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`gather_user_input`, `display_summary`, `fix_error`}
- When `display_summary`: `incident_id`, `timeline_doc` (file path),
  `start_time`, `end_time`, `event_count`
- When `gather_user_input`: `missing_fields[]`

**Invocation surface:**

```bash
~/.claude/scripts/rca-timeline.sh --full                                                        # main
~/.claude/scripts/rca-timeline.sh --json --full --incident "INC-001" \
  --start "2026-02-14 10:30" --end "2026-02-14 12:45"                                          # fully parameterized
~/.claude/scripts/rca-timeline.sh --gather --incident "INC-001" \
  --start "2026-02-14 10:30" --end "2026-02-14 12:45"                                          # gather only
~/.claude/scripts/rca-timeline.sh --collect                                                     # collect only
~/.claude/scripts/rca-timeline.sh --generate                                                    # generate only
~/.claude/scripts/rca-timeline.sh --raw --gather                                                # debug gather
~/.claude/scripts/rca-timeline.sh --raw --generate                                             # debug generate
```

## How it works

1. **Gather** — script checks for incident ID, start time, and end time. If any
   are missing it returns `gather_user_input`; the LLM asks the user and re-runs
   with explicit flags.
2. **Collect** — script pulls events from available sources: git log (commits and
   merges in the window), deployment records, log file snippets, and any alerts
   referenced in the INC document. Events are normalized to UTC timestamps.
3. **Generate** — collected events are sorted chronologically and written into a
   timeline document. Each entry includes: timestamp, event type, description, and
   the source it came from (log file, git, alert system).
4. **Display summary** — LLM reports incident ID, document path, the
   start-to-end window, and event count. Prompts the user to fill in any
   actual timestamps that were approximated, then suggests `/rca-analyze`.

## Example workflows

### Scenario: Full incident chain (in sequence)

```
/rca-triage             # open incident, assign SEV, write INC document
/rca-timeline           # reconstruct event sequence
/rca-analyze            # 5 Whys root cause analysis
/rca-pir                # post-incident review and action items
```

`/rca-timeline` is step 2 in the chain. Run it after `/rca-triage` assigns the
incident ID and before `/rca-analyze` needs a facts baseline.

### Scenario: Narrow window, pre-filled parameters

```
/rca-timeline --gather --incident INC-2026-0516-001 \
  --start "2026-05-16 14:30" --end "2026-05-16 16:00"
```

Skip the interactive prompt when you already know the exact incident window —
useful when running from a runbook or in a time-pressured SEV1.

### Scenario: Example output

```
/rca-timeline INC-2026-0516-001
```

```
Timeline created: INC-2026-0516-001
  Document: docs/incidents/INC-2026-0516-001-20260516T1440-RCA-timeline.md
  Window:   2026-05-16 14:00 → 2026-05-16 16:00 (2h 0m)
  Events:   14 entries collected (git: 3, logs: 8, alerts: 3)

Review the document and fill in any approximated timestamps (marked [~]).

Next: /rca-analyze INC-2026-0516-001
```

## Notes & gotchas

- Timestamps in the generated document marked `[~]` are approximations; replace
  them with confirmed values before sharing with stakeholders.
- Log collection depends on what sources are available locally — CI log artifacts,
  application log files, or cloud log exports must be accessible from the working
  directory or the script will note them as unavailable.
- `--collect` and `--generate` are designed to run sequentially after `--gather`;
  running `--generate` without a prior `--collect` will produce an empty or
  incomplete document.
- **If it fails:** rerun with `~/.claude/scripts/rca-timeline.sh --raw --gather`
  to verify parameters were captured correctly, then `--raw --generate` to check
  document generation. If the incident window is very wide (> 24 h), collection
  may time out — narrow the window with `--start` / `--end` and re-run.
