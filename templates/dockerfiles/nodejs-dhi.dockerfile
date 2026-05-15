# syntax=docker/dockerfile:1
# Node.js/Next.js DHI (Docker Hardened Images) Multi-Stage Dockerfile
#
# This template provides a production-ready Docker build for Node.js/Next.js
# projects using DHI base images and npm for dependency management.
#
# DHI images are non-root by default — no manual user creation needed.
#
# Variables:
#   MIN_COVERAGE  - Minimum test coverage percentage (default: 80)
#   NODE_PORT     - Port to expose (default: 3000)
#   BUILD_CMD     - Build command (default: npm run build)
#   START_CMD     - Start command (default: node server.js)
#   NODE_VERSION  - Node.js version tag (default: 24)
#
# Customization points:
#   - Package manager: Change npm to yarn or pnpm if needed
#   - Build output: Modify COPY commands for different frameworks
#   - Environment variables: Add NODE_ENV, API_URL, etc.
#   - Static assets: Adjust paths for public/static files
#
# Base images:
#   - Build: dhi.io/node:<version>-debian13-dev (has shell, apt, build tools)
#   - Runtime: dhi.io/node:<version>-debian13 (no shell, non-root by default)

# ---------------------------------------------------------------------------
# Stage 1: Dependencies — install all packages
# ---------------------------------------------------------------------------
FROM dhi.io/node:24-debian13-dev AS deps

WORKDIR /app

# Copy dependency files first for better layer caching
# Customization: Add .npmrc, .yarnrc.yml, etc. if needed
COPY package.json package-lock.json ./

# Install all dependencies (including devDependencies for build)
# Customization: Change to 'yarn install --frozen-lockfile' or 'pnpm install --frozen-lockfile'
RUN --mount=type=cache,target=/root/.npm \
    npm ci

# ---------------------------------------------------------------------------
# Stage 2: Builder — build the application
# ---------------------------------------------------------------------------
FROM deps AS builder

WORKDIR /app

# Copy source code
# Customization: Add additional config files if needed
# Examples: tsconfig.json, next.config.js, vite.config.ts
COPY . .

# Build the application
# Customization: Change build command for your framework
# Examples:
#   - Next.js: npm run build
#   - Vite: npm run build
#   - Custom: npm run build:prod
RUN ${BUILD_CMD:-npm run build}

# ---------------------------------------------------------------------------
# Stage 3: Testing (conditional — activated in CI with --build-arg RUN_TESTS=true)
# ---------------------------------------------------------------------------
FROM deps AS testing

ARG RUN_TESTS=false

WORKDIR /app

# Copy source for tests
COPY . .

# Run tests if enabled (typically in CI/CD)
# Customization: Modify test command and coverage thresholds
# Examples:
#   - Jest: npm test -- --coverage --coverageThreshold='{"global":{"lines":80}}'
#   - Vitest: npm run test:coverage
RUN if [ "$RUN_TESTS" = "true" ]; then \
      npm test -- \
        --coverage \
        --coverageThreshold='{"global":{"lines":${MIN_COVERAGE:-80}}}'; \
    fi

# ---------------------------------------------------------------------------
# Stage 4: Production dependencies — install only what's needed at runtime
# ---------------------------------------------------------------------------
FROM dhi.io/node:24-debian13-dev AS prod-deps

WORKDIR /app

COPY package.json package-lock.json ./

# Install production dependencies only
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# ---------------------------------------------------------------------------
# Stage 5: Development — identical base to production for dev/prod parity
# ---------------------------------------------------------------------------
FROM dhi.io/node:24-debian13 AS development

# OCI labels
ARG VERSION=dev
ARG CREATED
ARG REVISION
LABEL org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}"

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=${NODE_PORT:-3000}

# Next.js standalone pattern:
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

# Alternative for other frameworks (uncomment as needed):
#   - Vite/React SPA: COPY --from=builder /app/dist ./dist
#   - Express/Fastify: COPY --from=builder /app/build ./build
#   - Remix: COPY --from=builder /app/build ./build
#              COPY --from=builder /app/public ./public

EXPOSE ${NODE_PORT:-3000}

# Development may override entrypoint via docker-compose command
CMD ["${START_CMD:-node server.js}"]

# ---------------------------------------------------------------------------
# Stage 6: Production — minimal runtime image (default target)
# ---------------------------------------------------------------------------
FROM dhi.io/node:24-debian13 AS production

# OCI labels
ARG VERSION
ARG CREATED
ARG REVISION
LABEL org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}"

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=${NODE_PORT:-3000}

# Next.js standalone pattern:
# When using Next.js standalone output, node_modules are bundled in .next/standalone
# so a separate COPY of node_modules is not needed.
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

# Alternative for other frameworks (uncomment as needed):
#   - Vite/React SPA (serve with static server):
#       COPY --from=builder /app/dist ./dist
#       CMD ["npx", "serve", "-s", "dist", "-l", "3000"]
#   - Express/Fastify:
#       COPY --from=prod-deps /app/node_modules ./node_modules
#       COPY --from=builder /app/build ./build
#   - Remix:
#       COPY --from=prod-deps /app/node_modules ./node_modules
#       COPY --from=builder /app/build ./build
#       COPY --from=builder /app/public ./public

EXPOSE ${NODE_PORT:-3000}

# Health check
# Customization: Change endpoint/port to match your application
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["node", "-e", "require('http').get('http://localhost:${PORT:-3000}/health', r => r.statusCode === 200 ? process.exit(0) : process.exit(1))"]

# Customization: Change command for your framework
# Examples:
#   - Next.js standalone: ["node", "server.js"]
#   - Express: ["node", "build/index.js"]
CMD ["${START_CMD:-node server.js}"]
