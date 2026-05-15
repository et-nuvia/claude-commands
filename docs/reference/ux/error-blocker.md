# UX Error & Blocker Format

Problem + action only. No breakdowns, no bullets within the message, no "Error:" labels.

## Formats

**Recoverable error** — agent can retry or self-correct:
```
✗ What failed. Action to take.
```

**Blocking error** — cannot proceed without user:
```
✗ What failed — cannot proceed. User must: action.
```

**Intervention needed** — ambiguous, user chooses path:
```
⚠ What needs attention. Options: A or B.
```

## Examples

```
✗ Tests failed (3/12). Fix failing assertions in auth_test.go before continuing.

✗ No PROJECT.yaml found — cannot proceed. User must: run /project-config init.

⚠ Migration has breaking changes. Options: create rollback snapshot first, or proceed without one.
```

## Anti-Patterns

- `✗ Error: failed to connect` — don't prefix with "Error:"
- `✗ Build failed.\n  - Missing dependency\n  - Wrong version` — no sub-bullets
- `✗ The build process encountered an unexpected failure condition` — no passive voice
- `⚠ Warning: this might be a problem` — don't prefix with "Warning:"
- Multi-sentence problem descriptions — one crisp sentence only
