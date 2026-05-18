---
command: network-audit
group: audit
backing_script: ~/.claude/scripts/analyze-har.py
mutates: []
runtime: ~1-3min (Playwright browser launch + page idle wait)
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /network-audit

> Part of the [Auditing workflow](../08-workflows.md#auditing-scorecards).

Navigates to a URL using a headless Playwright browser, records all network
activity into a HAR file, and analyzes it for redundant API calls, excessive
payloads, waterfall gaps, and error responses. Produces a structured network
audit document in `docs/features/active/`. Makes no changes to application
code; safe to run repeatedly.

---

## When to use it

- A page feels slow and you suspect N+1 or duplicate API calls
- After a feature merge, to confirm no unintended network regressions
- Before a performance review, to produce a baseline network trace

## Usage

```bash
/network-audit <url>
```

**Common invocations:**

```bash
/network-audit https://staging.example.com/dashboard
/network-audit https://localhost:3000/patients
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `<url>` | Yes | The page URL to audit. Should be accessible from the local machine (staging or localhost). |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `npx` / `playwright` | Browser automation and HAR recording | `npm install -D playwright && npx playwright install chromium` |
| `python3` | Runs the HAR analysis script | preinstalled |
| `jq` | Build / consume result JSON | `brew install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `temp.har` — HAR recording written during execution (temporary, in working directory)
- `~/.claude/templates/feature/network-audit.md` — audit document template
- `docs/features/active/` — output directory for the generated audit document
- `/tmp/network-audit-result.json` — written for the LLM phase

## Backing script

**Script**: `~/.claude/scripts/analyze-har.py`

The script parses the HAR file and emits structured findings. The LLM drives
the Playwright browser session, then provides qualitative analysis and
optimization recommendations on top of the JSON output.

**Inputs:** path to `temp.har`. No CLI flags — all configuration is implicit.

**Outputs (structured JSON, to stdout and `/tmp/network-audit-result.json`):**

- `url` — audited page URL
- `request_count` — total requests recorded
- `findings[]` — per-finding `type` (redundant_call / excessive_payload /
  waterfall_gap / error_response), `endpoint`, `severity`, `evidence`, `count`
- `summary{}` — counts by type and severity
- `timeline[]` — request waterfall with timing data

**Invocation surface:**

```bash
python3 ~/.claude/scripts/analyze-har.py temp.har
```

**Analysis categories** (used for finding classification and report sections):

| Category | What It Checks |
|---|---|
| Redundant Calls | Same API endpoint called multiple times with identical parameters within a single page load |
| Excessive Payload | JSON responses larger than a threshold that significantly impact load time |
| Waterfall Gaps | Sequential requests that could be parallelized (each waits for the previous response) |
| Error Responses | Any non-2xx/3xx status codes: 4xx (client error) and 5xx (server error) |

## How it works

1. **Audit setup** — LLM validates the URL is reachable and `docs/features/active/`
   exists (or creates it).
2. **HAR recording** — LLM uses Playwright to launch a headless Chromium
   browser with HAR recording enabled (`recordHar: { path: 'temp.har' }`),
   navigates to the target URL, and waits for the network to reach an idle
   state (no activity for ~500ms).
3. **Analysis** — runs `python3 ~/.claude/scripts/analyze-har.py temp.har`,
   which parses every request/response pair and classifies findings by category.
4. **Read results** — LLM reads `/tmp/network-audit-result.json`; no further
   file scanning needed.
5. **Contextual analysis** — for each finding: explains the performance or
   correctness impact, identifies the likely source (component or API route),
   and suggests a concrete fix (client-side caching, request batching,
   parallelization, error handling).
6. **Report generation** — LLM fills in `~/.claude/templates/feature/network-audit.md`
   with findings and writes the completed document to
   `docs/features/active/[YYMMDDHHMM]-NET-[feature-name].md`.
7. **Follow-up routing** — offers to convert excessive-call findings into
   optimization tasks via `/task-capture`, investigate backend logic for
   specific endpoints, or check frontend caching opportunities.

## Example workflows

### Scenario: Post-merge regression check

```
# after merging a feature that touches the dashboard data layer
/network-audit https://staging.example.com/dashboard
/task-capture Optimize dashboard API calls: <summary>
```

### Scenario: Baseline before performance sprint

```
/network-audit https://staging.example.com/patients
# review generated doc in docs/features/active/
# commit as baseline for comparison after sprint
```

### Scenario: Scorecard output

```
/network-audit https://staging.example.com/dashboard
```

```
Network Audit — Dashboard Page
─────────────────────────────────────────
URL:     https://staging.example.com/dashboard
Date:    2026-05-16
Requests: 47 total

Findings:
  Redundant Calls    3   (high)
  Excessive Payload  1   (medium)
  Waterfall Gaps     2   (medium)
  Error Responses    1   (high)

Redundant Calls (high):
  • GET /api/patients/summary — called 4× with identical params
    Fix: memoize in PatientContext or move to page-level fetch
  • GET /api/user/permissions — called 3× on mount
    Fix: hoist to AuthProvider, pass via context

Error Responses (high):
  • GET /api/notifications → 500 (Internal Server Error)
    Fix: investigate backend NotificationsService

Audit saved: docs/features/active/2605160930-NET-dashboard.md
```

## Notes & gotchas

- The target URL must be reachable from the local machine. For staging behind
  VPN, ensure the VPN is connected before invoking.
- Playwright launches a real Chromium process; it requires `playwright install chromium`
  to have been run at least once.
- HAR recording captures all network traffic including auth tokens in request
  headers — `temp.har` is written to the working directory and should not be
  committed. Add `temp.har` to `.gitignore` if running repeatedly.
- The idle-wait heuristic (no network activity for ~500ms) may miss lazy-loaded
  content. For pages with infinite scroll or deferred loads, interact with the
  page manually or increase the wait threshold in the Playwright script.
- **If it fails:** verify Playwright can reach the URL with
  `npx playwright test --grep "Network Trace"` in isolation. If `analyze-har.py`
  errors, check that `temp.har` is non-empty and valid JSON by opening it in
  a browser DevTools HAR viewer.
