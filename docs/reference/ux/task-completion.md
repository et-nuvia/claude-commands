# UX: Task Completion Format

Single-line completion messages for tasks and commands.

## Formats

```
✓ Task complete — <what was delivered>. Next: /<suggested-command>
✓ <DOC-TYPE> created: <filename>. [<score/status>]
✓ Deployed to <env> — v<version> live. Next: /<suggested-command>
```

## Examples

```
✓ Task complete — auth middleware added with JWT validation. Next: /task-audit
✓ AUD created: 42D463-20260314-AUD-auth-middleware.md. Score: 87/100 (PASS)
✓ CRV created: 42D463-20260314-CRV-auth-middleware.md. 2 issues found.
✓ Deployed to staging — v1.4.2 live. Next: /deploy-to-prod
✓ Task complete — database migration scripts added. Next: /task-close
```

## Rules

- Single line — icons: ✓ success, ✗ failure, ⚠ partial
- Include score/status only when the command produces one
- `Next:` optional but preferred when a natural follow-up exists
- No `Next:` on final steps (e.g., /task-close)

## Anti-Patterns

- No multi-line summaries or "I have successfully completed..." prose
- No repeating the user's request — describe what was delivered
