# syntax=docker/dockerfile:1
# Generic DHI (Docker Hardened Images) Multi-Stage Dockerfile
#
# This template provides a production-ready Docker build using DHI base images.
# Suitable for Go, Rust, C/C++, or any compiled application.
#
# DHI images are non-root by default — no manual user creation needed.
#
# Variables:
#   TEST_DIR      - Directory containing tests (default: tests)
#   TEST_COMMAND  - Command to run tests (default: make test)
#   MIN_COVERAGE  - Minimum test coverage percentage (default: 80)
#   BUILD_COMMAND - Command to build the app (default: make build)
#   BINARY_NAME   - Name of the output binary (default: application)
#
# Customization points:
#   - Builder base: Change to language-specific DHI image if available
#   - Build command: Modify for your build system (make, cargo, go build, etc.)
#   - Runtime base: Use dhi.io/static for pure static binaries (no libc needed)
#   - Entry point: Set application entry point
#
# Base images:
#   - Build: dhi.io/debian:bookworm-dev (has shell, apt, build tools)
#   - Runtime: dhi.io/debian:bookworm (no shell, non-root by default)
#   - Static alt: dhi.io/static (for fully static binaries — smallest possible image)

# ---------------------------------------------------------------------------
# Stage 1: Builder — compile the application
# ---------------------------------------------------------------------------
FROM dhi.io/debian:bookworm-dev AS builder

WORKDIR /app

# Install build dependencies
# Customization: Add language-specific toolchains and libraries
# Examples:
#   - Go: RUN apt-get update && apt-get install -y golang && rm -rf /var/lib/apt/lists/*
#   - Rust: RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
#   - C/C++: Already available in -dev image (gcc, make, cmake)
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy source code
# Customization: Add additional files needed for build
COPY . .

# Build the application
# Customization: Change build command for your project
# Examples:
#   - Go: go build -ldflags="-s -w" -o /app/bin/application ./cmd/server
#   - Rust: cargo build --release && cp target/release/myapp /app/bin/application
#   - Make: make build
RUN ${BUILD_COMMAND:-make build}

# ---------------------------------------------------------------------------
# Stage 2: Testing (conditional — activated in CI with --build-arg RUN_TESTS=true)
# ---------------------------------------------------------------------------
FROM builder AS testing

ARG RUN_TESTS=false

# Run tests if enabled (typically in CI/CD)
# Customization: Modify test command for your project
# Examples:
#   - Go: go test -v -cover -coverprofile=coverage.out ./...
#   - Rust: cargo test
#   - Make: make test
RUN if [ "$RUN_TESTS" = "true" ]; then \
      ${TEST_COMMAND:-make test}; \
    fi

# ---------------------------------------------------------------------------
# Stage 3: Development — identical base to production for dev/prod parity
# ---------------------------------------------------------------------------
FROM dhi.io/debian:bookworm AS development

# OCI labels
ARG VERSION=dev
ARG CREATED
ARG REVISION
LABEL org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}"

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/bin/${BINARY_NAME:-application} /app/bin/${BINARY_NAME:-application}

# Customization: Copy additional runtime files (configs, templates, migrations, etc.)
# Example: COPY --from=builder /app/migrations /app/migrations

# Development may override entrypoint via docker-compose command
ENTRYPOINT ["/app/bin/${BINARY_NAME:-application}"]

# ---------------------------------------------------------------------------
# Stage 4: Production — minimal runtime image (default target)
# ---------------------------------------------------------------------------
# Option A: dhi.io/debian:bookworm — for dynamically linked binaries
# Option B: dhi.io/static — for fully static binaries (smallest image, no libc)
# Uncomment the appropriate FROM line:
FROM dhi.io/debian:bookworm AS production
# FROM dhi.io/static AS production

# OCI labels
ARG VERSION
ARG CREATED
ARG REVISION
LABEL org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}"

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/bin/${BINARY_NAME:-application} /app/bin/${BINARY_NAME:-application}

# Customization: Copy additional runtime files (configs, templates, migrations, etc.)
# Example: COPY --from=builder /app/migrations /app/migrations

# Health check
# Customization: Change endpoint/port to match your application
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/app/bin/${BINARY_NAME:-application}", "healthcheck"]

# Customization: Set your application's entry point
# Example: ENTRYPOINT ["/app/bin/myapp", "--config", "/app/config.yaml"]
ENTRYPOINT ["/app/bin/${BINARY_NAME:-application}"]
