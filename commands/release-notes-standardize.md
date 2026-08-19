---
name: release-notes-standardize
description: Standardize release notes to the multi-audience template with verified commit attribution
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You rewrite CI-generated release notes into the house non-technical format. **Use model: opus** — the whole value here is judgement about what a change means to a non-technical reader, which a generator cannot supply.

## Execute

```bash
~/.claude/scripts/release-notes-standardize.sh --version "${ARGUMENTS}"
```

Omit `--version` entirely when the user passed no argument — the script then targets the **most recent version only** (highest semver, not newest file mtime). Pass `--all` only if the user explicitly asks for every release.

The script returns, per target version: `filepath`, `release_date`, `commit_range`, `current_content`, and a `commits` array where each entry carries `sha`, `github_username`, `git_author_name`, `subject` and `pr`. Release-notes commits are already filtered out two ways — by `^docs(release)` subject prefix, and by path (any commit touching only `docs/release_notes/`, whatever its prefix). Never reintroduce them in any form; see rules 7 and 8. If `commits` comes back empty, that is the expected signal for a no-change release, not a script failure to work around.

## The Format

Follow `medical-clearance/docs/release_notes/v2.44.0.md`, established by commit `69d7dd6e`. Audience is **clinical and business staff** — GMs, Surgeons, CRNAs, Admins — not developers.

```markdown
# Release v0.3.0

**Release Date:** 2026-07-30

## Summary

One paragraph, plain language, naming the theme of the release and what it means
for the people using the app.

## What's New & Improved

### <outcome theme, e.g. Trusting the numbers on a signed agreement>

- **A bolded claim in the reader's terms.** What went wrong or was missing before,
  what that meant for them, and what is true now. (github_username, [`abc1234`])

### <another outcome theme>

- **Another claim.** … (github_username, [`def5678`, `9012abc`])

---

_Questions about this release? Contact the product team. For the full technical
change log, see the version history in the repository._
```

**Rules that make it read correctly:**

1. **Group by outcome, never by commit type.** "Fewer errors", "Faster experience", "Trusting the numbers" — not "Features / Bug Fixes / Chores". Several commits may collapse into one bullet, and one commit may split across two.
2. **Lead with the symptom, not the cause.** "Patient search no longer times out", not "added a database index".
3. **Attribution goes at the end of every bullet** as `(github_username, [commits...])` — use the `github_username` field, **never** `git_author_name`. One person often has several git names (a personal name locally, a bot-style name for squash merges, same email); the GitHub login is the stable identity. If a username came back with a `(git name — no GitHub account resolved)` suffix, keep the suffix so the reader knows it is unverified, and mention it in your summary to the user.
4. **No jargon anywhere**: no endpoint paths, scope names, field ids, class names, secret names, migration names, or config variables. There is no section of this document where they belong — if a change can only be explained in those terms, explain its effect instead.
5. **Collapse routine maintenance to one line** — e.g. "Applied security updates to underlying software libraries (routine vulnerability patching)." Do not enumerate dependency bumps.
6. **Keep work-record commits to a single closing bullet** under a `### Records & maintenance` heading, if you mention them at all.
7. **NEVER write about release notes or documentation.** A release-notes file must not describe edits to release notes or docs — not in the summary, not as a bullet, not under `Records & maintenance`, not in a footnote. The reader does not care that the document they are reading was rewritten. This holds even when a release-notes change is the *only* thing in the range: do not reach for it to fill the page.
8. **A range with no user-facing commits gets a no-change note, not an invented one.** When the script's `commits` array is empty, every commit in the range was filtered as release-notes/docs churn — so there is genuinely nothing to announce. Do not describe the filtered commits, and do not soften it into "updates and improvements". Write exactly this shape and stop:

   ```markdown
   # Release v0.0.0

   **Release Date:** YYYY-MM-DD

   ## Summary

   This release contains no changes to the application. There are no new features,
   no fixes, and nothing behaves differently. It is an internal maintenance release only.

   ---

   _Questions about this release? Contact the product team. For the full technical
   change log, see the version history in the repository._
   ```

   Omit the `## What's New & Improved` section entirely — an empty or padded one is worse than none. Do not add a footnote explaining the correction in this case; "no changes" needs no defence.

9. **NEVER write a pre-deployment section.** No `Before You Upgrade`, `Before You Deploy`, `Upgrade Notes`, `Deployment Steps`, `Migration Steps`, `Action Required`, or any renamed equivalent — not as a section, not as a bullet, not as a footnote. **These notes are written after the release has already shipped**, so instructions to do something beforehand are useless to every reader: nobody can act on them, and their presence implies a decision is still open when it is not. Required secrets, migrations, retired config variables, coordination ordering, and rollback steps belong in the task's RUN/TSK documents and the deployment runbook — which is where the operator who actually needed them already read them. Do not smuggle them back in as "Notes for administrators" or "Technical details" either. If a deployment step had a *user-visible consequence*, describe the consequence in the reader's terms as an ordinary bullet and say nothing about the step.

## Correctness Before Prose

The generated notes are frequently **wrong**, not merely terse — the generator reads commit subjects and cannot detect a behavioural change. Before writing:

1. **Find the changes that alter what someone experiences, not just what the code says.** A retired field, a validation that now rejects what it previously ignored, a removed endpoint, a newly required permission — these matter because of what a person or a partner system now *sees*: a screen that no longer loads, an integration that starts getting rejected, a value that stops appearing. Describe that effect as a normal bullet under an outcome heading. A generated file claiming "Breaking Changes: None" is not evidence of anything. Per rule 9, this never becomes a pre-deployment instruction — the deployment already happened.
2. **Commit hashes are pre-verified by the script** — every entry carries `sha_verified`, and the top level reports `shas_verified` (count) plus `shas_unresolved` (any that failed). Cite only hashes from the script's `commits` array, and never infer one from a PR number. Do NOT re-verify with your own `git cat-file` loop: a `for sha in ...; do ...; done` loop can never be auto-approved, so it just produces a permission prompt per batch for a check the script already did.
3. Read the diff or the task documents when a commit subject is too thin to explain in user terms. Do not guess at what a change did.

If you correct a factual claim from the previous version, add a one-line italic note at the foot of the file recording that it was rewritten and what was wrong — the edit should be visible, not silent.

## Write and Commit

Write each file to its `filepath` with the Write tool, then commit with a direct `git add` + `git commit` (do NOT use `/git-commit` for a doc-only change):

```bash
git add docs/release_notes/ && git commit -m "docs(release): rewrite <version> notes for non-technical readers"
```

Do not push. Release notes normally flow `prod → staging → dev`, so mention to the user that a rewritten file on one branch differs from the copies on the others, and let them decide whether to carry it forward.

## Report

State which version(s) you rewrote, any factual corrections you made to the previous text (especially breaking changes the generator missed), any hash that failed verification, and any `github_username` that fell back to a git name.

