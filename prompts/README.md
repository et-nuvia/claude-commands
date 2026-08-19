# Reusable Prompts

One-time migration and refactoring playbooks. These are templates for common transformations that don't fit as ongoing skills.

## How to Use

1. Read the prompt file for the transformation you need
2. Copy the prompt or reference it: `@~/.claude/prompts/bash-to-makefile.md`
3. Run with Claude in the target project

## Available Prompts

| Prompt | Description |
|--------|-------------|
| `bash-to-makefile.md` | Convert bash scripts to Makefile-based project automation |
| `js-to-typescript.md` | Migrate JavaScript project to TypeScript |
| `class-to-functional.md` | Convert React class components to functional with hooks |
| `rest-to-graphql.md` | Migrate REST API endpoints to GraphQL |
| `sqlite-to-postgres.md` | Migrate SQLite database to PostgreSQL |
| `docker-compose-v1-to-v2.md` | Update docker-compose v1 syntax to v2 |
| `cjs-to-esm.md` | Convert CommonJS to ES Modules |
| `jest-to-vitest.md` | Migrate from Jest to Vitest |
| `env-to-secrets-manager.md` | Move environment variables to AWS Secrets Manager |
| `monolith-to-monorepo.md` | Split monolithic repo into monorepo structure |

## Creating New Prompts

Prompts should include:
1. **Context** - What this transformation does
2. **Prerequisites** - What needs to be in place before starting
3. **Analysis Phase** - What to examine first
4. **Transformation Steps** - Step-by-step instructions
5. **Validation** - How to verify the migration worked
6. **Rollback** - How to undo if something goes wrong
