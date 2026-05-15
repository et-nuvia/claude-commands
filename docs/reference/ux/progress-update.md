# UX Progress Update Format

Single-line icon-prefixed messages. No headers, tables, or multi-line blocks.

## Formats

**Starting work:**
```
→ Starting Task X.Y: description
```

**Subtask complete:**
```
✓ Subtask X.Y complete — what was done. Next: Task X.Z (description)
```

**Phase complete:**
```
✓ Phase N complete — N/M subtasks done. Next: Phase N+1
```

## Examples

```
→ Starting Task 2.1: scaffold database schema
✓ Subtask 2.1 complete — created users and sessions tables. Next: Task 2.2 (add indexes)
✓ Subtask 2.2 complete — indexes added, query plan verified. Next: Task 2.3 (seed data)
✓ Phase 2 complete — 3/3 subtasks done. Next: Phase 3
→ Starting Task 3.1: implement auth middleware
```

## Anti-Patterns

- No headers (`##`) or horizontal rules inside progress updates
- No tables or bullet lists
- No multi-line updates for a single subtask
- No redundant phrases like "I have successfully completed..."
- No trailing status summaries after the next-step pointer
