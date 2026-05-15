# Release Notes Templates

Multi-audience release notes templates for generating targeted communication for different stakeholder groups.

## Templates

| Template | Audience | Focus |
|----------|----------|-------|
| `technical.md.tmpl` | Engineers, Developers | API changes, breaking changes, migration guides |
| `operations.md.tmpl` | DevOps, SRE | Deployment steps, infrastructure, configuration |
| `business.md.tmpl` | Product, Leadership | Business value, revenue impact, strategy |
| `external.md.tmpl` | Customers, End Users | User-facing features, improvements, actions required |
| `support.md.tmpl` | Customer Support | Common questions, troubleshooting, escalation paths |

## Template Syntax

Templates use Handlebars syntax for variable substitution and conditionals:

- **Variables**: `{{VARIABLE_NAME}}`
- **Conditionals**: `{{#if CONDITION}}...{{else}}...{{/if}}`
- **Loops**: `{{#each ARRAY}}...{{/each}}`
- **Index**: `{{@index}}` (in loops)

## Common Variables

### Universal
- `{{VERSION}}` - Release version (e.g., "1.2.3")
- `{{DATE}}` - Release date (ISO 8601 format)
- `{{PRODUCT_NAME}}` - Product name
- `{{CHANGELOG_URL}}` - Full changelog URL
- `{{COMMIT_COUNT}}` - Number of commits in release

### Features
- `{{FEATURES}}` - Array of feature objects
  - `title` - Feature title
  - `description` - Feature description
  - `code_example` - Code example
  - `dependencies` - Dependencies added

### Breaking Changes
- `{{BREAKING_CHANGES}}` - Array of breaking change objects
  - `title` - Change title
  - `what_breaks` - What functionality breaks
  - `migration` - Migration instructions
  - `affected` - Who is affected
  - `code_example` - Migration code example

### Bug Fixes
- `{{FIXES}}` - Array of fix objects
  - `title` - Fix title
  - `issue` - Issue fixed
  - `fix` - What was fixed
  - `impact` - Who benefits

### Deployment (Operations)
- `{{DEPLOYMENT_STEPS}}` - Array of deployment step objects
  - `step` - Step description
  - `commands` - Shell commands
  - `duration` - Estimated time

### Configuration (Operations)
- `{{CONFIG_CHANGES}}` - Array of configuration objects
  - `config_name` - Configuration name
  - `action` - Action required
  - `default` - Default value
  - `example` - Example value
  - `required` - Boolean, is it required?

### Business Impact
- `{{BUSINESS_VALUE}}` - Array of business value objects
  - `title` - Value title
  - `problem` - Problem solved
  - `value` - Value delivered
  - `customer_impact` - Customer impact
  - `metrics` - Expected metrics

## Usage Example

### Input Data (JSON)
```json
{
  "VERSION": "1.2.3",
  "DATE": "2026-02-10",
  "FEATURES": [
    {
      "title": "OAuth2 Authentication",
      "description": "Enterprise SSO support",
      "code_example": "auth.login({ provider: 'oauth2' })",
      "dependencies": "passport-oauth2@1.8.0"
    }
  ],
  "BREAKING_CHANGES": [],
  "FIXES": [
    {
      "title": "Fix memory leak in cache",
      "issue": "Cache growing unbounded",
      "fix": "Added TTL to cache entries",
      "impact": "All users"
    }
  ]
}
```

### Rendering
```bash
# Using Handlebars CLI or custom script
handlebars technical.md.tmpl --data release-data.json > technical-v1.2.3.md
```

### Output (technical.md)
```markdown
# Release Notes - Technical

**Version**: 1.2.3
**Released**: 2026-02-10
...

## New Features

### OAuth2 Authentication

Enterprise SSO support

**Usage**:
```javascript
auth.login({ provider: 'oauth2' })
```

**Dependencies**: passport-oauth2@1.8.0

## Bug Fixes

### Fix memory leak in cache

**Issue**: Cache growing unbounded
**Fix**: Added TTL to cache entries
**Impact**: All users
```

## Template Variables by Audience

### Technical Template

**Required**:
- `VERSION`, `DATE`

**Optional**:
- `BREAKING_CHANGES[]` - Breaking changes with migration guides
- `API_CHANGES[]` - API modifications
- `FEATURES[]` - New features with code examples
- `FIXES[]` - Bug fixes
- `PERFORMANCE[]` - Performance improvements
- `INTERNAL[]` - Internal changes
- `DEPENDENCY_UPDATES[]` - Dependency changes
- `MIGRATION_STEPS[]` - Migration instructions

### Operations Template

**Required**:
- `VERSION`, `DATE`

**Optional**:
- `DEPLOYMENT_STEPS[]` - Deployment procedure
- `CONFIG_CHANGES[]` - Configuration changes
- `INFRA_CHANGES[]` - Infrastructure modifications
- `ENV_VARS[]` - Environment variables
- `SECURITY_UPDATES[]` - Security patches
- `PERFORMANCE_IMPACT` - Resource impact
- `MONITORING_CHANGES` - Metrics and alerts
- `ROLLBACK_STEPS[]` - Rollback procedure
- `HEALTH_CHECKS[]` - Health verification

### Business Template

**Required**:
- `VERSION`, `DATE`, `EXECUTIVE_SUMMARY`

**Optional**:
- `BUSINESS_VALUE[]` - Business outcomes
- `CUSTOMER_IMPACT` - Customer effects
- `REVENUE_IMPACT` - Revenue opportunities
- `COMPETITIVE_ADVANTAGES[]` - Market differentiation
- `STRATEGIC_ALIGNMENT[]` - Strategy alignment
- `CONTRACT_COMPLIANCE[]` - Contract obligations
- `KEY_METRICS[]` - Success metrics

### External Template

**Required**:
- `VERSION`, `DATE`, `PRODUCT_NAME`, `FEATURE_COUNT`, `FIX_COUNT`

**Optional**:
- `NEW_FEATURES[]` - User-facing features
- `IMPROVEMENTS[]` - Enhancements
- `BUG_FIXES[]` - Fixed issues
- `ACTIONS_REQUIRED[]` - User actions
- `UPDATE_INSTRUCTIONS` - How to update
- `KNOWN_ISSUES[]` - Known problems
- `COMING_SOON[]` - Future features

### Support Template

**Required**:
- `VERSION`, `DATE`

**Optional**:
- `QUICK_REFERENCE[]` - Quick answers
- `NEW_FEATURES[]` - Feature support guides
- `BUG_FIXES[]` - Fixed issues
- `BREAKING_CHANGES[]` - Breaking changes with customer scripts
- `KNOWN_ISSUES[]` - Known issues with workarounds
- `SUPPORT_SCENARIOS[]` - Common scenarios
- `TESTING_CHECKLIST[]` - Verification steps
- `ESCALATION[]` - Escalation paths
- `COMM_TEMPLATES[]` - Communication templates

## Template Customization

### Adding Custom Variables

1. Add variable to data source (JSON/YAML)
2. Use in template: `{{CUSTOM_VARIABLE}}`
3. Document in this README

### Adding Custom Sections

```handlebars
{{#if CUSTOM_SECTION}}
## Custom Section

{{CUSTOM_SECTION.content}}

{{/if}}
```

### Conditional Content

```handlebars
{{#if BREAKING_CHANGES}}
⚠️ This release includes breaking changes. Please review carefully.
{{else}}
No breaking changes in this release.
{{/if}}
```

### Nested Loops

```handlebars
{{#each FEATURES}}
### {{this.title}}

{{#each this.sub_features}}
- {{this.name}}
{{/each}}

{{/each}}
```

## Integration

### With generate-release-notes.sh

Templates are used by `~/.claude/scripts/generate-release-notes.sh`:

```bash
# Generate all audience release notes
./scripts/generate-release-notes.sh v1.2.3

# Generates:
# - release-notes/v1.2.3-technical.md
# - release-notes/v1.2.3-operations.md
# - release-notes/v1.2.3-business.md
# - release-notes/v1.2.3-external.md
# - release-notes/v1.2.3-support.md
```

### With Claude API (AI Polish)

Raw template output can be polished with Claude API:

```bash
# Generate and polish with AI
./scripts/generate-release-notes.sh v1.2.3 --polish

# AI enhances:
# - Grammar and clarity
# - Technical accuracy
# - Consistent tone
# - Audience-appropriate language
```

## Template Testing

Test templates with sample data:

```bash
# Run template tests
./tests/test-templates.sh

# Test specific template
./tests/test-templates.sh technical
```

## Best Practices

1. **Keep templates DRY** - Extract common sections to partials
2. **Provide defaults** - Use `{{else}}` for missing data
3. **Document variables** - Update README when adding variables
4. **Test thoroughly** - Test with real release data
5. **Review output** - Always review generated notes before publishing
6. **Audience-first** - Write for the audience, not the feature
7. **Be concise** - Each audience has limited attention

## Examples

See `docs/releases/` for real-world examples of generated release notes.

## Maintenance

- **Owner**: Engineering team
- **Review cycle**: Quarterly
- **Feedback**: #engineering-releases Slack channel
- **Updates**: Submit PR with template improvements
