# Code Review: PR #6 — Secrets manager shim foundation

**PR**: https://github.com/et-nuvia/claude-commands/pull/6
**Branch**: `feat/secrets-manager-shims` → `main`
**Author**: Eric Turner
**Reviewer**: Friendly AI Agent Assistant
**Date**: 2026-05-15
**Stats**: 1 commit · 7 files · ~700 lines added

---

## Summary

Foundation for [#2](https://github.com/et-nuvia/claude-commands/issues/2).
Mirrors the structure of the git platform shims (PR #5) for the secrets
layer. Adds a dispatcher (`scripts/lib/secrets-api.sh`) and three full
adapters under `scripts/lib/secrets-backends/`: Infisical (CLI-based),
AWS Secrets Manager (CLI-based), and a `none` no-op backend for users
without a secrets manager. Adds 5 bats contract tests including a
functional smoke test of the `none` adapter's exit codes.

**No script migrations.** Same discipline as #5 — foundation lands
first, then individual migration PRs swap the 20+ direct `infisical` /
`aws secretsmanager` calls scattered across rotation, bootstrap, and
audit scripts.

The work is well-paced, internally consistent with #5, and adds two
thoughtful refinements not present in the git-platform foundation: the
`none` adapter for opt-out, and `sm_ui_url` for human-facing help
messages.

## Scores

| Category | Weight | Score | Weighted |
|---|---|---|---|
| Minimal Changes | 0.20 | **10** | 2.00 |
| Security | 0.25 | **10** | 2.50 |
| Best Practices | 0.20 | **8** | 1.60 |
| Code Quality | 0.15 | **8** | 1.20 |
| Testing | 0.10 | **7** | 0.70 |
| Documentation | 0.05 | **10** | 0.50 |
| Git Hygiene | 0.05 | **10** | 0.50 |
| **Overall** | | | **9.00 / 10** |

## Critical Issues

None. Security clean across all scanners:
- Trivy: 0 / 0 / 0 / 0 (critical / high / medium / secrets)
- Semgrep: 0 issues
- Gitleaks: 0 findings
- 114 "manual_secrets" from grep are all textual references in
  identifiers, paths, and doc strings (`secrets.backend`,
  `secrets-api.sh`, "AWS Secrets Manager", etc.). Predictable noise for
  a PR about secrets management. No actual credentials introduced.

> Note: the script set `critical_block: true` because `manual_secrets > 0`
> triggers the flag regardless of content. Same false-positive
> cascade as PRs #3 and #5. Worth fixing in `review-pr.sh` someday.

## Major Issues

### M1 — `sm_set_json` semantics differ between adapters

**Files**: `scripts/lib/secrets-backends/{infisical.sh,aws-sm.sh}`,
**plus**: `scripts/lib/secrets-backends/README.md`

The contract README says:

> `sm_set_json <env> <path> <json>` — replaces ALL keys at path

But:
- **`aws-sm.sh`** honors this — it calls `put-secret-value` with the
  whole new blob, replacing everything.
- **`infisical.sh`** does NOT — it iterates the JSON and sets each key
  via `infisical secrets set k=v`. Keys present at the path but not in
  the new JSON are left untouched.

The Infisical CLI has no native "replace all" operation, which is the
underlying problem. Three resolutions:

1. **Make the contract match reality**: change README to "merges keys
   from the JSON into the path; preserves existing keys not in the JSON."
   AWS implementation still satisfies this (a complete blob = a merge
   that incidentally clobbers everything). Easiest fix.
2. **Implement true replace in Infisical**: `sm_get_json` first → diff
   keys → delete missing → set new. More correct but more code and
   another round trip.
3. **Add `sm_replace_json` as a distinct function** alongside
   `sm_set_json`, with the contract documenting that some adapters
   may return exit 3 for replace.

I'd recommend #1 for now — the only existing callers (rotation
scripts) write the complete intended state anyway, so merge semantics
are functionally equivalent for them. Document the distinction so a
future caller doesn't bet on replace semantics.

Confidence: 90.

### M2 — `sm_set` on AWS SM has a TOCTOU race

**File**: `scripts/lib/secrets-backends/aws-sm.sh:88-106`

```bash
blob=$(_aws_get_secret_blob "$env" "$path" 2>/dev/null)
if [[ -z "$blob" ]]; then
  ...
else
  new_blob=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$blob")
  _aws_call put-secret-value --secret-id "$name" --secret-string "$new_blob" >/dev/null
fi
```

Read-modify-write without optimistic locking. Two concurrent
`sm_set` calls against the same secret will both fetch the original
blob, both compute a merged new blob with only their own key, and the
second one to put will silently clobber the first.

AWS SM offers `ClientRequestToken` for idempotency but not native
optimistic locking — the cleaner fix is to use `update-secret` with the
returned `VersionId` as a precondition (via the SDK; CLI may not
support).

For the current call sites (rotation scripts that run single-process
during scheduled rotation windows), this won't bite. Worth flagging
because:

1. As more code starts using `sm_set`, the assumption may not hold
2. A simple `# WARNING: not safe for concurrent callers` comment in the
   function would prevent future misuse

Confidence: 85.

## Minor Issues

### m1 — `sm_versions` on AWS silently ignores the `key` arg

**File**: `scripts/lib/secrets-backends/aws-sm.sh:148-152`

```bash
sm_versions() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  # key is part of the contract but AWS SM versions the whole blob, not
  # individual keys. Ignore the key arg; documented in contract README.
```

The comment says it's documented in the README, but the README's
contract table just says "Returns: JSON array `[{version, created_at,
is_current}]`" without explaining that the result is per-blob (covering
all keys) on AWS vs theoretically per-key on Infisical (which returns
empty anyway).

Either:
1. Update the contract README to clarify: "Returns version history of
   the whole secret blob (AWS) or empty (Infisical, no CLI support);
   the `<key>` argument is reserved for future per-key version backends."
2. Print a stderr note when called on AWS so users aren't surprised.

Confidence: 85.

### m2 — `sm_health` on Infisical only verifies auth, not project access

**File**: `scripts/lib/secrets-backends/infisical.sh:160-169`

```bash
if ! infisical user "${_INFISICAL_DOMAIN_ARGS[@]}" >/dev/null 2>&1; then
  echo "sm_health(infisical): CLI not authenticated ..."
```

`infisical user` confirms the CLI can talk to the instance and the
user is logged in, but doesn't confirm the user has access to the
specific project that secrets will be read from. A stronger check
would try a read against a known path:

```bash
infisical secrets --env "${_INFISICAL_HEALTH_ENV:-staging}" --path /  ...
```

Reasonable to skip for now — `sm_health` is primarily a "is this even
configured?" check, not a "can I do everything?" probe.

Confidence: 80.

### m3 — Test #3 conditional logic is awkward

**File**: `scripts/tests/test-secrets-api-contract.bats:36-51`

```bash
@test "dispatcher: aws-secrets-manager alias maps to aws-sm" {
  ...
  if [ "$status" -eq 0 ] && [ -n "$output" ]; then
    [[ "$output" == *"aws-sm"* ]]
  else
    # CLI missing path — verify the resolver picked the right filename
    ...
```

The test branches on whether the aws CLI is installed, asserting
different things in each case. This makes the test pass on machines
without `aws` (good for portability) but the dual-path assertion is
hard to read and easy to misread as "test the alias works OR test the
error message — either is fine."

Cleaner alternative: stub out `aws` (and `infisical`) in the test
setup with a `command_not_found` script, OR refactor to test the alias
mechanism without sourcing the actual adapter:

```bash
@test "dispatcher: aws-secrets-manager alias maps to aws-sm filename" {
  SM_ADAPTER_OVERRIDE=aws-secrets-manager run bash -c \
    'source scripts/lib/secrets-api.sh; load_sm_adapter 2>&1 || true' 
  # Whatever path we took (success or load failure), the resolved
  # filename must reference aws-sm.sh
  [[ "$output" == *"aws-sm"* ]]
}
```

Confidence: 80. The current test works; the readability concern is real
but small.

### m4 — `_aws_get_secret_blob` returns rc 1 vs rc 2 for missing app_name vs missing secret

**File**: `scripts/lib/secrets-backends/aws-sm.sh:62-67`

`_aws_secret_name` returns 1 when `_AWS_APP_NAME` is missing.
`_aws_call get-secret-value` returns 2 when the secret doesn't exist.
Both propagate up through `_aws_get_secret_blob`. Callers see:

- exit 1 → "couldn't form a secret name" (configuration error)
- exit 2 → "secret doesn't exist" (data state)

The distinction is correct, but a caller doing `sm_get x y z || return $?`
to map both to a sensible UX may not realize they need to branch.

Minor — the contract documents the exit codes and callers should read
them. Worth noting in case a future improvement wants a unified "not
ready" exit for configuration issues.

Confidence: 80.

## Positive Highlights

- **Scope discipline maintained**: again, foundation only, no script
  migrations. The PR description spells out the migration groups
  upcoming. This is now the pattern, and it's the right pattern.
- **`none` adapter**: thoughtful addition not present in the git
  shim PR. Users without a secrets manager can still source the API
  without scripts breaking on `sm_health` etc. The exit code semantics
  (read → 2, write → 3, health → 0) are well-chosen.
- **`sm_ui_url`**: another addition not in #5. AWS adapter generates a
  proper console deep-link with the secret name and region embedded;
  Infisical falls back to the instance home. Genuinely useful for
  error-message UX.
- **Path translation rules** in the README: explicit table showing
  `/database` → Infisical `/database` vs AWS `<app>/<env>/database` is
  the kind of documentation that prevents "wait, what's the secret
  called in AWS?" confusion.
- **Gotcha documented inline**: the `null.sh` → `none.sh` rename
  (caused by `yq` returning the string `"null"` for missing keys) is
  documented both in the renamed file's header comment and in the
  commit message. Future readers will understand why.
- **Alias resolution**: dispatcher accepts `aws`, `aws-secrets-manager`,
  `aws_secrets_manager` and maps all three to `aws-sm`. Reduces
  configuration friction without proliferating filenames.
- **Defensive `_AWS_APP_NAME` resolution**: doesn't fail at source-time
  (only when an op actually needs it), so `sm_health` and `sm_ui_url`
  remain useful even on a misconfigured project.
- **Functional smoke test**: bats test #5 actually exercises the
  `none` adapter's contract (`sm_get` → 2, `sm_get_json` → `{}`,
  `sm_set` → 3, `sm_health` → 0). Not just "does it source" — "does
  it behave."
- **`sm_restore` on Infisical**: returns exit 3 with clear manual UI
  instructions instead of silently failing. Honest about CLI
  limitations.
- **AWS secret naming convention spelled out**: `<app>/<env>/<path>`
  with the rationale documented in the file's top comment. No mystery.
- **Stderr translation pattern reused**: both `_infisical_call` and
  `_aws_call` translate "not found" stderr patterns to exit 2, matching
  the `_gh_get` pattern from PR #5. Cross-PR consistency.

## File-by-File Notes

| File | Notes |
|---|---|
| `scripts/lib/secrets-api.sh` | 66 lines. Dispatcher + alias resolution. Clean. |
| `scripts/lib/secrets-backends/README.md` | Apply M1 wording, m1 clarification. |
| `scripts/lib/secrets-backends/infisical.sh` | Apply m2 (stronger health check, optional). |
| `scripts/lib/secrets-backends/aws-sm.sh` | Apply M2 (TOCTOU warning comment), m4 (exit-code note). |
| `scripts/lib/secrets-backends/none.sh` | 21 lines. Simple, correct. No issues. |
| `scripts/tests/test-secrets-api-contract.bats` | Apply m3 (test #3 readability). |
| `profiles/default.yaml.example` | Single comment edit, correct. |

## Recommendations

**Merge?** Yes — with no blockers.

**Suggested follow-up before merge** (~30 min):

- **M1** — README wording fix (5 minutes; just say "merges or
  replaces, adapter-specific" and acknowledge AWS replaces / Infisical
  merges)
- **M2** — TOCTOU warning comment on `sm_set` in aws-sm.sh (2 minutes)

**Defer to follow-up PRs**:

- **m1** — version semantics doc clarification (bundle with M1)
- **m2** — stronger Infisical health check (probably not needed)
- **m3** — test readability cleanup
- **m4** — exit code unification note

**Post-merge sequencing**:

1. Land this PR.
2. With #5 and #6 both merged, the foundation is fully in place. Two
   parallel migration tracks become possible:
   - Git-platform migration PRs (per the #5 plan)
   - Secrets-manager migration PRs (per the #6 plan)
3. Start with the smallest migration in each track to validate
   end-to-end:
   - Git track: task lifecycle group
   - Secrets track: rotation group (`rotate-generic.sh`,
     `rotate-database.sh`, `rollback-secret.sh`)
4. After all migrations land in both tracks, add the pre-commit hook
   that blocks direct `gh`/`glab`/`infisical`/`aws secretsmanager`
   calls outside the adapters.

The foundation is solid. Land it.

---

*Friendly AI Agent Assistant*
