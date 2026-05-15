# [Service Name] — API Reference

**Service:** [SERVICE_DESCRIPTION]

| Environment | Public URL | Private URL | Notes |
|-------------|------------|-------------|-------|
| [ENV_NAME] | `[PUBLIC_URL]` | `[PRIVATE_URL]` | [ACCESS_NOTES] |

---

## Overview

[Brief description of the API surface: what it serves, who consumes it, and the general architecture (e.g., REST, versioned, etc.).]

---

## Authentication Summary

| Method | Description | Used By |
|--------|-------------|---------|
| None | No authentication required | [Which endpoint groups] |
| [AUTH_METHOD] | [How it works] | [Which endpoint groups] |

---

## Rate Limiting Summary

| Tier | Limit | Window | Applies To |
|------|-------|--------|------------|
| Global | [REQUESTS] req | [WINDOW] | All endpoints unless overridden |
| [TIER_NAME] | [REQUESTS] req | [WINDOW] | [Endpoint groups or specific paths] |

**Rate limit headers returned:**
- `Retry-After: [SECONDS]` — seconds until rate limit resets

---

## Access Patterns

[Describe how different consumers access the API. For example: public patients use the form endpoints, internal systems use admin endpoints via VPN, monitoring tools use health endpoints, etc.]

---

## API Specifications

| Spec File | Description | Endpoints | Auth |
|-----------|-------------|-----------|------|
| [`[FILENAME]`]([RELATIVE_PATH]) | [Brief description] | [COUNT] | [AUTH_METHOD] |

---

## Endpoint Index

### [API Group Name]

**Spec:** [`[FILENAME]`]([RELATIVE_PATH])

| Method | Path | Auth | Rate Limit | Idempotent | Description |
|--------|------|------|------------|------------|-------------|
| `[METHOD]` | `[PATH]` | [None/Key/etc.] | [LIMIT] | [Yes/No] | [Brief description] |

### [Next API Group Name]

[Repeat the group structure above for each API group.]

---

## Quick Reference

### Common Operations

```bash
# [Operation description]
curl -s "[URL]" | jq

# [Operation description]
curl -s -H "[AUTH_HEADER]: [TOKEN]" "[URL]" | jq
```

### Status Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 201 | Created |
| 400 | Bad request |
| 401 | Unauthorized |
| 403 | Forbidden |
| 404 | Not found |
| 409 | Conflict |
| 429 | Rate limited |
| 500 | Internal error |
| 503 | Service unavailable |
