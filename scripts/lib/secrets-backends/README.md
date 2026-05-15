# Secrets Manager Adapters

This directory holds adapter shims for secrets backends (Infisical, AWS
Secrets Manager, and any future provider). Scripts that need to read,
write, rotate, or restore secrets source `scripts/lib/secrets-api.sh`,
which dispatches to the adapter matching `profile_env_get .secrets.backend`
(with PROJECT.yaml override).

Same pattern as `scripts/lib/git-platforms/`. Adding a new backend = one
new file in this directory + one case branch in the dispatcher.

## Usage from a calling script

```bash
source "${SCRIPT_DIR}/lib/secrets-api.sh"
load_sm_adapter || exit 1

# Now the sm_* functions are defined. Same call works for any backend.
db_password=$(sm_get production /database DATABASE_PASSWORD)
sm_set staging /config LOG_LEVEL debug
```

## Contract

Every adapter MUST implement every function below. All functions return
data on stdout when they have data to return, human-readable errors on
stderr, and one of these exit codes:

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error (network, auth, validation, unexpected state) |
| `2` | Not found (the requested secret/path doesn't exist) |
| `3` | **Reserved.** Future contract additions not yet implemented on every adapter. Today, every function is implemented on every adapter — no function returns `3`. |

Every function takes `<env>` as its first arg (e.g. `production`,
`staging`). The `<path>` arg is the logical secret folder (e.g.
`/database`, `/admin`); adapters translate this to backend-native
addressing (Infisical paths, AWS secret name segments).

### Read

| Function | Args | Returns |
|---|---|---|
| `sm_get` | `<env> <path> <key>` | plain value on stdout |
| `sm_get_json` | `<env> <path>` | JSON object of all keys at path |
| `sm_health` | — | exit 0 if auth + network OK; exit 1 with stderr details |
| `sm_ui_url` | `<env> <path>` | URL for the web UI (for human-facing help) |

### Write

| Function | Args | Returns |
|---|---|---|
| `sm_set` | `<env> <path> <key> <value>` | empty on success |
| `sm_set_json` | `<env> <path> <json>` | empty on success; replaces ALL keys at path |

### Versions

| Function | Args | Returns |
|---|---|---|
| `sm_versions` | `<env> <path> <key>` | JSON array `[{version, created_at, is_current}]` |
| `sm_restore` | `<env> <path> <key> <version>` | empty on success |

### Rotation

| Function | Args | Returns |
|---|---|---|
| `sm_rotate_prepare` | `<env> <path>` | empty (most backends are no-op; AWS may stage a pending value) |

## Path semantics

The `<path>` arg is a forward-slash-separated logical address that
adapters translate:

- **Infisical**: `/database` → API path `/database` (one-to-one).
- **AWS SM**: `/database` → secret name `${app}/${env}/database`,
  where `${app}` is read from PROJECT.yaml `.app_name` and `${env}` is
  the function's first arg. AWS-SM "secrets" are JSON blobs, so
  individual keys live inside the value.

This means `sm_get production /database DATABASE_PASSWORD` works the
same way against both backends, with the adapter handling the
translation.

## Adding a new adapter (e.g., HashiCorp Vault)

1. Copy `infisical.sh` as `<backend>.sh` — its CLI-based pattern is
   closer to most secrets backends than `aws-sm.sh`'s SDK-based one.
2. Implement every function in the contract. Use `_vault_call()` (or
   equivalent) as your private low-level helper.
3. Add a case branch to `load_sm_adapter()` in `../secrets-api.sh`.
4. Add the `<backend>` value as a valid choice in
   `profiles/default.yaml.example` under the `secrets.backend` field.

## Special case: `none`

For users who don't want to use a secrets backend at all, set
`secrets.backend: none` in the profile or PROJECT.yaml. The dispatcher
loads `none.sh`, which provides no-op stubs:

- Read functions return empty / `{}` / exit 2
- Write/restore functions return exit 3 (unsupported)
- `sm_health` returns 0 — nothing to check

This lets scripts that always call `sm_health` etc. continue to work
without branching on backend presence.

## Testing an adapter

```bash
# Force a specific adapter regardless of profile
SM_ADAPTER_OVERRIDE=infisical source scripts/lib/secrets-api.sh
load_sm_adapter
sm_health && echo OK || echo FAIL
```

## Why a flat namespace?

Same reasoning as the git platform shims (see `../git-platforms/README.md`).
Function names like `sm_get` (not `infisical::secret::get`) match bash's
lack of true namespacing. The dispatcher picks the adapter at source time,
so only one set of `sm_*` functions exists per shell session.
