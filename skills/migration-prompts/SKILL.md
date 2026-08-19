---
name: migration-prompts
description: Catalog of one-time codebase migration prompts in ~/.claude/prompts/ (bash-to-makefile, js-to-typescript, env-to-secrets-manager, docker-compose-v1-to-v2, cjs-to-esm, class-to-functional). Load when performing a one-time whole-codebase migration of one of these kinds.
---

# Migration Prompts (`~/.claude/prompts/`)

Invoke a one-time migration via `@~/.claude/prompts/<name>.md`:

| Prompt | Migrates |
|---|---|
| `bash-to-makefile` | ad-hoc bash scripts → hierarchical Makefile targets |
| `js-to-typescript` | JavaScript → TypeScript |
| `env-to-secrets-manager` | `.env` variables → secrets manager (Infisical / AWS Secrets Manager) |
| `docker-compose-v1-to-v2` | `docker-compose` V1 syntax → `docker compose` V2 |
| `cjs-to-esm` | CommonJS → ES modules |
| `class-to-functional` | React class components → functional components + hooks |
