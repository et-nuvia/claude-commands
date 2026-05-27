# Understand-Anything Graph Schema (v1)

**Schema file**: `schemas/understand-graph.schema.json` (JSON Schema draft 2020-12)
**Produced by**: `/understand-scan`
**Consumed by**: `/understand-explore`, `/understand-impact`, the hosted viewer, and any command that auto-loads `.understand/graph.json` for structural context.

This document is the human-readable companion to the JSON schema. The schema is authoritative — if these two disagree, the schema wins.

## Why this schema exists

The graph is the **contract** between the scan pipeline and every consumer. Locking it lets:

- Commands silently load it without coordinating versions
- The hosted viewer treat any repo's graph as a black-box JSON document
- Incremental rescans key off file hashes deterministically
- Schema evolution be tracked and breaking changes flagged via `graph_schema_version`

## Top-level shape

```jsonc
{
  "graph_schema_version": 1,
  "meta":   { ... },
  "layers": [ ... ],
  "nodes":  [ ... ],
  "edges":  [ ... ]
}
```

All four top-level keys are required. Unknown keys at the root are rejected (`additionalProperties: false`).

## `graph_schema_version`

Integer, currently `1`. Consumers MUST check this and degrade gracefully on mismatch (e.g., log + skip rather than crash). Bumped on any breaking change to this document.

## `meta` — scan provenance

| Field | Type | Required | Description |
|---|---|---|---|
| `commit_sha` | string (7–40 hex) | yes | Git commit the scan was performed against. Drives auto-update threshold logic. |
| `scanned_at` | ISO-8601 date-time | yes | When the scan completed. |
| `file_hashes` | object<path, sha256:HEX> | yes | Map of repo-relative file path to source hash. Drives incremental rescans — only files whose hash changes get re-analyzed. |
| `scan_cost_usd` | number ≥ 0 | no | Total LLM cost for this scan. |
| `scan_duration_seconds` | number ≥ 0 | no | Wall-clock duration. |
| `project_knowledge_sha` | string \| null | no | sha256 of `PROJECT-KNOWLEDGE.md` at scan time; null if absent. Lets consumers detect PK drift since last scan. |
| `scanner_version` | string (semver) | no | Version of the scan pipeline. |

`meta` is open to extension (`additionalProperties: true`) so the pipeline can record diagnostics without a schema bump.

## `layers` — architectural groupings

Each layer is referenced from `node.layer`. Layers are repo-defined, not enumerated, so different stacks can use different vocabularies.

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string (`[a-z0-9_-]+`) | yes | Stable identifier (e.g., `api`, `service`, `data`, `ui`). |
| `label` | string | yes | Display name (e.g., `"API"`, `"Data Access"`). |
| `color` | `#RRGGBB` | no | Color used by the viewer. |
| `description` | string | no | Optional clarification. |

Example:
```json
{ "id": "api", "label": "API", "color": "#3366cc", "description": "HTTP boundary" }
```

## `nodes` — files and symbols

Each node represents either a container (`file`, `module`) or a symbol (`function`, `class`, `method`, `type`).

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Stable unique identifier. Convention: `<path>` for files, `<path>::<symbol>` for symbols. |
| `kind` | enum | yes | One of: `file`, `module`, `function`, `class`, `method`, `type`. |
| `path` | string | yes | Repo-relative path to the source file. |
| `name` | string | yes | Display name. |
| `summary` | string (1–2000 chars) | yes | LLM-authored plain-English summary. Should use PK vocabulary when applicable. |
| `layer` | string \| null | no | Layer id from `layers[]`, or null if unclassified. |
| `hash` | `sha256:HEX` | no | sha256 of the source extent that produced this summary. Enables incremental rescan. |
| `tags` | string[] | no | Freeform tags (e.g., `entry-point`, `deprecated`, `generated`). |
| `line_start` | integer ≥ 1 | no | Source range start (for symbols). |
| `line_end` | integer ≥ 1 | no | Source range end (for symbols). |

Unknown fields on nodes are rejected (`additionalProperties: false`). New fields require a schema bump.

### Node id convention

- File node: `src/auth/login.ts`
- Symbol node: `src/auth/login.ts::login`
- Method on a class: `src/auth/Session.ts::Session.refresh`

The exact form is a convention, not enforced by the schema — but consumers (especially `understand-impact`) expect this shape.

## `edges` — relationships

Each edge is a directed relationship between two node ids.

| Field | Type | Required | Description |
|---|---|---|---|
| `from` | string | yes | Source node id. |
| `to` | string | yes | Target node id. |
| `kind` | enum | yes | One of: `calls`, `imports`, `extends`, `implements`, `references`, `contains`. |

Edge kinds:

- `calls` — function/method invocation
- `imports` — module-level import
- `extends` — class inheritance
- `implements` — interface implementation
- `references` — type or value reference outside the above kinds
- `contains` — parent→child structural edge (file `contains` its symbols, class `contains` its methods)

The schema does NOT enforce that `from` and `to` reference existing nodes — `assemble-reviewer` is responsible for that integrity check at write time.

## Full example

```json
{
  "graph_schema_version": 1,
  "meta": {
    "commit_sha": "abc1234def5678",
    "scanned_at": "2026-05-22T03:00:00Z",
    "file_hashes": {
      "src/auth/login.ts": "sha256:0000000000000000000000000000000000000000000000000000000000000001"
    },
    "scan_cost_usd": 0.42,
    "scan_duration_seconds": 12.3,
    "project_knowledge_sha": "sha256:0000000000000000000000000000000000000000000000000000000000000002",
    "scanner_version": "1.0.0"
  },
  "layers": [
    { "id": "api", "label": "API", "color": "#3366cc" },
    { "id": "data", "label": "Data" }
  ],
  "nodes": [
    {
      "id": "src/auth/login.ts::login",
      "kind": "function",
      "path": "src/auth/login.ts",
      "name": "login",
      "layer": "api",
      "summary": "Authenticates user with email and password, returns JWT on success.",
      "hash": "sha256:0000000000000000000000000000000000000000000000000000000000000003",
      "tags": ["entry-point"],
      "line_start": 12,
      "line_end": 45
    },
    {
      "id": "src/auth/login.ts",
      "kind": "file",
      "path": "src/auth/login.ts",
      "name": "login.ts",
      "summary": "Login HTTP handler."
    }
  ],
  "edges": [
    { "from": "src/auth/login.ts::login", "to": "src/db/users.ts::findByEmail", "kind": "calls" },
    { "from": "src/auth/login.ts", "to": "src/auth/login.ts::login", "kind": "contains" }
  ]
}
```

## Validation

```bash
# Validate a graph against the schema
ajv validate -s schemas/understand-graph.schema.json -d .understand/graph.json --spec=draft2020
```

`assemble-reviewer` performs this validation before writing the graph; commits to `.understand/graph.json` should never contain an invalid graph.

## Versioning policy

- **Patch-level changes** (no version bump): documentation clarifications, adding `description` strings to schema fields.
- **Additive changes** (no version bump): adding a new optional field to an existing object, adding a new value to a non-strict enum.
- **Breaking changes** (`graph_schema_version` bump): removing a field, renaming a field, narrowing a type, adding a required field, removing or renaming an enum value.

On a bump:
1. The schema file is updated and the `const` for `graph_schema_version` increments.
2. This reference doc is updated with a migration note.
3. Consumers check the version and either migrate, refuse, or warn.
4. The auto-update cron rescans all repos to produce graphs at the new version.
