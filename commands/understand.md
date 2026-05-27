---
name: understand
description: Explain how a specific part of the codebase works
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "understand" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "understand" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Understand Project

I'll analyze your entire application to understand its architecture, patterns, and how everything works together.

**Dispatch strategy**: For large codebases (>50 files, multiple services), dispatch 2-3 parallel Explore agents with different focus areas instead of exploring serially. This is faster (parallel execution) and keeps the parent context clean (agents' file reads don't pollute your conversation).

**Model selection**: Use `model: sonnet` for exploration (cost-efficient, good at pattern recognition). Escalate to `model: opus` only for architecture synthesis on complex multi-service systems where the relationships between components require deeper reasoning.

**For large codebases** — dispatch in parallel:
```
Agent({ subagent_type: "Explore", prompt: "Map the project structure, tech stack, entry points, and build system. Report: directory layout, languages, frameworks, package managers, docker setup.", thoroughness: "medium" })
Agent({ subagent_type: "Explore", prompt: "Map the data layer: database connections, models/entities, migrations, repositories, query patterns. Report: schema overview, ORM usage, data flow.", thoroughness: "medium" })
Agent({ subagent_type: "Explore", prompt: "Map the API/service layer: routes, controllers, middleware, external integrations, auth flow. Report: endpoint inventory, integration points, auth pattern.", thoroughness: "medium" })
```

Then consolidate the 3 agent results into a unified picture. Read specific files they identified for deeper analysis.

**For small codebases** (<50 files, single service) — explore directly using native tools:

**Phase 1: Project Discovery**
Using native tools for comprehensive analysis:
- **Glob** to map entire project structure
- **Read** key files (README, docs, configs)
- **Grep** to identify technology patterns
- **Read** entry points and main files

I'll discover:
- Project type and main technologies
- Architecture patterns (MVC, microservices, etc.)
- Directory structure and organization
- Dependencies and external integrations
- Build and deployment setup

**Phase 2: Code Architecture Analysis**
- **Entry points**: Main files, index files, app initializers
- **Core modules**: Business logic organization
- **Data layer**: Database, models, repositories
- **API layer**: Routes, controllers, endpoints
- **Frontend**: Components, views, templates
- **Configuration**: Environment setup, constants
- **Testing**: Test structure and coverage

**Phase 3: Pattern Recognition**
I'll identify established patterns:
- Naming conventions for files and functions
- Code style and formatting rules
- Error handling approaches
- Authentication/authorization flow
- State management strategy
- Communication patterns between modules

**Phase 4: Dependency Mapping**
- Internal dependencies between modules
- External library usage patterns
- Service integrations
- API dependencies
- Database relationships
- Asset and resource management

**Phase 5: Documentation Synthesis**
After analysis, I'll provide:
- **Architecture diagram** (in text/markdown)
- **Key components** and their responsibilities
- **Data flow** through the application
- **Important patterns** to follow
- **Tech stack summary**
- **Development workflow**

**Integration Points:**
I'll identify how components interact:
- API endpoints and their consumers
- Database queries and their callers
- Event systems and listeners
- Shared utilities and helpers
- Cross-cutting concerns (logging, auth)

**Output Format:**
```
PROJECT OVERVIEW
├── Architecture: [Type]
├── Main Technologies: [List]
├── Key Patterns: [List]
└── Entry Point: [File]

COMPONENT MAP
├── Frontend
│   └── [Structure]
├── Backend
│   └── [Structure]
├── Database
│   └── [Schema approach]
└── Tests
    └── [Test strategy]

KEY INSIGHTS
- [Important finding 1]
- [Important finding 2]
- [Unique patterns]
```

When the analysis is large, I'll create a todo list to explore specific areas in detail.

This gives you a complete mental model of how your application works.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "understand" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
