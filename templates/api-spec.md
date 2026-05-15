# [API Group Name] API Specification

**Base URL:** `[BASE_PATH]`
**Authentication:** [None / API Key / OAuth / etc.]
**Rate Limit:** [REQUESTS] requests per [WINDOW] (per [IP/key/global])

## Overview

[Brief description of what this API group does, who uses it, and why it exists.]

### Access URLs

| Environment | URL |
|-------------|-----|
| [ENV_NAME] | `[URL]` |

---

## Authentication

[Describe authentication mechanism if applicable. Include header name, token format, and how to obtain credentials. Remove this section if authentication is "None".]

**Header:** `[HEADER_NAME]: [TOKEN_FORMAT]`

---

## Rate Limiting

| Tier | Limit | Window | Key |
|------|-------|--------|-----|
| [TIER_NAME] | [REQUESTS] | [WINDOW] | [IP/API key/global] |

**Rate Limit Response (429):**
```json
{
  "error": "Too many requests",
  "retryAfter": [SECONDS]
}
```

---

## Endpoints

### [Endpoint Name]

```http
[METHOD] [PATH]
```

[Description of what this endpoint does and when to use it.]

**Idempotent:** [Yes / No] — [Brief explanation: e.g., "Safe to retry. Returns same result for same input." or "Creates new resource on each call. Use deduplication key to prevent duplicates."]

**Rate Limit:** [Same as group default / CUSTOM_LIMIT if different]

#### Parameters

| Name | In | Type | Required | Description |
|------|----|------|----------|-------------|
| [PARAM] | [path/query/header] | [TYPE] | [Yes/No] | [Description] |

#### Request Body

```json
{
  [REQUEST_BODY_EXAMPLE]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| [FIELD] | [TYPE] | [Yes/No] | [Description] |

#### Response ([STATUS_CODE])

```json
{
  [RESPONSE_BODY_EXAMPLE]
}
```

#### Error Responses

| Status | Condition |
|--------|-----------|
| [CODE] | [When this error occurs] |

#### Notes

[Any business logic, side effects, or important behavioral details. Remove this subsection if not needed.]

---

### [Next Endpoint Name]

[Repeat the endpoint structure above for each endpoint in this API group.]

---

## Usage Examples

```bash
# [Description of example]
curl -s "[EXAMPLE_URL]" | jq

# [Description of example with auth]
curl -s -H "[AUTH_HEADER]: [TOKEN]" "[EXAMPLE_URL]" | jq
```

---

## Error Responses

All error responses follow this format:

```json
{
  "error": "[ERROR_MESSAGE]"
}
```

| Status | Description |
|--------|-------------|
| 400 | Bad request — invalid parameters or body |
| 401 | Unauthorized — missing or invalid credentials |
| 403 | Forbidden — valid credentials but insufficient permissions |
| 404 | Not found — resource does not exist |
| 429 | Rate limit exceeded — retry after specified delay |
| 500 | Internal server error |
