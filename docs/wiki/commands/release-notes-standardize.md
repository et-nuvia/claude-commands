---
command: release-notes-standardize
group: git
backing_script: ~/.claude/scripts/release-notes-standardize.sh
mutates: [files]
runtime: ~1min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /release-notes-standardize

Rewrites release notes into the multi-audience template, with every
bullet attributed to a verified GitHub username rather than to whatever
name the contributor had configured locally.

---

## When to use it

- Release notes written ad hoc that need to match the house format
- Before publishing notes to a non-technical audience
- Standardizing a backlog of past releases

## Usage

```bash
/release-notes-standardize [version]
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | A version (`v0.3.0` or `0.3.0`). Defaults to the most recent; `--all` rewrites every file. |

## Backing script

**Script**: `~/.claude/scripts/release-notes-standardize.sh`

```bash
~/.claude/scripts/release-notes-standardize.sh --version v0.3.0
~/.claude/scripts/release-notes-standardize.sh --all
~/.claude/scripts/release-notes-standardize.sh --notes-dir <path>
```

Defaults to `docs/release_notes/`. Versions are ordered by semver, so
"most recent" means the highest version rather than the newest file.

## How it works

The script does the deterministic half — pick the version, resolve its
commit range, map every commit to its GitHub username, and read the
current file — then hands off the prose.

Commits that only touch release notes are dropped whatever their subject
prefix: a release-notes file must never describe edits to release notes.
Every SHA is resolve-checked in-script, so the caller never has to verify
hashes it is about to transcribe.

## Notes & gotchas

- **Attribute with `github_username`, never `git_author_name`.** One
  person routinely has several git names — a personal name locally, a
  bot-style name for squash merges — against the same email. The GitHub
  login is the stable identity.
- A name that came back with a `(git name — no GitHub account resolved)`
  suffix is unverified. Keep the suffix; it is the difference between a
  confirmed attribution and a guess.

---

**See also:** [`/create-pr`](create-pr.md) · [`/deploy-to-prod`](deploy-to-prod.md)
