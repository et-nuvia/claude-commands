# syntax=docker/dockerfile:1
# Python DHI (Docker Hardened Images) Multi-Stage Dockerfile
#
# This template provides a production-ready Docker build for Python projects
# using DHI base images, uv for dependency management, and pytest for testing.
#
# DHI images are non-root by default — no manual user creation needed.
#
# Variables:
#   SOURCE_DIR      - Python source directory (default: src)
#   TEST_DIR        - Directory containing tests (default: tests)
#   MIN_COVERAGE    - Minimum test coverage percentage (default: 80)
#   PYTHON_MODULE   - Python module to run (default: app)
#   PYTHON_VERSION  - Python version tag (default: 3.14)
#
# Customization points:
#   - Dependencies: Add system packages in builder stage via apt
#   - Package manager: uv by default, switch to pip/poetry if needed
#   - Test command: Modify pytest options in testing stage
#   - Entry point: Change module name or use different execution method
#
# Base images:
#   - Build: dhi.io/python:<version>-debian13-dev (has shell, apt, build tools)
#   - Runtime: dhi.io/python:<version>-debian13 (no shell, non-root by default)

# ---------------------------------------------------------------------------
# Stage 1: Builder — install dependencies and prepare application
# ---------------------------------------------------------------------------
FROM dhi.io/python:3.14-debian13-dev AS builder

WORKDIR /app

# Copy dependency files first for better layer caching
# Customization: Add requirements.txt, Pipfile, etc. if not using uv
COPY pyproject.toml uv.lock ./

# Install Python dependencies with uv (cached)
# Customization: Change to pip install or poetry install if needed
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# Copy source code
# Customization: Add additional directories if your project structure differs
COPY ${SOURCE_DIR:-src}/ ./${SOURCE_DIR:-src}/

# Install the project itself
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# ---------------------------------------------------------------------------
# Stage 2: Testing (conditional — activated in CI with --build-arg RUN_TESTS=true)
# ---------------------------------------------------------------------------
FROM builder AS testing

ARG RUN_TESTS=false

# Install dev dependencies for testing
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen

# Copy tests
COPY ${TEST_DIR:-tests}/ ./${TEST_DIR:-tests}/

# Run tests if enabled (typically in CI/CD)
# Customization: Add pytest plugins or modify options
RUN if [ "$RUN_TESTS" = "true" ]; then \
      uv run pytest ${TEST_DIR:-tests}/ -v \
        --cov=${SOURCE_DIR:-src} \
        --cov-report=term-missing \
        --cov-fail-under=${MIN_COVERAGE:-80}; \
    fi

# ---------------------------------------------------------------------------
# Stage 3: Development — identical base to production for dev/prod parity
# ---------------------------------------------------------------------------
FROM dhi.io/python:3.14-debian13 AS development

# OCI labels
ARG VERSION=dev
ARG CREATED
ARG REVISION
LABEL org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}"

WORKDIR /app

# Copy virtual environment and application from builder
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/${SOURCE_DIR:-src} /app/${SOURCE_DIR:-src}

ENV PATH="/app/.venv/bin:$PATH"

# Development may override entrypoint via docker-compose command
# Customization: Change module name or use different execution method
ENTRYPOINT ["python", "-m", "${PYTHON_MODULE:-app}"]

# ---------------------------------------------------------------------------
# Stage 4: Production — minimal runtime image (default target)
# ---------------------------------------------------------------------------
FROM dhi.io/python:3.14-debian13 AS production

# OCI labels
ARG VERSION
ARG CREATED
ARG REVISION
LABEL org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}"

WORKDIR /app

# Copy virtual environment and application from builder
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/${SOURCE_DIR:-src} /app/${SOURCE_DIR:-src}

ENV PATH="/app/.venv/bin:$PATH"

# Health check
# Customization: Change endpoint/port to match your application
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]

# Customization: Change module name or use different execution method
# Examples:
#   - FastAPI: ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
#   - Django: ["python", "manage.py", "runserver", "0.0.0.0:8000"]
#   - CLI tool: ["/app/.venv/bin/mytool"]
ENTRYPOINT ["python", "-m", "${PYTHON_MODULE:-app}"]
