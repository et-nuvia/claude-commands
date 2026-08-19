---
name: document-api
description: Scan project for API endpoints and generate comprehensive documentation
user_invocable: true
---


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

