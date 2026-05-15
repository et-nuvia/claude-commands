# Project Knowledge: {{PROJECT_NAME}}

> Domain knowledge, workflows, and architectural context for AI-assisted development.
> This document helps AI tools understand the system beyond what code structure reveals.

---

## Domain Overview

<!-- High-level description of what this system does, who uses it, and why it exists -->

### Key Concepts

<!-- Domain-specific terms and their meanings -->

| Term | Definition |
|------|-----------|
| | |

---

## Core Workflows

<!-- The main user-facing or system workflows. Each should describe the happy path
     and key decision points. -->

### Workflow: {{WORKFLOW_NAME}}

**Trigger**: <!-- What starts this workflow -->
**Actors**: <!-- Who/what is involved -->

**Steps**:
1.
2.
3.

**Outcome**: <!-- What state the system is in when complete -->

---

## Integration Flows

<!-- External systems this project communicates with and how data flows between them -->

### {{INTEGRATION_NAME}}

- **Direction**: Inbound / Outbound / Bidirectional
- **Protocol**: REST API / Webhook / Message Queue / etc.
- **Data**: <!-- What data is exchanged -->
- **Trigger**: <!-- When does this integration fire -->

---

## Authentication & Authorization

<!-- How users/services authenticate and what authorization model is used -->

- **Auth Method**: <!-- JWT, OAuth2, API Keys, etc. -->
- **Session Storage**: <!-- Where sessions/tokens live -->
- **Role Model**: <!-- RBAC, ABAC, etc. -->
- **Key Rules**: <!-- Important auth constraints -->

---

## Entity Relationships

<!-- Key database entities and how they relate. ERD-style descriptions. -->

```
Entity A (1) ──── (N) Entity B
    │
    └── (1) ──── (1) Entity C
```

### Key Constraints

- <!-- FK cascades, unique constraints, soft-delete rules -->

---

## Service Responsibility Map

<!-- Which service/module owns what functionality -->

| Service/Module | Responsibilities | Key Files |
|---------------|-----------------|-----------|
| | | |

---

## Business Rules

<!-- Non-obvious rules that the code must enforce. These are the rules that
     would cause bugs if violated and aren't obvious from reading the code. -->

### Rule: {{RULE_NAME}}

- **What**: <!-- The rule -->
- **Why**: <!-- Business reason -->
- **Where enforced**: <!-- Code location(s) -->
- **Edge cases**: <!-- Known exceptions -->

---

## Environment-Specific Notes

<!-- Differences between dev, staging, and production that affect development -->

| Aspect | Development | Staging | Production |
|--------|------------|---------|------------|
| | | | |
