# Python Development Guide

## Default Stack

| Component | Tool | Version |
|-----------|------|---------|
| Python | 3.14+ | Latest stable |
| Package Manager | [UV](https://github.com/astral-sh/uv) | Fast Python package installer |
| Linting & Formatting | [Ruff](https://github.com/astral-sh/ruff) | Replaces Black, flake8, isort |
| Type Checking | [Pyright](https://github.com/microsoft/pyright) | Fast static type checker |
| Testing | pytest | With pytest-asyncio for async tests |
| Framework | FastAPI | Async web framework |
| ORM | SQLAlchemy | With async support |

Projects may override these in their project-specific CLAUDE.md.

---

## Code Style

### Follow PEP 8

Ruff enforces PEP 8 automatically. Key points:
- 4 spaces for indentation (no tabs)
- 88 character line length (Black default)
- snake_case for functions and variables
- PascalCase for classes
- UPPER_SNAKE_CASE for constants

### Type Hints (Required)

All functions must have type hints:

```python
# Required
def process_user(user_id: int, include_deleted: bool = False) -> User | None:
    ...

# Required for class attributes
class UserService:
    db: AsyncSession
    cache: Redis

    def __init__(self, db: AsyncSession, cache: Redis) -> None:
        self.db = db
        self.cache = cache
```

Use modern Python 3.14 syntax:
```python
# Good (Python 3.14)
def get_users() -> list[User]:
    ...

def find_user(user_id: int) -> User | None:
    ...

# Avoid (old style)
from typing import List, Optional

def get_users() -> List[User]:
    ...

def find_user(user_id: int) -> Optional[User]:
    ...
```

### Imports

Ruff handles import sorting. Follow this order:
1. Standard library
2. Third-party packages
3. Local imports

```python
import os
from datetime import datetime
from pathlib import Path

import httpx
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.user import User
```

---

## Naming Conventions

### Descriptive Names

Names should be self-documenting:

```python
# Good
def calculate_compatible_updates(
    current_version: str,
    available_versions: list[str],
    minimum_python_version: str,
) -> list[str]:
    compatible_versions = [
        version for version in available_versions
        if meets_python_requirement(version, minimum_python_version)
    ]
    return compatible_versions

# Bad
def calc(v: str, av: list[str], mpv: str) -> list[str]:
    cv = [x for x in av if check(x, mpv)]
    return cv
```

### Boolean Variables and Functions

Prefix with `is_`, `has_`, `can_`, `should_`:

```python
is_active = True
has_permission = user.can_edit(resource)
can_delete = not resource.is_locked
should_notify = settings.notifications_enabled

def is_valid_email(email: str) -> bool:
    ...

def has_required_permissions(user: User, action: str) -> bool:
    ...
```

### Collections

Use plural names:

```python
users = get_all_users()
active_user_ids = [u.id for u in users if u.is_active]
email_to_user = {u.email: u for u in users}
```

---

## Function Design

### Keep Functions Focused

Each function should do one thing:

```python
# Good - single responsibility
async def get_user_by_email(db: AsyncSession, email: str) -> User | None:
    result = await db.execute(select(User).where(User.email == email))
    return result.scalar_one_or_none()

async def validate_user_credentials(user: User, password: str) -> bool:
    return verify_password(password, user.hashed_password)

async def create_access_token(user: User) -> str:
    return jwt.encode({"sub": user.id}, settings.jwt_secret)

# Bad - does too many things
async def login(db: AsyncSession, email: str, password: str) -> str:
    result = await db.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    if not user or not verify_password(password, user.hashed_password):
        raise HTTPException(401)
    return jwt.encode({"sub": user.id}, settings.jwt_secret)
```

### Async/Await Patterns

Use async consistently with FastAPI:

```python
# Good - async all the way
async def get_user_with_orders(db: AsyncSession, user_id: int) -> User:
    user = await get_user(db, user_id)
    orders = await get_user_orders(db, user_id)
    user.orders = orders
    return user

# Bad - blocking call in async function
async def get_user_with_orders(db: AsyncSession, user_id: int) -> User:
    user = await get_user(db, user_id)
    orders = requests.get(f"/api/orders/{user_id}")  # Blocks!
    return user
```

For CPU-bound or blocking operations:

```python
from fastapi.concurrency import run_in_threadpool

async def process_large_file(file_path: Path) -> dict:
    # Run blocking operation in thread pool
    result = await run_in_threadpool(parse_large_file, file_path)
    return result
```

---

## Error Handling

### Use Specific Exceptions

```python
# Good - specific exceptions
class UserNotFoundError(Exception):
    def __init__(self, user_id: int):
        self.user_id = user_id
        super().__init__(f"User {user_id} not found")

class InvalidCredentialsError(Exception):
    pass

async def get_user(db: AsyncSession, user_id: int) -> User:
    user = await db.get(User, user_id)
    if not user:
        raise UserNotFoundError(user_id)
    return user

# Bad - generic exceptions
async def get_user(db: AsyncSession, user_id: int) -> User:
    user = await db.get(User, user_id)
    if not user:
        raise Exception("User not found")  # Too generic
    return user
```

### FastAPI Exception Handlers

```python
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI()

@app.exception_handler(UserNotFoundError)
async def user_not_found_handler(request: Request, exc: UserNotFoundError):
    return JSONResponse(
        status_code=404,
        content={"detail": f"User {exc.user_id} not found"},
    )
```

---

## Project Structure

### Standard Layout

```
backend/
├── app/
│   ├── __init__.py
│   ├── main.py               # FastAPI app entry point
│   ├── api/                   # API endpoints
│   │   ├── __init__.py
│   │   ├── deps.py            # Shared dependencies
│   │   └── v1/
│   │       ├── __init__.py
│   │       ├── router.py      # Main router
│   │       ├── users.py       # User endpoints
│   │       └── auth.py        # Auth endpoints
│   ├── core/                  # Core functionality
│   │   ├── __init__.py
│   │   ├── config.py          # Settings
│   │   └── security.py        # Auth utilities
│   ├── models/                # SQLAlchemy models
│   │   ├── __init__.py
│   │   ├── base.py            # Base model class
│   │   └── user.py
│   ├── schemas/               # Pydantic schemas
│   │   ├── __init__.py
│   │   └── user.py
│   ├── crud/                  # Database operations
│   │   ├── __init__.py
│   │   └── user.py
│   ├── services/              # Business logic
│   │   ├── __init__.py
│   │   └── user_service.py
│   ├── workers/               # Background jobs
│   │   └── __init__.py
│   └── utils/                 # Utilities
│       └── __init__.py
├── tests/                     # Mirrors app/ structure
│   ├── conftest.py            # Shared fixtures
│   ├── test_api/
│   ├── test_services/
│   └── test_models/
├── alembic/                   # Database migrations
│   ├── versions/
│   └── env.py
├── pyproject.toml             # UV/Ruff/Pyright config
└── requirements.txt           # Dependencies
```

### Layer Responsibilities

| Layer | Purpose | Can Call |
|-------|---------|----------|
| `api/` | HTTP handling, request/response | services, crud |
| `services/` | Business logic | crud, other services |
| `crud/` | Database operations | models |
| `models/` | Data structures | nothing |
| `schemas/` | Validation/serialization | nothing |

---

## Testing

### Test Structure

Mirror the app structure:

```
tests/
├── conftest.py                # Shared fixtures
├── test_api/
│   └── test_users.py
├── test_services/
│   └── test_user_service.py
├── test_crud/
│   └── test_user.py
└── test_models/
    └── test_user.py
```

### Fixtures

```python
# conftest.py
import pytest
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from app.models.base import Base

@pytest.fixture
async def db_session():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    async with AsyncSession(engine) as session:
        yield session

@pytest.fixture
def user_factory(db_session: AsyncSession):
    async def create_user(**kwargs) -> User:
        user = User(**kwargs)
        db_session.add(user)
        await db_session.commit()
        return user
    return create_user
```

### Test Patterns

```python
# test_user_service.py
import pytest
from app.services.user_service import UserService

class TestUserService:
    async def test_get_user_returns_user_when_exists(
        self, db_session: AsyncSession, user_factory
    ):
        # Arrange
        user = await user_factory(email="test@example.com")
        service = UserService(db_session)

        # Act
        result = await service.get_user(user.id)

        # Assert
        assert result is not None
        assert result.email == "test@example.com"

    async def test_get_user_raises_when_not_found(
        self, db_session: AsyncSession
    ):
        service = UserService(db_session)

        with pytest.raises(UserNotFoundError):
            await service.get_user(99999)
```

### Test Commands

```bash
# Run all tests
docker compose run --rm backend pytest

# Run specific file
docker compose run --rm backend pytest tests/test_services/test_user_service.py

# Run with coverage
docker compose run --rm backend pytest --cov=app --cov-report=term-missing

# Run specific test
docker compose run --rm backend pytest -k "test_get_user_returns"
```

---

## Dependency Management

### Adding Dependencies

Always inside containers:

```bash
# 1. Add to requirements.txt without version
echo "new-package" >> backend/requirements.txt

# 2. Rebuild and check installed version
docker compose build backend
docker compose run --rm backend pip show new-package | grep Version

# 3. Update requirements.txt with pinned version
# new-package==1.2.3
```

### pyproject.toml Configuration

```toml
[project]
name = "app"
version = "0.1.0"
requires-python = ">=3.14"

[tool.ruff]
line-length = 88
target-version = "py314"

[tool.ruff.lint]
select = [
    "E",      # pycodestyle errors
    "W",      # pycodestyle warnings
    "F",      # Pyflakes
    "I",      # isort
    "B",      # flake8-bugbear
    "C4",     # flake8-comprehensions
    "UP",     # pyupgrade
    "ARG",    # flake8-unused-arguments
    "SIM",    # flake8-simplify
]
ignore = [
    "E501",   # line too long (handled by formatter)
]

[tool.ruff.lint.isort]
known-first-party = ["app"]

[tool.pyright]
pythonVersion = "3.14"
typeCheckingMode = "strict"
```

---

## Code Quality Commands

```bash
# Lint (check only)
docker compose run --rm backend ruff check .

# Lint (auto-fix)
docker compose run --rm backend ruff check --fix .

# Format
docker compose run --rm backend ruff format .

# Type check
docker compose run --rm backend pyright

# All checks
docker compose run --rm backend ruff check . && \
docker compose run --rm backend ruff format --check . && \
docker compose run --rm backend pyright && \
docker compose run --rm backend pytest
```

---

## FastAPI Patterns

### Dependency Injection

```python
# app/api/deps.py
from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_db
from app.services.user_service import UserService

async def get_user_service(
    db: AsyncSession = Depends(get_db),
) -> UserService:
    return UserService(db)

# app/api/v1/users.py
from fastapi import APIRouter, Depends
from app.api.deps import get_user_service

router = APIRouter()

@router.get("/users/{user_id}")
async def get_user(
    user_id: int,
    service: UserService = Depends(get_user_service),
):
    return await service.get_user(user_id)
```

### Pydantic Schemas

```python
# app/schemas/user.py
from pydantic import BaseModel, EmailStr

class UserBase(BaseModel):
    email: EmailStr
    name: str

class UserCreate(UserBase):
    password: str

class UserUpdate(BaseModel):
    email: EmailStr | None = None
    name: str | None = None

class UserResponse(UserBase):
    id: int
    is_active: bool

    model_config = {"from_attributes": True}
```

### SQLAlchemy Models

```python
# app/models/user.py
from sqlalchemy import String, Boolean
from sqlalchemy.orm import Mapped, mapped_column
from app.models.base import Base

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(255))
    hashed_password: Mapped[str] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
```

---

## Code Examples

Implementation templates in [docs/code/](../code/):

- [Python Overview](../code/python/overview.md) - FastAPI project structure and patterns
- [Python + AWS Secrets Manager](../code/python/secrets-aws.md)
- [Python + Infisical](../code/python/secrets-infisical.md)

---

## Checklist

Before committing Python code:

- [ ] All tests pass (`pytest`)
- [ ] No linting errors (`ruff check .`)
- [ ] Code is formatted (`ruff format .`)
- [ ] Type checking passes (`pyright`)
- [ ] Coverage >= 80%
- [ ] Type hints on all functions
- [ ] Descriptive variable names
- [ ] No commented-out code
