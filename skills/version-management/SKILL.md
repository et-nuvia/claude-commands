---
name: version-management
description: How project versions are derived (git tags + conventional commits, with version-file fallback), the get-version.sh retrieval script, and Docker image version tagging per environment. Load when determining, bumping, or tagging a project version, or naming a release.
---

# Version Management

Semver `MAJOR.MINOR.PATCH`.

## Sources

**Primary — git tags + conventional commits:**

| Commit type | Bump |
|---|---|
| `feat:` | minor |
| `fix:` | patch |
| `BREAKING CHANGE:` | major |

Tags are auto-created after a successful production deployment — **no manual bumps**.

**Legacy fallback — version files** (VERSION, package.json, pyproject.toml, Cargo.toml, pom.xml, build.gradle) via optional `version_file` in PROJECT.yaml. Only when tags are unavailable, or for published packages.

## Retrieval

```bash
~/.claude/scripts/get-version.sh          # tags first, file fallback
~/.claude/scripts/get-version.sh -g       # tags only
~/.claude/scripts/get-version.sh -f <file> # specific file
```

Check the deployed version before baking a version into a task or document name — don't extrapolate from prior tasks.

## Docker image tags

- **Build time**: clean version (`1.2.3`)
- **Staging**: `1.2.3-staging.1234`
- **Production**: `1.2.3`
- **Runtime display version**: computed from `ENVIRONMENT`

**See**: [Version Management Guide](docs/version-management.md)
