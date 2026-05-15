# Task Intake Patterns

**Purpose**: Comprehensive guide for capturing tasks from any source into structured, trackable format.

## Overview

Tasks can come from many sources. We have two primary intake skills:

1. **`/parse-issue`** - For structured project management systems
   - GitHub Issues
   - GitLab Issues
   - Jira tickets

2. **`/capture-task`** - For informal/unstructured sources
   - Email (Gmail, work email)
   - SMS
   - Voice notes
   - Asana tasks
   - Cliq messages
   - Direct input

Both create structured task documents in `docs/tasks/` that feed into the same workflow.

## Task Intake by Environment

### At Work (macOS)

**Primary sources** (in order of preference):
1. **Asana** → `/capture-task` (fetch by task ID/URL)
2. **Cliq messages** → `/capture-task` (paste or fetch)
3. **Work email** → `/capture-task` (paste or forward)
4. **Direct input** → `/capture-task [description]`

**Project management**:
- If using GitHub/GitLab at work → `/parse-issue`

---

### At Home (WSL)

**Primary sources**:
1. **Email (Gmail)** → `/capture-task` (paste or API)
2. **SMS** → `/capture-task` (paste message)
3. **Voice/Phone** → `/capture-task` (paste transcription)
4. **Direct input** → `/capture-task [description]`

**Project management**:
- If using GitHub/GitLab at home → `/parse-issue`

---

## Skill Selection Guide

### Use `/parse-issue` when:
- Task is in GitHub Issues
- Task is in GitLab Issues
- Task is in Jira
- Source has structured fields (labels, milestones, etc.)
- You have issue number or URL

### Use `/capture-task` when:
- Task came via email
- Task came via SMS
- Task came via voice note
- Task came via Asana
- Task came via Cliq message
- Someone told you verbally
- You're creating task from notes

---

## Authentication Setup

### Work (macOS)

**Asana**:
```bash
# Get Personal Access Token from Asana settings
echo "YOUR_TOKEN_HERE" > ~/.asana-token
chmod 600 ~/.asana-token
```

**Zoho Cliq**:
```bash
# Get OAuth token from Cliq developer console
echo "YOUR_TOKEN_HERE" > ~/.cliq-token
chmod 600 ~/.cliq-token
```

**GitHub** (if used at work):
```bash
gh auth login
```

---

### Home (WSL)

**Gmail API** (optional, for automatic fetching):
```bash
# Follow Gmail API quickstart
# Download credentials.json
# Run OAuth flow
# Token saved automatically
```

**GitHub/GitLab**:
```bash
# GitHub
gh auth login

# GitLab
echo "YOUR_TOKEN_HERE" > ~/.gitlab-token
chmod 600 ~/.gitlab-token
```

**Twilio** (optional, for SMS API):
```bash
# Only needed if you want automatic SMS fetching
# Otherwise, paste SMS content manually
```

---

## Usage Examples

### Example 1: Asana Task (Work)

```bash
/capture-task

# You'll be prompted:
# Where is this task from?
# > Asana task

# Provide task:
# - URL: https://app.asana.com/0/PROJECT/TASK_ID
# - Or task ID: 1234567890
# - Or task name: "Add user authentication"

# Result:
# ✓ Task captured from Asana
# Saved: docs/tasks/2024-01-30-feature-add-user-auth.md
```

---

### Example 2: Email (Home or Work)

```bash
/capture-task

# Paste email:
From: client@example.com
Subject: Website contact form not working
Date: Jan 30, 2024 2:30 PM

Hi,

The contact form on the website isn't sending emails.
I tried submitting a message but never got a confirmation.
Can you look into this? We're missing customer inquiries.

Thanks,
Jane

# Result:
# ✓ Task captured from Email
# Priority: High (customer impact)
# Saved: docs/tasks/2024-01-30-bug-contact-form-emails.md
```

---

### Example 3: SMS (Home)

```bash
/capture-task

# Paste SMS:
From: Mom (555-1234)
Time: 3:45 PM
Message: The family website needs photos updated for the reunion next month

# Result:
# ✓ Task captured from SMS
# Priority: Medium (deadline: next month)
# Saved: docs/tasks/2024-01-30-enhancement-update-reunion-photos.md
```

---

### Example 4: Voice Note (Home)

```bash
/capture-task

# Paste transcription:
[Voice memo from phone, 2:15 PM]

"Okay so I need to remember to uh fix that bug in the login flow where
um if users enter the wrong password three times it should lock them out
but right now it's not doing that and uh this is pretty important for
security reasons so we should probably do this like this week"

# Result:
# ✓ Task captured from Voice
# Priority: High (security + deadline)
# Saved: docs/tasks/2024-01-30-bug-login-lockout.md
```

---

### Example 5: Cliq Message (Work)

```bash
/capture-task

# Paste Cliq message:
From: @jane in #engineering
Time: 10:30 AM

Hey team, we're getting reports that the API is slow when handling
large datasets. Can someone investigate and optimize the query?
This is affecting our enterprise customers.

# Result:
# ✓ Task captured from Cliq
# Priority: High (customer impact)
# Saved: docs/tasks/2024-01-30-bug-api-performance.md
```

---

### Example 6: GitHub Issue

```bash
/parse-issue #123

# Or with URL:
/parse-issue https://github.com/owner/repo/issues/123

# Result:
# ✓ Issue parsed from GitHub
# Saved: docs/tasks/2024-01-30-issue-123-add-pagination.md
```

---

### Example 7: Quick Direct Input

```bash
/capture-task Add rate limiting to API endpoints

# Result:
# ✓ Task captured
# Saved: docs/tasks/2024-01-30-feature-api-rate-limiting.md
# Note: Will ask clarifying questions for minimal descriptions
```

---

## Workflow Integration

After capturing a task, the document flows into the standard workflow:

```bash
# 1. Capture task
/capture-task
# → Creates: docs/tasks/2024-01-30-feature-name.md

# 2. Plan implementation (if not trivial)
/task-plan docs/tasks/2024-01-30-feature-name.md
# → Creates: docs/plans/2024-01-30-feature-name.md

# 3. Start work
/start-task docs/plans/2024-01-30-feature-name.md
# → Creates branch, sets up environment

# 4. Implement (TDD)
/tdd-start "Feature description"
# [implement code]
/run-tests --coverage

# 5. Review
/create-pr
/review-pr

# 6. Deploy
/analyze-deployment-risk
/deploy production

# 7. Close
/close-task
```

---

## Task Document Format

All intake methods create the same structured format:

```markdown
# Task: [Title]

**Source**: [Email/SMS/Voice/Asana/Cliq/GitHub/etc.]
**Priority**: [Critical/High/Medium/Low]
**Type**: [Bug/Feature/Enhancement/etc.]
**Due Date**: [Date]

## Task Summary
[What needs to be done]

## Requirements
- [Requirement 1]
- [Requirement 2]

## Acceptance Criteria
- [ ] [Criterion 1]
- [ ] [Criterion 2]

## Ambiguities & Questions
- [Question 1]
```

This consistency enables:
- Uniform processing by `/task-plan`
- Easy searching: `grep -r "Priority: Critical" docs/tasks/`
- Git tracking of all tasks
- Historical analysis

---

## Priority Detection

Tasks are auto-prioritized based on signals:

### Critical (P0) - Immediate action required
**Signals**:
- Production outage
- Security vulnerability
- Legal/compliance issue
- Words: "critical", "urgent", "down", "broken", "ASAP"
- Source: Executive email, support escalation

**Examples**:
- "Production login is broken"
- "Security vulnerability reported"
- "[URGENT] API down"

---

### High (P1) - This week
**Signals**:
- Customer impact
- Upcoming deadline (< 1 week)
- Words: "important", "need soon", "this week"
- Source: Customer email, manager request

**Examples**:
- "Contact form not working" (customer impact)
- "Need before Friday demo"
- "Enterprise customer blocked"

---

### Medium (P2) - This sprint/month
**Signals**:
- Moderate impact
- Flexible deadline (1-4 weeks)
- Words: "should", "would be nice", "next sprint"
- Source: Team member, Asana task

**Examples**:
- "Add pagination to user list"
- "Update docs for new API"
- "Refactor old code"

---

### Low (P3) - Backlog
**Signals**:
- No deadline
- Nice to have
- Words: "someday", "eventually", "consider"
- Source: Suggestion, idea

**Examples**:
- "Consider adding dark mode"
- "Might want to optimize this later"
- "Future enhancement idea"

---

## Type Detection

Tasks are auto-categorized:

- **Bug**: Something broken ("fix", "broken", "error", "not working")
- **Feature**: New functionality ("add", "implement", "create new")
- **Enhancement**: Improve existing ("improve", "optimize", "better")
- **Research**: Investigation ("investigate", "research", "understand")
- **Maintenance**: Cleanup ("refactor", "update deps", "clean up")
- **Documentation**: Docs only ("update docs", "add README")

---

## Best Practices

### For Email Tasks
- Forward emails to capture them (preserve context)
- Include full thread if relevant
- Note if reply expected

### For SMS Tasks
- Capture immediately (easy to lose)
- Screenshot if contains important details
- Note sender for follow-up

### For Voice Tasks
- Transcribe as soon as possible
- Use voice memo app for automatic transcription
- Review transcription for accuracy

### For Asana/Cliq
- Include task/message URL for reference
- Capture before it's lost in stream
- Note who requested for questions

### General
- Capture everything (don't rely on memory)
- Review daily for priorities
- Clarify ambiguities before planning
- Link related tasks

---

## Troubleshooting

### "Can't fetch from Asana"
- Check token: `cat ~/.asana-token`
- Verify token: `curl -H "Authorization: Bearer $(cat ~/.asana-token)" https://app.asana.com/api/1.0/users/me`
- Token expired? Regenerate in Asana settings

### "Can't access Gmail"
- Using Gmail API? Check credentials
- Or paste email content manually
- Consider email forwarding rule

### "Voice transcription is bad"
- Use better transcription service
- Or manually clean up before capturing
- Speak clearly for better results

### "Too many tasks captured"
- Review and prioritize: `ls -lt docs/tasks/ | head -20`
- Archive old tasks: `mv docs/tasks/old/ docs/archive/`
- Focus on P0/P1 tasks first

---

## Automation Ideas

### Email Forwarding
Set up email forward rule:
```
When email has subject containing "[TASK]"
Forward to: tasks@your-capture-system.com
```

### SMS Forwarding
Use IFTTT/Zapier:
```
When SMS received from specific contacts
→ Send to webhook
→ Auto-create task
```

### Asana Webhooks
Set up webhook for new tasks:
```
When new task assigned to me
→ POST to webhook
→ Auto-capture to docs/tasks/
```

---

## See Also

- [Parse Issue Documentation](../skills/parse-issue.md)
- [Plan Implementation](../skills/plan-implementation.md)
- [Standard Developer Workflow](workflow.md)
