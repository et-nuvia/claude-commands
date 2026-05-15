---
name: document-api
description: Scan project for API endpoints and generate comprehensive documentation
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "document-api" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "document-api" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Scan the project codebase to discover all API endpoints and produce consistent, comprehensive documentation. Use model: opus for all code analysis.

**Templates**: `~/.claude/templates/api-spec.md` and `~/.claude/templates/api-summary.md`

## 1. Determine Scope

- No argument: document ALL endpoints
- File/directory argument: document only those routes
- `update`: re-scan and fill gaps in existing docs

## 2. Read Project Config

Read PROJECT.yaml for tech stack, server entry point, route conventions, auth patterns, and base URLs.

## 3. Discover API Routes

Based on detected framework, search for route definitions:
- **Express**: glob `**/routes/**/*.{js,ts}`, grep `app\.(get|post|put|patch|delete)`
- **FastAPI**: grep `@(app|router)\.(get|post|put|patch|delete)\(`
- **Django**: glob `**/urls.py`, grep `path\(|re_path\(`

For each file: read fully, extract every route (method + path), note middleware, request/response schemas, and error handling.

## 4. Identify Rate Limits and Idempotency

Search for rate limiting config (windowMs, max, RateLimiter, slowapi). Map each limiter to the routes it covers.

For idempotency: GET/HEAD/OPTIONS/PUT are idempotent by convention. POST requires analysis (check for dedup logic, upserts). PATCH depends on whether it sets absolute vs relative values. Document each endpoint as Yes/No/Conditional with explanation.

## 5. Gap Analysis

Check for existing docs in `docs/api/`. If found, compare against discovered endpoints and present:
```
Discovered: N endpoints | Documented: X endpoints
Fully documented / Partially documented / Undocumented / Stale
Proceed?
```

## 6. Generate Spec Files

For each logical API group, create `docs/api/[group-name]-api-spec.md` using the template. Include: base URL, auth method, rate limits, and for every endpoint: method+path, description, idempotency, parameters table, request/response JSON examples, error codes, and curl examples.

## 7. Generate Summary README

Create `docs/api/README.md` using the summary template. Include: auth methods table, rate limit tiers, endpoint index (method, path, auth, rate limit, idempotent, description) covering every endpoint.

## 8. Report Results

```
Spec files created/updated: N files, X endpoints
Summary: docs/api/README.md
Coverage: endpoints/rate limits/idempotency/error responses: 100%
```

## Rules

- Read code — never guess. Every documented field comes from actual analysis.
- Use realistic JSON examples, not placeholder strings.
- Preserve any manually-added notes when updating.
- Group by business function, not file structure.
- No AI attribution in generated docs.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "document-api" --event complete \
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
