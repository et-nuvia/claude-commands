# Test Database Reset Pattern

## Overview

Tests run against a pre-seeded database that is reset **once** before the test suite starts. Individual tests get isolation via savepoint-rollback — no per-test TRUNCATE, no deadlocks.

## How It Works

### 1. Reset Script (`scripts/reset-test-db.sh`)

Called by Makefile test targets before pytest. Reads config from `PROJECT.yaml` and `docker-compose.yml`:

- **`databases[0].type`** — determines driver (`postgresql+asyncpg`, `mysql+aiomysql`)
- **Docker Compose DB service** — reads `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` from environment
- **`testing.seed_module`** — Python module:function for baseline seed data (default: `tests.seed:seed_baseline`)
- **Components** — finds the API service and Python package from `components[]`

The script:
1. Drops and recreates `{db_name}_test`
2. Runs `Base.metadata.create_all` (imports all models via `{package}.models`)
3. Calls the seed function to insert baseline data
4. Commits

### 2. Guard Variable (`TASKFORGE_TEST_DB_RESET`)

Prevents nested Make targets from re-running the reset:

```makefile
# Parent resets, then passes guard to children
test: reset-test-db
    TASKFORGE_TEST_DB_RESET=1 $(MAKE) test-unit test-e2e

# Leaf targets also call reset (for standalone use)
# but the guard skips if parent already did it
test-unit-backend: reset-test-db
    TASKFORGE_TEST_DB_RESET=1 $(MAKE) -C backend test-unit
```

- `make test` → resets once, children skip
- `make test-unit-backend` → resets (no parent set the guard)
- Crashes/hangs leave no stale state (env var dies with process)

### 3. Savepoint-Rollback Isolation (`conftest.py`)

Each test's `db` fixture:
1. Opens a real transaction on the connection
2. Starts a SAVEPOINT (nested transaction)
3. Listens for `after_transaction_end` to restart savepoints after each `commit()`
4. Yields the session
5. Rolls back the outer transaction — all changes vanish

```python
@pytest.fixture
async def db(_test_engine):
    async with _test_engine.connect() as conn:
        txn = await conn.begin()
        await conn.begin_nested()
        session = AsyncSession(bind=conn, expire_on_commit=False)

        @sa_event.listens_for(session.sync_session, "after_transaction_end")
        def _restart_savepoint(sess, transaction):
            if conn.sync_connection.in_nested_transaction():
                return
            conn.sync_connection.begin_nested()

        try:
            yield session
        finally:
            await session.close()
            await txn.rollback()
```

## Rules for Test Authors

### Baseline Data is READ-ONLY

The seed data (companies, users, API keys, projects) is shared across all tests. Never mutate it — if you need to test deletion or updates, create your own records first.

### Each Suite Owns Its Data

Tests should create their own records using unique IDs. Don't rely on data created by other test files. The savepoint rollback ensures your data doesn't leak to other tests.

### Don't Bypass the `db` Fixture

Never create your own `create_async_engine()` or `async_sessionmaker()` in test files. Always use the `db` fixture (or `seeded_db` which is an alias). If you need a session for a tool/service that takes a session factory, wrap the `db` fixture session:

```python
@asynccontextmanager
async def _session_from_fixture(db):
    yield db

set_session_factory(lambda: _session_from_fixture(db))
```

### Don't Create Conflicting Seed Data

If your test needs a company membership, check if it already exists in the baseline (see `tests/seed.py`). Don't blindly insert — you'll get `UniqueViolationError`.

### Assertions Must Account for Baseline

If you query `SELECT count(*) FROM projects`, the baseline already has 1 project. Either:
- Filter by your own company/user IDs
- Use `>=` instead of `==`
- Create test-specific data with unique identifiers

## PROJECT.yaml Configuration

```yaml
databases:
  - name: primary
    type: postgresql    # Driver auto-detected
    ...

testing:
  seed_module: tests.seed:seed_baseline   # module:function
  ...
```

## File Locations

| File | Purpose |
|------|---------|
| `scripts/reset-test-db.sh` | Drop/create/seed test DB |
| `tests/seed.py` | Baseline seed data and constants |
| `tests/conftest.py` | Fixtures (db, seeded_db, client, auth helpers) |
| `PROJECT.yaml` | DB type, seed module config |
