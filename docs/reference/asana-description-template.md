# Asana Task Description Template

**Purpose**: Standard format for Asana task descriptions that provide a concise summary with a link to the full task document.

**Philosophy**: Asana descriptions should be **summaries**, not full documentation. Aim for ~50 lines that give stakeholders enough context to understand the task without overwhelming them with implementation details.

---

## Template Structure

```markdown
## Summary

[2-3 sentences: What needs to be done + Why it's needed + Expected outcome]

## Context

**Requested by**: [Person/Team Name]
**Source**: [Cliq message / Email / GitHub Issue / Direct input]
**Why**: [Business reason or problem being solved]
**Data Source**: [If applicable, key technical context like "Existing API" or "ActivityEvent audit trail"]

## Key Metrics/Requirements ([Total Count])

**[Category 1]** ([count]):
- [Requirement 1]
- [Requirement 2]
- [Requirement 3]

**[Category 2]** ([count]):
- [Requirement 4]
- [Requirement 5]

**[Category 3]** ([count]):
- [Requirement 6]

## Technical Approach

**Phase 1** ([X-Y days]): [High-level deliverables]
**Phase 2** ([X-Y days]): [High-level deliverables]
**Phase 3** ([X-Y days]): [High-level deliverables]

**Stack**: [Key technologies/frameworks]

## [Domain-Specific Section] (Optional)

For healthcare apps:
## HIPAA Compliance ⚕️
[Compliance strategy in 3-5 bullet points]
[Key callout about no new concerns]

For infrastructure:
## Security Considerations 🔒
[Security controls and implications]

For API changes:
## Breaking Changes ⚠️
[Backwards compatibility notes]

## Acceptance Criteria

- [ ] [High-level testable criteria 1]
- [ ] [High-level testable criteria 2]
- [ ] [High-level testable criteria 3]
- [ ] [High-level testable criteria 4]
- [ ] [High-level testable criteria 5]
- [ ] [High-level testable criteria 6]
- [ ] [High-level testable criteria 7]
- [ ] [High-level testable criteria 8]

## Full Documentation

📄 **Task Document**: `path/to/docs/active/####-DATETIME-TSK-description.md`

**Work Item**: #### | **Priority**: [High/Medium/Low] | **Target**: [Date]
```

---

## Section Guidelines

### Summary (Required)
- **Length**: 2-3 sentences
- **Content**: What + Why + Outcome
- **Tone**: Clear, direct, non-technical
- **Example**: "Build analytics dashboard to track staff performance, workflow efficiency, and patient categorization across the medical clearance system. Provides operational visibility into how the system is used, identifies bottlenecks, and validates categorization decisions."

### Context (Required)
- **Who requested**: Name of person/team
- **Source**: Where the request came from (helps trace back)
- **Why**: Business reason (not technical reason)
- **Data Source**: If applicable, key technical context that affects approach
- **Example**:
  ```markdown
  **Requested by**: Brandon Martin
  **Source**: Cliq message
  **Why**: Operations team needs data-driven insights to measure staff efficiency
  **Data Source**: Existing ActivityEvent audit trail (read-only, HIPAA-compliant)
  ```

### Key Metrics/Requirements (Required)
- **Format**: Organized by category with counts
- **Content**: High-level bullet points (not exhaustive)
- **Limit**: 3-7 bullets per category, 3-5 categories max
- **Example**:
  ```markdown
  ## Key Metrics (11 Total)

  **Staff Performance** (4):
  - Staff first view timestamp
  - Provider clearance timestamp
  - Last-minute clearances (< 24/48hrs)
  - First interaction tracking
  ```

### Technical Approach (Required)
- **Format**: Phased breakdown with time estimates
- **Content**: High-level deliverables (not implementation details)
- **Stack**: List key technologies/frameworks
- **Example**:
  ```markdown
  **Phase 1** (3-5 days): Backend analytics APIs + HIPAA controls
  **Phase 2** (3-4 days): Frontend dashboard with visualizations
  **Phase 3** (2-3 days): CSV export, drill-downs, real-time updates

  **Stack**: NestJS backend, React/Next.js frontend, ActivityEvent queries, Redis caching
  ```

### Domain-Specific Section (Optional)
- **When to include**: If the task has critical compliance, security, or breaking change considerations
- **Common sections**:
  - `## HIPAA Compliance ⚕️` (healthcare apps)
  - `## Security Considerations 🔒` (security-sensitive changes)
  - `## Breaking Changes ⚠️` (API changes)
  - `## Infrastructure Impact 🏗️` (infrastructure changes)
- **Content**: 3-5 bullet points + key callout
- **Example**:
  ```markdown
  ## HIPAA Compliance ⚕️

  ✅ Uses existing audit trail (no new PHI collection)
  ✅ Role-based access (admin/management only)
  ✅ Center-based filtering
  ✅ Meta-audit logging (audit the audit)
  ✅ Data minimization (aggregates preferred)

  **No new HIPAA concerns** - internal analytics only, no new data storage or transmission.
  ```

### Acceptance Criteria (Required)
- **Format**: Checkboxes (even though Asana doesn't render them, shows they're testable)
- **Content**: High-level testable criteria (not implementation steps)
- **Limit**: 8-12 items max
- **Coverage**: Functional + Quality + Compliance
- **Example**:
  ```markdown
  - [ ] All 11 metrics queryable via API
  - [ ] Dashboard displays visualizations (charts/tables)
  - [ ] Filters work (date range, office, provider, role)
  - [ ] CSV export with access logging
  - [ ] Queries < 3s for 90-day ranges
  - [ ] Non-admin users blocked (401/403)
  - [ ] GM users see only their centers
  - [ ] 80%+ test coverage
  ```

### Full Documentation (Required)
- **Always include**: Link to full TSK document
- **Metadata**: Work item number, priority, target date
- **Example**:
  ```markdown
  📄 **Task Document**: `docs/active/0000-0099/0002-2602111135-TSK-analytics-staff-provider-performance-workflow-tracking.md`

  **Work Item**: 0002 | **Priority**: Medium | **Target**: Feb 28, 2026
  ```

---

## Length Guidelines

| Target | Metric |
|--------|--------|
| Total Length | ~50 lines (±20 lines acceptable) |
| Summary | 2-3 sentences |
| Context | 3-5 fields |
| Requirements | 3-7 per category, 3-5 categories |
| Technical Approach | 3-5 phases + stack |
| Acceptance Criteria | 8-12 items |

**Rule of Thumb**: If the description exceeds 100 lines, you're including too much detail. Move details to the TSK document.

---

## Anti-Patterns (What NOT to Do)

❌ **Don't copy the entire TSK document** - That's what the link is for
❌ **Don't include implementation details** - Keep it high-level
❌ **Don't list every requirement** - Highlight key ones only
❌ **Don't include code snippets** - Not appropriate for Asana
❌ **Don't explain technical decisions** - Save for TSK document
❌ **Don't write multi-paragraph explanations** - Keep it concise
❌ **Don't skip the link to full documentation** - Always include it

---

## Good vs. Bad Examples

### ❌ Bad: Too Verbose

```markdown
## Summary

Build comprehensive analytics and reporting features to track staff/provider performance metrics, workflow efficiency indicators, and patient categorization trends across the medical clearance system. The application already tracks all activity via the ActivityEvent audit trail—this feature will surface that data through analytics dashboards and reports. The implementation will be done in three phases: first building backend analytics APIs, then creating frontend dashboards with visualizations, and finally adding advanced features like CSV export and real-time updates.

## Requirements (11 Metrics Across 3 Categories)

### Staff & Provider Performance
1. ✅ Track when staff first viewed a patient (timestamp + user)
   - Query ActivityEvent table with EventTypeId='PATIENT_VIEW'
   - Join with Auth table to get user role
   - Return MIN(OccurredAt) grouped by PatientId
2. ✅ Track when providers cleared a patient (timestamp + user)
   - Query ActivityEvent table with EventTypeId='CLEARANCE_CREATED'
   - Join with Clearance table for clearance details
   - Join with Auth table for provider information
...
[Continues for 200+ lines with exhaustive details]
```

**Problems**:
- Summary is 5 sentences instead of 2-3
- Requirements include implementation details (SQL queries)
- Way too long (200+ lines vs. target 50 lines)
- No clear link to full documentation

---

### ✅ Good: Concise Summary

```markdown
## Summary

Build analytics dashboard to track staff performance, workflow efficiency, and patient categorization across the medical clearance system. Provides operational visibility into how the system is used, identifies bottlenecks, and validates categorization decisions.

## Context

**Requested by**: Brandon Martin
**Source**: Cliq message
**Why**: Operations team needs data-driven insights to measure staff efficiency and identify delays
**Data Source**: Existing ActivityEvent audit trail (read-only, HIPAA-compliant)

## Key Metrics (11 Total)

**Staff Performance** (4):
- Staff first view timestamp
- Provider clearance timestamp
- Last-minute clearances (< 24/48hrs)
- First interaction tracking

**Workflow Efficiency** (5):
- Document request timestamps
- Avg requests per provider
- Delays by office
- User login metrics

**Categorization** (2):
- Cat I-IV accuracy validation
- Cat 3 justification tracking

## Technical Approach

**Phase 1** (3-5 days): Backend analytics APIs + HIPAA controls
**Phase 2** (3-4 days): Frontend dashboard with visualizations
**Phase 3** (2-3 days): CSV export, drill-downs, real-time updates

**Stack**: NestJS backend, React/Next.js frontend, ActivityEvent queries, Redis caching

## HIPAA Compliance ⚕️

✅ Uses existing audit trail (no new PHI collection)
✅ Role-based access (admin/management only)
✅ Center-based filtering
✅ Meta-audit logging (audit the audit)
✅ Data minimization (aggregates preferred)

**No new HIPAA concerns** - internal analytics only, no new data storage or transmission.

## Acceptance Criteria

- [ ] All 11 metrics queryable via API
- [ ] Dashboard displays visualizations (charts/tables)
- [ ] Filters work (date range, office, provider, role)
- [ ] CSV export with access logging
- [ ] Queries < 3s for 90-day ranges
- [ ] Non-admin users blocked (401/403)
- [ ] GM users see only their centers
- [ ] 80%+ test coverage

## Full Documentation

📄 **Task Document**: `docs/active/0000-0099/0002-2602111135-TSK-analytics-staff-provider-performance-workflow-tracking.md`

**Work Item**: 0002 | **Priority**: Medium | **Target**: Feb 28, 2026
```

**Why it's good**:
- Summary is 2 sentences
- Requirements are high-level bullets (no SQL queries)
- ~50 lines total
- Clear link to full documentation
- Scannable with organized sections

---

## When to Use This Template

✅ **Use for**:
- Tasks captured from Asana URLs (updating description)
- Tasks created from direct input (initial description)
- Tasks created from Cliq/Email/SMS (initial description)
- Any task that will be synced to Asana

❌ **Don't use for**:
- Local-only tasks (no Asana sync)
- Quick notes or reminders
- Tasks that are already in Asana with good descriptions

---

## Integration with Task Capture

**During `/task-capture`**:

1. Create local TSK document with full details
2. If creating Asana task (`capture` in `sync_on_operations`):
   - Use this template for Asana description
   - Extract key information from parsed requirements
   - Keep it concise (~50 lines)
   - Include link to local TSK document path

**Example Flow**:
```markdown
1. User: /task-capture "Build analytics dashboard for staff performance"
2. Create full TSK document (10+ pages)
3. Create Asana task with summary description (~50 lines)
4. Link Asana description to TSK document
5. Store Asana GID in TSK document External Tracking
```

---

## Maintenance

**When to update Asana description**:
- Scope significantly changes (add/remove major requirements)
- Timeline significantly changes (phases shift by weeks)
- Priority changes (High → Low or vice versa)
- Domain-specific considerations discovered (new HIPAA concerns)

**What NOT to update in Asana**:
- Implementation details (those go in TSK document only)
- Code snippets or file paths
- Detailed test plans
- Step-by-step procedures

**Update both** TSK document and Asana description if:
- Core requirements change
- Phases are reorganized
- Acceptance criteria shift
- Key dates change

---

## Related Documentation

- **Task Capture Skill**: `/task-capture` command documentation
- **Asana MCP Integration**: `~/.claude/docs/reference/asana-mcp-integration.md`
- **V4 Documentation**: `~/.claude/docs/reference/DOCUMENTATION-V4.md`
- **Task Templates**: `~/.claude/templates/task-TSK.md`

---

## Summary

**Key Takeaways**:
1. Asana descriptions are **summaries**, not full documentation
2. Target **~50 lines** (±20 acceptable)
3. **Always link** to full TSK document
4. **Organize** by sections for scannability
5. **High-level only** - no implementation details
6. **Use domain-specific sections** when relevant (HIPAA, Security, Breaking Changes)
7. **Update** when scope/timeline/priority changes significantly

**Template Location**: `~/.claude/docs/reference/asana-description-template.md`
**Example Task**: https://app.asana.com/0/1211676392439164/1213233048322728
