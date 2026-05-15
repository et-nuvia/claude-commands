# Python Project Rules

Copy this file to your project as `CLAUDE.md` or `.claude/CLAUDE.md`.

---

## Stack

- **Python**: 3.14+
- **Package Manager**: UV (pyproject.toml + uv.lock)
- **Linter/Formatter**: Ruff
- **Type Checker**: Pyright (strict mode)
- **Testing**: pytest
- **Web Framework**: FastAPI
- **ORM**: SQLAlchemy 2.x (async)

## Code Standards

- Type hints on ALL functions (parameters and return types)
- Async/await patterns with FastAPI
- Pydantic models for all API request/response schemas
- SQLAlchemy models inherit from declarative base

## File Structure

```
src/
├── api/
│   ├── routes/          # FastAPI routers
│   └── dependencies.py  # Dependency injection
├── models/              # SQLAlchemy models
├── schemas/             # Pydantic schemas
├── services/            # Business logic
├── repositories/        # Data access layer
└── core/
    ├── config.py        # Settings (from secrets manager)
    └── database.py      # DB connection
tests/
├── unit/
├── integration/
└── conftest.py          # Fixtures
```

## Commands

```bash
# Run inside container only
docker compose run --rm app ruff check .      # Lint
docker compose run --rm app ruff format .     # Format
docker compose run --rm app pyright           # Type check
docker compose run --rm app pytest tests/ -v  # Test
```

## Patterns

### API Route
```python
from fastapi import APIRouter, Depends
from src.schemas.user import UserCreate, UserResponse
from src.services.user import UserService

router = APIRouter(prefix="/users", tags=["users"])

@router.post("/", response_model=UserResponse)
async def create_user(
    data: UserCreate,
    service: UserService = Depends(),
) -> UserResponse:
    return await service.create(data)
```

### Service
```python
from src.repositories.user import UserRepository
from src.schemas.user import UserCreate, UserResponse

class UserService:
    def __init__(self, repo: UserRepository = Depends()) -> None:
        self.repo = repo

    async def create(self, data: UserCreate) -> UserResponse:
        user = await self.repo.create(data)
        return UserResponse.model_validate(user)
```

### Test
```python
import pytest
from httpx import AsyncClient

@pytest.mark.asyncio
async def test_create_user(client: AsyncClient) -> None:
    # Arrange
    payload = {"email": "test@example.com", "name": "Test"}

    # Act
    response = await client.post("/users/", json=payload)

    # Assert
    assert response.status_code == 201
    assert response.json()["email"] == "test@example.com"
```
