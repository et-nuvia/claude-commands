# UX: Commit Confirmation Format

Standard format for presenting commits to users before execution.

## Layout

Use a table for the commit overview, followed by bodies shown separately.

### Single Commit

```
Commit Plan

  ┌─────┬─────────────────────────────────────────────────────┬───────────────────────────────────────┬────────┐
  │  #  │                        Title                        │                 Files                 │  +/-   │
  ├─────┼─────────────────────────────────────────────────────┼───────────────────────────────────────┼────────┤
  │ 1   │ fix(nginx): redirect HTTP frontend traffic to HTTPS │ nginx/templates/default.conf.template │ +3/-10 │
  └─────┴─────────────────────────────────────────────────────┴───────────────────────────────────────┴────────┘

  Body:
  ▎ Replace the HTTP frontend proxy with a 301 redirect to HTTPS.
  ▎ API and AI endpoints remain on HTTP for internal health checks
  ▎ and smoke tests that connect via port 80.
```

### Multiple Commits

```
Commit Plan

  ┌─────┬─────────────────────────────────────────────────────┬───────────────────────────────────────────┬─────────┐
  │  #  │                        Title                        │                  Files                    │   +/-   │
  ├─────┼─────────────────────────────────────────────────────┼───────────────────────────────────────────┼─────────┤
  │ 1   │ feat(scripts): add shared logging library           │ scripts/lib/logging.sh                    │ +85/-0  │
  │ 2   │ refactor(scripts): replace yq calls with yaml_get   │ scripts/task-start.sh, scripts/task-fe... │ +24/-18 │
  │ 3   │ chore: remove orphaned deploy scripts               │ scripts/deploy-staging.sh (D), scripts... │ +0/-477 │
  └─────┴─────────────────────────────────────────────────────┴───────────────────────────────────────────┴─────────┘

  1 ▎ New unified logging library with log_info/success/error/warn/debug.
    ▎ All output to stderr, suppressed when OUTPUT_MODE=json.

  2 ▎ Replaces 13 direct yq eval calls with yaml_get() for
    ▎ cross-platform macOS/WSL compatibility.

  3 ▎ Legacy deploy-staging.sh and deploy-production.sh replaced
    ▎ by deploy-to-stage.sh and deploy-to-prod.sh.
```

## Rules

- **Table columns**: `#`, `Title`, `Files`, `+/-`
- **Files column**: Show filenames (not full paths if in same directory). Truncate with `...` if too many. Append `(D)` for deleted, `(N)` for new files.
- **+/- column**: Net insertions/deletions across all files in the commit
- **Body section**: Prefixed with commit number and `▎` bar. Wrap at 72 chars. Explain WHY, not WHAT.
- **Table width**: Auto-size columns to content. Title column is the widest.
- **Ask for approval**: End with the AskUserQuestion tool offering "Approve" and "Edit plan" options

## Anti-Patterns

- No raw diffs or patch hunks — stats (+/-) are enough
- No omitting the body — always explain why
- No "Co-Authored-By: Claude" in commit messages
- No leading `./` in file paths
- No body text inside the table — bodies go below
