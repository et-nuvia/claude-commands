---
name: network-audit
description: Record and analyze network activity (HAR) for a specific page using Playwright.
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "network-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "network-audit" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

# Network Audit Analysis

I will navigate to a specified page using Playwright, record all network activity into a HAR file, and analyze the results to identify excessive API calls or performance bottlenecks.

**Template**: `~/.claude/templates/feature/network-audit.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-NET-[feature-name].md`

---

## 1. Audit Setup

**Input**: A URL to audit (e.g., your staging environment).

**Action**:
- I will use Playwright to launch a browser.
- I will enable HAR recording: `recordHar: { path: 'temp.har' }`.
- I will navigate to the target URL and wait for the page to be "idle" (no more network activity).

---

## 2. Execution & Trace Collection

```bash
# Example Playwright command I might run
npx playwright test --grep "Network Trace"
```

I will perform the navigation and capture the `temp.har` file.

---

## 3. Analysis Phase

I will run the analysis script to parse the results:
```bash
~/.claude/scripts/analyze-har.py temp.har
```

I will specifically look for:
- **Redundant Calls**: The same API endpoint called multiple times with the same parameters.
- **Excessive Payload**: Large JSON responses that impact load time.
- **Waterfall Gaps**: Sequential requests that should be parallelized.
- **Unauthorized/Error Calls**: Any non-200/300 status codes.

---

## 4. Report Generation

I will generate a network audit document to `docs/features/active/`.

---

## 5. Next Steps

After presenting the report, I will ask:
- "Should I convert the excessive calls into optimization tasks?"
- "Would you like me to check if these calls can be cached on the frontend?"
- "Shall I investigate the backend logic for these specific endpoints?"

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "network-audit" --event complete \
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
