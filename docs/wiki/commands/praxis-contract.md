---
command: praxis-contract
group: outlier
backing_script: ~/.claude/scripts/praxis-contract.sh
mutates: []
runtime: ~5s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /praxis-contract

Queries the Praxis API to retrieve endpoint contracts — the field definitions,
types, required flags, enums, example responses, and JSON Schemas that other
services must implement. Run it without arguments to list all available
contracts, or pass an endpoint path to drill into the full specification.
Read-only; never modifies anything.

---

## When to use it

- You are implementing an endpoint that Praxis orchestrates and need the exact field contract
- You want to confirm which endpoints Praxis exposes before starting integration work
- You want to generate a stub implementation from the authoritative contract definition

## Usage

```bash
/praxis-contract [endpoint-path]
```

**Common invocations:**

```bash
/praxis-contract                   # list all available contracts
/praxis-contract /capacity         # full contract for the /capacity endpoint
/praxis-contract /health           # full contract for the /health endpoint
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Endpoint path (e.g., `/capacity`). Omit to list all available contracts. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `curl` or equivalent HTTP client | Queries the Praxis API | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `PRAXIS_URL` env var — optional; overrides the default Praxis service URL if set

## Backing script

**Script**: `~/.claude/scripts/praxis-contract.sh`

**Inputs:** `$ARGUMENTS` (optional endpoint path). Reads `PRAXIS_URL` from the
environment to locate the Praxis service.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_contracts`, `display_contract`, `fix_error`}
- On `display_contracts`: `contracts[]` — array of `{endpoint, method, description}`
- On `display_contract`: `contract` — full specification including `fields[]`
  (name, type, required, description, example), `example_response`, `json_schema`,
  and `enums{}`
- On `fix_error`: `message` describing the failure

**Invocation surface:**

```bash
~/.claude/scripts/praxis-contract.sh                    # list contracts
~/.claude/scripts/praxis-contract.sh /capacity          # single contract
```

## How it works

1. **Route** — if no argument is provided, the script calls the Praxis contracts
   index endpoint and returns `display_contracts`. If an endpoint path is
   provided, it fetches that contract directly and returns `display_contract`.
2. **List display** — the LLM formats `contracts[]` as a table (endpoint,
   method, description) and invites the user to pick one for full detail.
3. **Contract display** — the LLM renders the fields table with types, required
   flags, descriptions, and examples; shows the example response JSON; shows the
   JSON Schema for validation; and explains any enum constraints.
4. **Stub offer** — if the user is implementing the endpoint, the LLM offers to
   generate a language-appropriate stub (FastAPI, Express, etc.) pre-populated
   with the required fields.
5. **Error handling** — on `fix_error`, the LLM reports the error and suggests
   either checking whether Praxis is running or setting `PRAXIS_URL` to point
   to the correct host.

## Example workflows

### Scenario: Starting a new endpoint implementation

```
/praxis-contract /capacity          # read the contract
# implement the endpoint in code
/test                               # verify the implementation matches the schema
```

### Scenario: Browsing available contracts

```
/praxis-contract
```

```
Available Praxis Contracts
  Endpoint        Method  Description
  /capacity       POST    Report service capacity and availability
  /health         GET     Liveness and readiness probe
  /version        GET     Return deployed version string
  /status         GET     Extended service status with dependency health

Pick an endpoint to see the full contract.
```

## Notes & gotchas

- Praxis must be reachable from the machine running the command. If the service
  is not running locally, set `PRAXIS_URL` to point to the correct host:
  `export PRAXIS_URL=http://praxis.internal:8080`.
- The command is read-only; it never modifies Praxis state or local files.
- **If it fails:** `fix_error` with "unreachable" — verify Praxis is running
  (`curl $PRAXIS_URL/health`) and that `PRAXIS_URL` is set correctly.
  "Endpoint not found" — run `/praxis-contract` without arguments to list valid paths.
