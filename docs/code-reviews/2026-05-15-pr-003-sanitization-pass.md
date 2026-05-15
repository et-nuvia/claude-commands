# Code Review: PR #3 — Extract environment config into profile

**PR**: https://github.com/et-nuvia/claude-commands/pull/3
**Branch**: `sanitize/extract-profile-values` → `main`
**Author**: Eric Turner
**Reviewer**: Friendly AI Agent Assistant
**Date**: 2026-05-15
**Stats**: 8 commits · 43 files · +595 / −374

---

## Summary

Eight-commit refactor that extracts hardcoded personal and organizational
identifiers (self-hosted git host, registry, Infisical URL, Asana
workspace) out of production code and into a profile-driven config
layer. Adds `scripts/lib/load-profile.sh` as the keystone helper, then
sweeps 14 production scripts, 17 documentation files, 9 test files, and
2 templates. Bonus: also fixes four silently-broken subcommands in
`detect-environment.sh` that referenced helpers never sourced.

The PR is internally consistent, well-sequenced, and ships with a clear
fallback path (bundled example profile + stderr warning) so the system
still works for someone cloning before they configure anything.

## Scores

| Category | Weight | Score | Weighted |
|---|---|---|---|
| Minimal Changes | 0.20 | **9** | 1.80 |
| Security | 0.25 | **9** | 2.25 |
| Best Practices | 0.20 | **8** | 1.60 |
| Code Quality | 0.15 | **8** | 1.20 |
| Testing | 0.10 | **6** | 0.60 |
| Documentation | 0.05 | **9** | 0.45 |
| Git Hygiene | 0.05 | **10** | 0.50 |
| **Overall** | | | **8.40 / 10** |

## Critical Issues

None. Security scan returned **0 real secrets** (gitleaks flagged 190
"manual_secrets" but inspection shows all are doc substitutions like
`INFISICAL_URL: "https://secrets.turnersrus.com"` → `"https://secrets.example.com"`
or pre-existing variable references like `PRIVATE-TOKEN: ${GITLAB_TOKEN}`
shown in diff context — no new credentials introduced).

## Major Issues

### M1 — Subprocess invocation in Python is shell-quoted but not hardened

**File**: `scripts/docker-audit.py:42-51`, `scripts/project-config-detect.py:27-44`

The `_profile_get_env()` helper builds a bash command via f-string:

```python
["bash", "-c", f'source "{lib}" && profile_env_get "{yaml_path}"']
```

`yaml_path` comes from call sites today as hardcoded literals (`.git.instance`,
`.registry.host`), so this is safe in current use. **But** the pattern
will tempt future callers to pass user-controlled paths, at which point
a malicious YAML key containing `"; rm -rf /;"` would execute. Either:

1. Validate `yaml_path` against `^\.[a-z_.]+$` before interpolation, or
2. Use `subprocess.run([..., yaml_path], env={...})` with a small bash
   wrapper that reads the path from `$1`.

Confidence: 90. Not exploitable today, but a footgun the moment someone
plumbs user input through.

### M2 — `contributing.sh` compound conditional is hard to follow

**File**: `scripts/contributing.sh:119-127`

The "is this a personal project?" detection uses a nested compound
condition with backslash-continuations and an inline `personal_host=$(...)`
assignment inside the `{ ... }` group. It works, but reading it requires
parsing bash precedence rules. Extract to a small helper:

```bash
_is_personal_remote() {
  local url="$1" host
  [[ "$url" =~ personal ]] && return 0
  host=$(profile_env_get .git.instance 2>/dev/null)
  [[ -n "$host" && "$host" != "github.com" && "$host" != "gitlab.com" && "$url" == *"$host"* ]]
}
```

Then the `elif` becomes `elif [[ ! -f "CONTRIBUTING.md" ]] && _is_personal_remote "$remote_url"; then`.

Confidence: 85.

## Minor Issues

### m1 — `SECRETS_API_URL` computed unconditionally at script-top

**File**: `scripts/rotate-generic.sh:18`, `scripts/rotate-database.sh:14`,
`scripts/rollback-secret.sh:21`

```bash
SECRETS_API_URL="$(profile_env_get .secrets.url)/api"
```

If the profile is unset/missing the field, this becomes the bare string
`/api`, and the later `--domain /api` will fail at runtime with a confusing
error. Either guard the assignment, or fail fast at the top of `main()`:

```bash
[[ -n "$(profile_env_get .secrets.url)" ]] || { echo "secrets.url not configured in profile" >&2; exit 1; }
```

Confidence: 95. Won't bite during normal operation, but produces
confusing failures during onboarding.

### m2 — `detect-environment.sh` last-resort fallback still maps OS → env

**File**: `scripts/detect-environment.sh:81-84`

```bash
case "$(uname -s)" in
  Darwin) echo "work" ;;
  Linux)  echo "home" ;;
```

This is the original convention preserved as a "first-run with no profile"
fallback. The PR commit message acknowledges this. Considered fine for
backward compat, but the values `work` / `home` are still the *user's*
labels — someone forking for a team won't have an env named "home".
Worth a TODO comment pointing at the bundled `default.yaml.example` so
this fallback is the prompt-to-configure pattern, not a hidden default.

Confidence: 80.

### m3 — `load-profile.sh` warning fires on every accessor call

**File**: `scripts/lib/load-profile.sh:74-78`

When using the fallback profile, the WARN message prints on every call
that reaches `load_profile()`. Caller scripts that read multiple values
get the same warning 5–10 times. Cache the "warned already" state:

```bash
if [[ "$_PROFILE_IS_FALLBACK" == "1" && -z "${_PROFILE_WARNED:-}" ]]; then
  echo "load-profile: WARN ..." >&2
  _PROFILE_WARNED=1
fi
```

Confidence: 99. Cosmetic but irritating; observed during the
detect-environment smoke test.

### m4 — Renamed test relies on default.yaml.example as fixture

**File**: `scripts/tests/test-project-config-detect.py:436-444`

`test_gitlab_self_hosted_via_profile` happens to pass because the
bundled example has `git.example.com` as the home env instance, and the
test asserts against that same value. This is an implicit coupling: if
someone changes the bundled example, this test silently breaks (or
silently lies). Either:

1. Set `CLAUDE_PROFILE` explicitly to a fixture profile inside the test, or
2. Add a comment in `default.yaml.example` warning that the home env's
   `git.instance` is referenced by this test.

Confidence: 85.

### m5 — `pipeline-create.sh` REPLACE_ME placeholder

**File**: `scripts/pipeline-create.sh:407`

When neither PROJECT.yaml nor profile has a registry, the generated
pipeline contains `REGISTRY: REPLACE_ME.example.com`. That's a deliberate
"force the user to notice" choice — good — but the generated pipeline
will still be written. Worth a stderr warning on the script side so the
user knows to edit the output, not just on the next CI run failing.

Confidence: 85.

## Positive Highlights

- **Sequencing**: 8 commits land in a logical order (foundation → groups
  → cleanup → docs → tests). Each commit drops the leak count and is
  independently reviewable. This is exemplary git hygiene.
- **`load-profile.sh` API design**: clean separation between `profile_get`
  (root-level) and `profile_env_get` (environment-block), with a
  `profile_is_fallback` for callers that need to gate side effects. The
  resolution order (`$CLAUDE_PROFILE` → `$CLAUDE_HOME` → `~/.claude/` →
  bundled example) is explicit and well-documented.
- **Bonus fix to broken subcommands**: `detect-environment.sh` had four
  subcommands calling helpers that didn't exist anywhere. Fixing this
  while the file was open is the right scope-management instinct —
  bundled in the same commit, called out in the commit message.
- **Python ↔ bash bridge pattern**: `_profile_get_env()` subprocess
  pattern is duplicated in two files but is small enough that DRY-ing
  it would be premature; documenting it as "the pattern" via the second
  occurrence is reasonable.
- **Test renaming**: `test_gitlab_turnersrus_url` → `test_gitlab_self_hosted_via_profile`
  isn't just sanitization — it reflects what the test actually validates
  after the refactor. The comment explaining the implicit fixture
  dependency is honest and useful.
- **Conservative fallback behavior**: a fresh clone with no profile
  doesn't crash — it falls back to the bundled example with a loud
  warning. The 0→1 onboarding step is guarded.
- **Documentation**: detect-environment.sh has a "historical note" comment
  explaining what the refactor replaced and why. Future readers will
  thank you.

## File-by-File Notes

| File | Notes |
|---|---|
| `scripts/lib/load-profile.sh` | New keystone, 197 lines. API solid. Apply m3 (warning dedup). |
| `scripts/detect-environment.sh` | -250/+140. Cleanest refactor in the set. Apply m2 (TODO). |
| `scripts/task-*.sh` (4 files) | Consistent pattern; load profile, replace URL. Good. |
| `scripts/lib/task-close-complete.sh` | Defensive `source` is correct since file is sourced not invoked. |
| `scripts/rotate-*.sh`, `rollback-secret.sh` | Apply m1 (fail-fast guard). |
| `scripts/pipeline-create.sh` | Apply m5 (stderr warning on placeholder). |
| `scripts/monitor-pipeline.sh` | Now errors clearly when GITLAB_INSTANCE missing — good. |
| `scripts/docker-audit.py` | Apply M1 (path validation). |
| `scripts/project-config-detect.py` | Apply M1. Branch reorder (public hosts first) is correct. |
| `scripts/review-pr.sh` | Two-line substitution, clean. |
| `scripts/contributing.sh` | Apply M2 (extract helper). |
| `scripts/get-task-config.sh` | Help message now correct for any GitLab instance. |
| `profiles/default.yaml.example` | New `secrets.url` field documented in comment. |
| `docs/reference/*` (15 files) | Bulk text substitution. Spot-checked: reads naturally. |
| `scripts/tests/*` (9 files) | Apply m4 (explicit fixture or warning comment). |

## Recommendations

**Merge?** Yes — with no blockers. The major items M1 and M2 are
defensive hardening (M1) and readability (M2); neither blocks the
sanitization goal.

**Suggested follow-up before merge** (small, ~30 min):
- m1 (`SECRETS_API_URL` guard) — three identical one-liners
- m3 (warning dedup in load-profile.sh) — one-line cache
- m4 (test fixture comment) — single comment

**Defer to follow-up PRs**:
- M1 (subprocess hardening) — needs design discussion, not urgent
- M2 (contributing.sh helper) — pure readability
- m2, m5 — nice-to-haves

**Post-merge sequence** (already noted in PR description):
1. Cutover — create `~/.claude/profiles/active.yaml`, run `./install.sh`,
   verify daily workflow
2. Issue #1 — git platform adapter shims
3. Issue #2 — secrets manager adapter shims

The platform/secrets shim issues are unblocked by this PR and should
land before this codebase is widely shared, because they're the
remaining sharp edges that limit who can adopt it without forking.

---

*Friendly AI Agent Assistant*
