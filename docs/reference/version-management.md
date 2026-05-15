# Version Management Guide

**Philosophy**: Git tags are the single source of truth. Calculate versions from tags + commits, burn into images at build time, create tags only on successful production deployment.

---

## Single Source of Truth: Git Tags

**No VERSION files.** Git tags capture:
- ✅ Exact code snapshot
- ✅ Semantic version
- ✅ Deployment history
- ✅ Easy rollback (`git checkout v1.2.3`)

**Git tags created automatically** by CI/CD after successful production deployment.

---

## Semantic Versioning

Format: `MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes (1.2.3 → 2.0.0)
- **MINOR**: New features, backwards compatible (1.2.3 → 1.3.0)
- **PATCH**: Bug fixes, backwards compatible (1.2.3 → 1.2.4)

### Conventional Commits Determine Bump Type

| Commit Prefix | Bump Type | Example |
|--------------|-----------|---------|
| `BREAKING CHANGE:` or `!` | MAJOR | `feat!: redesign API` |
| `feat:` | MINOR | `feat(auth): add OAuth2` |
| `fix:` | PATCH | `fix(api): handle null values` |
| Other | PATCH | `docs: update README` |

---

## Version Calculation Script

### Usage

```bash
# Show current version from latest git tag
~/.claude/scripts/version.sh show

# Calculate next version from commits
~/.claude/scripts/version.sh calculate

# Create git tag (manual - normally done by CI/CD)
~/.claude/scripts/version.sh create "Production release 1.2.3"
```

### How It Works

1. **Find latest tag:** `git describe --tags --abbrev=0 --match "v*.*.*"`
2. **Get commits since tag:** `git log v1.2.3..HEAD`
3. **Analyze commits:** Look for `feat:`, `fix:`, `BREAKING CHANGE:`
4. **Calculate bump:** major/minor/patch
5. **Return next version:** e.g., `1.3.0`

---

## PROJECT.yaml Configuration

**No version_file needed:**

```yaml
name: "my-app"
description: "My application"
# version_file: ""  # Not used - versions come from git tags

version_source: git-tags  # Document that versions come from git tags
```

---

See ~/.claude/docs/version-management.md.backup for full documentation
