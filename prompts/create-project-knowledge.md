# Create PROJECT-KNOWLEDGE.md

Generate a comprehensive `docs/architecture/PROJECT-KNOWLEDGE.md` document for this project. This document is optimized for LLM context loading — it should give an AI assistant immediate understanding of how the system works without needing to read dozens of source files.

## Before You Start

1. Read `CLAUDE.md` and `PROJECT.yaml` (if they exist) for project overview and tech stack
2. Read any existing architecture docs in `docs/architecture/` or `docs/`
3. Do NOT duplicate information already in CLAUDE.md (file paths, directory structure, tech stack versions, deployment config) — this document covers **domain logic and behavior** that CLAUDE.md doesn't

## What to Explore

Launch parallel exploration agents to deeply research these areas:

1. **Core business workflows** — What are the primary user-facing flows? How do entities move through states? What triggers transitions?
2. **Entity relationships** — All database entities, their FKs, cascades, unique constraints. Group by domain.
3. **Service responsibility map** — Every service, what it owns, what it depends on. Group by domain.
4. **Integration flows** — How does the system interact with external services? What are the webhook endpoints, API clients, queue architectures?
5. **Authentication & authorization** — How do users authenticate? What roles exist? How is access scoped?
6. **Background processing** — Scheduled jobs, cron tasks, queue processors, async workflows
7. **Business rules & invariants** — Rules that aren't obvious from code structure (e.g., "both roles must approve", "sync is queue-based with idempotency")

## Document Structure

Use this structure with **Mermaid diagrams** for every workflow and integration:

```markdown
# {Project Name} — Project Knowledge Base

> **Purpose**: Living reference for understanding system behavior, business logic,
> entity relationships, and integration flows. Optimized for LLM context loading
> and task auditing.
>
> **Last Updated**: {date}

## Table of Contents
{auto-generate from sections}

## Domain Overview
- 1-paragraph summary of what the system does
- Numbered list of the core loop (the primary workflow in 5-7 steps)
- Architecture summary (services, ports, key technologies)

## Core Workflows
For each major workflow:
- **Mermaid flowchart or sequence diagram** showing the full flow
- Key services involved
- State transitions
- Business rules that govern the flow

## Integration Flows
For each external integration:
- **Mermaid sequence diagram** showing data flow in both directions
- Field mappings (if bidirectional sync)
- Queue architecture (if async)
- Webhook endpoints and security
- Error handling and retry strategy

## Authentication & Authorization
- **Mermaid sequence diagram** of the auth flow
- Role table with IDs and access levels
- Access control layers (guards, scoping, IP restrictions)

## Entity Relationship Diagrams
- **Mermaid ER diagrams** grouped by domain (not one massive diagram)
- Include field types for key entities
- Show cascade rules and unique constraints
- Separate diagrams for: Core domain, Records/Documents, Communications, etc.

## Service Responsibility Map
- Table per domain: Service | Responsibility | Key Dependencies
- **Mermaid flowchart** showing key service dependencies

## Scheduled Jobs & Background Processing
- Table: Service | Schedule | Purpose | Status (active/disabled)
- Queue architecture details
- Rate limiting configuration

## Business Rules & Invariants
- Tables grouped by domain (Patient Rules, Access Control, Integration Rules, etc.)
- Each rule: Rule name | Details (specific, not vague)
```

## Mermaid Diagram Guidelines

- Use `flowchart TD` for workflows with decision points
- Use `sequenceDiagram` for multi-service interactions and API flows
- Use `erDiagram` for entity relationships
- Include actual method names, status values, and field names in diagrams — not generic labels
- Show error paths and alternative flows (use `alt` in sequence diagrams)
- Keep diagrams focused — split into multiple smaller diagrams rather than one huge one

## Quality Checklist

Before finishing, verify the document answers these questions without needing to read source code:

- [ ] "Which service handles X?" → Service map answers this
- [ ] "What happens when a user does Y?" → Workflow diagram shows this
- [ ] "What entities are affected by Z?" → ER diagram shows relationships
- [ ] "What business rules apply to W?" → Business rules table covers this
- [ ] "How does the system talk to external service V?" → Integration flow shows this
- [ ] "Who can access U and how?" → Auth section explains this
- [ ] "What runs in the background?" → Scheduled jobs table lists this

## What NOT to Include

- File paths and directory structure (CLAUDE.md has this)
- API endpoint lists (CLAUDE.md has this)
- Tech stack versions (PROJECT.yaml has this)
- Deployment configuration (already documented elsewhere)
- Setup/installation instructions
- Environment variables or secrets details

## Output

Write the completed document to `docs/architecture/PROJECT-KNOWLEDGE.md`. Create the directory if it doesn't exist.
