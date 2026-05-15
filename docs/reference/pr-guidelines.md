# Pull Request Guidelines

## Conventional Commits Format

All PR/MR titles MUST follow the conventional commits specification:

```
<type>(<scope>): <description>
```

### Type

**Required**. Must be one of:

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only changes
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `perf`: Performance improvement
- `test`: Adding missing tests or correcting existing tests
- `chore`: Changes to build process, dependencies, or auxiliary tools
- `ci`: Changes to CI configuration files and scripts
- `build`: Changes that affect the build system

### Breaking Changes

Add `!` after the type to indicate breaking changes:

- `feat!`: Breaking change (new feature)
- `fix!`: Breaking change (bug fix)
- `refactor!`: Breaking refactor

### Scope

**Optional**. The scope describes the area of the codebase affected:

Examples: `auth`, `api`, `database`, `ui`, `cli`, `docker`

### Description

**Required**. Short description of the change:

- Use imperative, present tense: "add" not "added" nor "adds"
- Don't capitalize first letter
- No period at the end
- Keep it under 50 characters

## Examples

### Good PR Titles ✅

```
feat(auth): add OAuth2 authentication support
fix(api): resolve race condition in user lookup
docs(readme): update installation instructions
refactor(database): simplify query builder
perf(api): optimize user search with indexing
test(auth): add integration tests for login flow
chore(deps): upgrade express to v5.0.0
feat!(api): migrate REST API to GraphQL
```

### Bad PR Titles ❌

```
Add feature               ❌ No type or scope
feat: Add Feature         ❌ Capitalized description
Update code               ❌ Too vague, no type
feat(auth) add login      ❌ Missing colon
feat(auth): Added login.  ❌ Wrong tense, has period
```

## Release Notes

PRs must include release notes for relevant audiences:

### 1. Technical (Engineers)

**Who**: Developers integrating with or maintaining this code

**Include**:
- API changes
- New dependencies
- Migration steps
- Breaking changes
- Configuration changes

**Example**:
```markdown
### Technical

- Added new `/api/v2/auth/oauth` endpoint for OAuth2 flow
- New dependency: `passport-oauth2` (v1.8.0)
- Breaking: Old `/api/auth/token` endpoint deprecated (remove in v3.0.0)
- Migration: Update client code to use new OAuth2 flow (see docs)
```

### 2. Operations (DevOps/SRE)

**Who**: Teams deploying and operating this code

**Include**:
- Configuration changes
- Infrastructure requirements
- Deployment steps
- Performance impact
- Monitoring changes

**Example**:
```markdown
### Operations

- New env var required: `OAUTH_CLIENT_SECRET`
- Redis cache now required for session storage
- Deploy order: Update environment variables → Deploy new image
- Expected memory usage increase: +50MB per instance
```

### 3. Business (Product/Management)

**Who**: Stakeholders tracking product progress

**Include**:
- Business value
- Problem solved
- Customer impact
- Revenue/cost impact

**Example**:
```markdown
### Business

- Enables enterprise SSO authentication
- Reduces support tickets related to password resets
- Required for Acme Corp contract (closes deal blocker)
- Estimated 30% reduction in authentication-related support costs
```

### 4. External (Customers/Users)

**Who**: End users who will see these changes

**Include**:
- User-facing changes
- New features
- Bug fixes users noticed
- Actions required

**Example**:
```markdown
### External

- You can now sign in using your company's single sign-on (SSO)
- Faster login experience with remembered devices
- No more password resets needed if your company uses SSO
```

### 5. Support (Customer Support)

**Who**: Support teams helping users

**Include**:
- Common questions
- Troubleshooting tips
- Known limitations
- Support procedures

**Example**:
```markdown
### Support

**Common Questions**:
- Q: "Where's the SSO button?" A: On login page, click "Sign in with SSO"
- Q: "SSO not working" A: Check that their company admin enabled SSO

**Troubleshooting**:
1. Verify user's email domain matches configured SSO domain
2. Check SSO provider status page
3. Test with admin test account

**Known Limitations**:
- SSO only works for @company.com emails
- Mobile app SSO coming in v2.1
```

## When Release Notes Are Required

### Always Required

- `feat`: New features (all audiences as relevant)
- `fix`: User-visible bugs (External, Support minimum)
- `feat!` or `fix!`: Breaking changes (Technical, Operations, External)
- `perf`: Performance changes (Operations minimum)

### Sometimes Required

- `refactor`: If it affects integrations (Technical)
- `chore`: If it affects deployment (Operations)
- `docs`: Usually no release notes needed

### Not Required

- `test`: Internal testing changes
- `ci`: CI/CD changes
- Minor dependency updates without user impact

## PR Validation

All PRs are automatically validated by CI:

- ✅ PR title follows conventional commits format
- ✅ PR title is not empty
- ✅ Type is valid (`feat`, `fix`, etc.)
- ✅ Description is present and properly formatted
- ✅ Breaking changes use `!` marker

**If validation fails:**

1. Edit your PR title to match the format
2. CI will automatically re-run
3. PR cannot be merged until validation passes

## Squash Merge Behavior

When PRs are squash merged to staging:

- **Commit title**: Uses your PR title (conventional commits format)
- **Commit body**: Includes your PR description + release notes + individual commits
- **Semantic info**: Preserved in commit body for version calculation
- **Individual commits**: Listed in body for audit trail

Example squash commit:
```
feat(auth): add OAuth2 authentication

Summary: Added OAuth2 support for enterprise SSO.

### Technical
- New /api/v2/auth/oauth endpoint
- Added passport-oauth2 dependency

### Operations
- Requires OAUTH_CLIENT_SECRET env var
- Requires Redis for session storage

Commits:
- abc123: feat(auth): add OAuth2 provider
- def456: test(auth): add OAuth2 integration tests
- ghi789: docs(auth): document OAuth2 setup
```

This preserves all semantic information for version calculation!

## Quick Reference

| Type | When to Use | Breaking? | Release Notes |
|------|-------------|-----------|---------------|
| `feat` | New feature | No | Yes |
| `feat!` | Breaking feature | Yes | Yes |
| `fix` | Bug fix | No | Yes |
| `fix!` | Breaking bug fix | Yes | Yes |
| `docs` | Documentation | No | No |
| `refactor` | Code restructure | No | Sometimes |
| `perf` | Performance | No | Yes |
| `test` | Tests only | No | No |
| `chore` | Maintenance | No | Sometimes |

## FAQs

**Q: Can I use multiple types in one PR?**

A: No, choose the most significant type. If you have feat + fix, split into two PRs.

**Q: What if my change affects multiple scopes?**

A: Choose the primary scope or omit scope entirely.

**Q: Do I need all 5 release note sections?**

A: No, only fill sections relevant to your change. Leave others empty.

**Q: Can I skip release notes for a small fix?**

A: If it's user-visible, include at least External and Support sections. If it's internal only, you can skip.

**Q: What if CI validation fails on merge?**

A: Edit the PR title to match the format. Validation re-runs automatically.

## Resources

**Internal Documentation**:
- **[Multi-Audience Release Notes Workflow](../workflows/release-notes-guide.md)** - Complete workflow guide with examples and FAQ
- **[CI/CD Pipeline Guide](../pipelines.md)** - Pipeline configuration and version management
- **[Version Management](version-management.md)** - Semantic versioning strategies
- Project release notes examples: `docs/releases/`

**External Standards**:
- [Conventional Commits Specification](https://www.conventionalcommits.org/)
- [Semantic Versioning](https://semver.org/)
