# Git Best Practices

Guidelines for effective version control and collaboration.

---

## Commit Messages

### Conventional Commits Format

```
type(scope): brief description

Body explaining WHY, not WHAT (the diff shows what).
Reference issues/tickets.

Closes #42
```

**Types**: `feat`, `fix`, `test`, `refactor`, `docs`, `chore`, `perf`, `ci`

### Examples

```
# Good
feat(api): add language version filtering for dependencies

Implements language version constraint checking when fetching
dependency updates. This ensures users only see updates compatible
with their current PHP/Node version.

Filters GlobalPackageVersion records based on requires_language_version
field and compares against MonitoredFile.language_version.

Closes #42

# Bad
updated stuff
changed some files
fix
wip
```

---

## Commit Strategy

### Single Purpose Per Commit

Each commit does exactly one thing:

```bash
# Good - atomic commits
git commit -m "test(auth): add test for email validation"
git commit -m "feat(auth): implement email validation"
git commit -m "refactor(auth): extract validation to separate function"

# Bad - bundled changes
git commit -m "finished auth feature with tests and refactoring"
```

### Split Changes Across Commits

Even changes in the same file should be in separate commits if they serve different purposes:

```bash
# If user.py has both a bug fix and a new feature:
git add -p user.py  # Stage only bug fix lines
git commit -m "fix(users): correct email validation regex"

git add user.py  # Stage remaining feature lines
git commit -m "feat(users): add phone number field"
```

### What Goes Together

| Same Commit | Separate Commits |
|-------------|------------------|
| Feature code + its tests | Refactoring + bug fix |
| Migration + model change | Unrelated bug fixes |
| Config + code that uses it | Feature A + Feature B |

---

## Branching Strategy

### Feature Branch Workflow

```bash
git checkout main
git pull
git checkout -b feature/language-version-constraints
# ... make changes, commit ...
git push -u origin feature/language-version-constraints
# Create PR
```

### Branch Naming

```
feature/description    # New features
fix/description        # Bug fixes
refactor/description   # Code refactoring
docs/description       # Documentation
chore/description      # Maintenance tasks
```

### Branch Lifecycle

- Keep branches short-lived (< 3 days when possible)
- Rebase on main regularly to avoid merge conflicts
- Delete branches after merging

---

## Pull Requests

### PR Size

- Keep PRs small (< 400 lines changed)
- Break large features into smaller PRs
- Each PR should be reviewable in one sitting

### PR Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] All tests pass
- [ ] Added new tests for this change
- [ ] Coverage maintained/improved

## Checklist
- [ ] Code follows project style guide
- [ ] Self-reviewed code
- [ ] Commented complex logic
- [ ] Updated documentation
```

---

## Rebase vs Merge

**Full merge strategy SOP**: See [Branch, Merge & Deploy SOP](../workflows/branch-merge-deploy-sop.md) for the authoritative guide on how code moves between branches.

### Summary

| Boundary | Strategy | Why |
|----------|----------|-----|
| feature → dev | **Squash** (via task-close or PR) | One clean conventional commit per feature |
| dev → staging | **Regular merge** | Preserves commit SHAs, prevents phantom conflicts |
| staging → master | **Regular merge** | Preserves commit messages for version calculation |

### When to Rebase

```bash
# Update feature branch with latest dev BEFORE squash merge
git checkout feature/my-feature
git fetch origin
git rebase origin/dev

# Interactive rebase to clean up commits (optional — squash merge collapses anyway)
git rebase -i HEAD~3
```

Rebase is only for feature branches before merging into dev. Never rebase shared branches (dev, staging, master).

### Never

- Rebase commits that have been pushed to shared branches
- Force push to dev/staging/master
- Squash merge when promoting between dev → staging → master (causes phantom conflicts)

---

## Useful Commands

### Staging Partial Changes

```bash
# Stage specific hunks interactively
git add -p

# Stage specific files
git add path/to/file.py
```

### Viewing History

```bash
# Compact log
git log --oneline -20

# With graph
git log --oneline --graph --all

# Changes in a file
git log -p -- path/to/file.py

# Search commit messages
git log --grep="feature"
```

### Undoing Changes

```bash
# Unstage file
git restore --staged file.py

# Discard local changes
git restore file.py

# Amend last commit (only if not pushed!)
git commit --amend

# Undo last commit, keep changes
git reset --soft HEAD~1
```

---

## .gitignore

Comprehensive gitignore:

```gitignore
# Python
__pycache__/
*.py[cod]
*$py.class
.pytest_cache/
.coverage
htmlcov/
.venv/
venv/
*.egg-info/
.ruff_cache/
.pyright/

# Node
node_modules/
.next/
out/
dist/
.turbo/

# Environment
.env
.env.local
.env.*.local

# IDE
.vscode/
.idea/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Project specific
test-results/
backups/
logs/
*.log

# Secrets (never commit)
*.pem
*.key
credentials.json
secrets.yaml
```

---

## Commit Frequency

- Commit after each TDD cycle (red-green-refactor)
- Commit when tests pass
- Commit before switching context
- Don't commit broken code

---

## Pre-Commit Checklist

Before every commit:

- [ ] Tests pass
- [ ] Linting passes
- [ ] Type checking passes
- [ ] No secrets in staged files
- [ ] Commit message follows convention
- [ ] Changes are logically grouped
