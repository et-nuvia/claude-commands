# Anti-Rationalization Guards

These tables counter common LLM rationalizations for skipping mandatory process steps. Scripts and CI enforce hard rules, but softer decisions — "is this too small for a plan?" or "does this need review?" — rely on judgment. These pre-loaded counter-arguments exist so the right answer is recalled before the shortcut is taken.

---

## Testing

| Shortcut Thought | Reality | What To Do Instead |
|---|---|---|
| "This is just a simple fix, no tests needed" | Simple fixes are the most common source of regressions. Simplicity is not a proxy for safety. | Write a targeted unit test for the fix. Run `make test` to confirm it passes and coverage stays >= 80%. |
| "The existing tests cover this implicitly" | Implicit coverage is untested coverage. If no test explicitly exercises the changed path, the behavior is unverified. | Check coverage output from `make test`. If the changed lines aren't hit, add a test that hits them. |
| "I'll add tests later" | Later never comes. Once the task is closed, there is no forcing function. The debt compounds into the next task. | Write the test now, before marking the work done. TDD means the test comes first, not last. |
| "This is just a refactor, tests would be redundant" | Refactors change structure without changing behavior — which means tests are the only way to prove behavior was preserved. | Run the existing suite first. If coverage is below 80%, add tests before refactoring, not after. |
| "Mocking this would be too complex" | If mocking is complex, the dependency is too tightly coupled. That's a design signal, not a test exemption. | Mock at the boundary (external I/O, network, DB). If the boundary is hard to reach, refactor the coupling — then test. |
| "The type checker / linter already caught the issue" | Static analysis finds type errors. It does not find logic errors, edge cases, or integration failures. | Static analysis and tests are complementary. Run both via `make test` and `make lint`. |

---

## Planning

| Shortcut Thought | Reality | What To Do Instead |
|---|---|---|
| "This is small enough to do without a plan" | Small tasks with no plan are where unintended scope creep and missed edge cases hide. A 10-minute plan prevents a 2-hour rework. | Use `/task-plan` to produce a PLN document. Even a short plan forces the right questions upfront. |
| "The requirements are obvious" | Requirements that feel obvious are the ones most likely to contain unstated assumptions. Those assumptions become bugs. | Write the plan anyway. The act of writing surfaces assumptions. Check `plan-progress.sh --json` to track against it. |
| "Planning would take longer than just doing it" | Implementation without a plan takes longer than implementation with one. The plan is recovered during debugging, not avoided. | Time-box the plan to 15 minutes. A brief PLN document is sufficient. Use `/task-plan` to start. |
| "I already know the approach" | Knowing the approach is different from having verified it against the full scope, edge cases, and integration points. | Document the approach in a PLN file. Review it against the task requirements before writing code. |

---

## Code Review

| Shortcut Thought | Reality | What To Do Instead |
|---|---|---|
| "The changes are trivial, review is overkill" | Trivial changes are the ones that get committed without scrutiny and then cause subtle production issues. Trivial is not the same as correct. | Run `/task-audit` to get an objective view of test coverage, scope, and side effects before closing. |
| "I wrote this carefully, it doesn't need review" | Care during authorship does not substitute for a second pass. The author is the least qualified reviewer of their own work. | Use `/task-code-review` to produce a CRV document. Review your own diff as if someone else wrote it. |
| "It's just config or docs changes" | Config changes break production more often than code changes do. Docs that are wrong are worse than no docs. | Config changes: verify every key against its consumers. Docs changes: verify every claim is still accurate. Run `/task-audit`. |
| "The tests pass so it must be correct" | Tests verify what was thought to test. They do not verify what was forgotten to test, security properties, or operational concerns. | Passing tests are necessary but not sufficient. Use `/task-code-review` to check security, error handling, and unintended side effects. |
| "I'll catch it in staging" | Staging is for integration testing, not for catching basic review items. Bugs caught in staging cost more than bugs caught in review. | Do the review before merging. Use the CRV document from `/task-code-review` as a checklist. |

---

## Deployment

| Shortcut Thought | Reality | What To Do Instead |
|---|---|---|
| "This change is too small to need a staging deploy" | Production has configuration, data, and traffic patterns that staging exposes and local does not. Size is not a reliable proxy for safety. | Run `/deploy-risk` to score the change. Even low-risk changes require a staging pass via `/deploy-to-stage` before production. |
| "CI passed, so it's safe to deploy" | CI validates syntax, tests, and lint. It does not validate infrastructure config, environment-specific behavior, or interaction with live data. | CI passing is the floor, not the ceiling. Run `~/.claude/scripts/ci-lint-local.sh --json --full` and verify smoke tests pass in staging before promoting. |
| "We can always roll back if something breaks" | Rollback is a recovery mechanism, not a release strategy. It requires downtime, risks data inconsistency, and burns trust. | Use `~/.claude/scripts/deployment-rollback.sh` if rollback is genuinely needed — but run `/deploy-risk` before deploying so rollback is a last resort, not the plan. |
| "It's just a dependency update, low risk" | Dependency updates are the leading cause of silent behavioral regressions. Transitive changes are invisible at review time. | Treat dependency updates as code changes. Run the full test suite, check for license changes, and deploy to staging before production. |
| "Smoke tests are overkill for this change" | Smoke tests catch broken critical paths in under a minute. Skipping them to save a minute is the classic false economy. | Let `~/.claude/scripts/smoke-tests.sh` run automatically. Monitor with `pipeline-watch.sh`. If a smoke test is wrong, fix the test — don't skip it. |
| "I'll watch the metrics after deploy instead of running checks first" | Post-deploy monitoring detects failures after users are affected. Pre-deploy checks detect failures before they reach users. | Run `/deploy-to-stage` with smoke tests first. Only promote to production after staging health checks pass via `check-health.sh`. |

---

## Error Handling

| Shortcut Thought | Reality | What To Do Instead |
|---|---|---|
| "This API call won't fail in practice" | Every network call fails eventually — timeouts, rate limits, transient errors, and upstream deploys all cause failures that "won't happen in practice." | Wrap external calls with explicit error handling. Honor the retry budget (max 3 retries with backoff). Log failures with structured output so they are diagnosable. |
| "The framework handles errors automatically" | Frameworks handle uncaught exceptions by returning 500s or crashing. They do not provide context, trigger alerts, or implement graceful degradation. | Handle errors explicitly at each boundary. Use error boundaries for UI components. Log structured errors with enough context to diagnose without reproducing. |
| "Adding error handling clutters the code" | Unhandled errors clutter production logs, confuse users, and cause 3am incidents. The "clutter" objection trades a minor authorship inconvenience for a major operational cost. | Error handling belongs at the boundary, not inlined. Extract a handler function if the inline form is truly cluttered. The code is not cleaner for being fragile. |
| "We'll add proper error handling when we productionize" | Code that reaches staging is code that reaches production. There is no formal "productionize" gate. Technical debt in error handling is paid with incidents, not refactors. | Add error handling now. If the scope is large, capture it as a task item in the PLN document and do not close the task until it is done. |
| "A generic catch-all is good enough" | A catch-all swallows the error type, discards the context, and makes the root cause invisible. It is harder to debug than no handling at all. | Catch specific error types. Log the full error with structured fields (error type, message, stack, request context). Use a catch-all only as a last resort and always re-log with full context. |
