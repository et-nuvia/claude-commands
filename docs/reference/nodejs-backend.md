# Node.js Backend Framework Guide

## Overview

Node.js backend with Express/Fastify, TypeScript, and modern tooling.

---

## Default Stack

| Component | Tool | Version |
|-----------|------|---------|
| Runtime | Node.js | 24 LTS |
| Framework | Express or Fastify | Latest |
| ORM | Knex + Objection.js | Latest |
| Validation | Zod | Latest |
| Testing | Vitest | Latest |

---

## PROJECT.yaml Configuration

```yaml
languages:
  - name: typescript
    version: "5.0"
    root: "backend"

testing:
  command: "npm test"
  coverage_command: "npm run test:cov"
  min_coverage: 80

quality:
  lint_command: "npm run lint"
  format_command: "npx prettier --write ."
  typecheck_command: "npx tsc --noEmit"
```

---

## Project Structure

```
backend/
├── src/
│   ├── index.ts                # Entry point
│   ├── app.ts                  # Express/Fastify app
│   ├── config/
│   │   ├── index.ts
│   │   └── secrets.ts          # Secret fetching
│   ├── database/
│   │   ├── knex.ts             # Knex instance
│   │   └── migrations/
│   ├── routes/
│   │   └── users.ts
│   ├── services/
│   │   └── userService.ts
│   ├── middleware/
│   └── types/
├── tests/
├── knexfile.ts
├── package.json
├── tsconfig.json
└── Dockerfile
```

---

## Secrets Module

```typescript
// src/config/secrets.ts
import { readFileSync, existsSync } from 'fs';
import { parse } from 'yaml';
import { platform } from 'os';
import cron from 'node-cron';

interface ProjectConfig {
  name: string;
  secrets?: {
    backend?: 'aws' | 'infisical';
    refresh?: { enabled?: boolean; interval_seconds?: number };
  };
}

let config: ProjectConfig;
const secretCache = new Map<string, Record<string, string>>();

function loadConfig(): ProjectConfig {
  if (!existsSync('PROJECT.yaml')) {
    throw new Error('PROJECT.yaml not found');
  }
  return parse(readFileSync('PROJECT.yaml', 'utf-8'));
}

function getSecretsBackend(): 'aws' | 'infisical' {
  if (!config) config = loadConfig();
  if (config.secrets?.backend) return config.secrets.backend;
  return platform() === 'darwin' ? 'aws' : 'infisical';
}

export async function getSecretBucket(bucket: string): Promise<Record<string, string>> {
  if (secretCache.has(bucket)) {
    return secretCache.get(bucket)!;
  }

  if (!config) config = loadConfig();
  const app = config.name;
  const env = process.env.ENVIRONMENT!;
  const backend = getSecretsBackend();

  let secrets: Record<string, string>;
  if (backend === 'aws') {
    secrets = await fetchFromAws(`${app}/${env}/${bucket}`);
  } else {
    secrets = await fetchFromInfisical(app, env, bucket);
  }

  secretCache.set(bucket, secrets);
  return secrets;
}

async function fetchFromAws(secretId: string): Promise<Record<string, string>> {
  const { SecretsManagerClient, GetSecretValueCommand } = await import(
    '@aws-sdk/client-secrets-manager'
  );
  const client = new SecretsManagerClient({ region: process.env.REGION });
  const response = await client.send(new GetSecretValueCommand({ SecretId: secretId }));
  return JSON.parse(response.SecretString!);
}

async function fetchFromInfisical(
  app: string,
  env: string,
  bucket: string
): Promise<Record<string, string>> {
  const { InfisicalClient } = await import('@infisical/sdk');
  const client = new InfisicalClient({
    clientId: process.env.INFISICAL_CLIENT_ID,
    clientSecret: process.env.INFISICAL_SECRET!,
    siteUrl: 'https://secrets.example.com',
  });
  const secret = await client.getSecret({
    projectId: process.env.INFISICAL_PROJECT_ID!,
    environment: env,
    path: `/${app}/${bucket}`,
    secretName: 'DATA',
  });
  return JSON.parse(secret.secretValue);
}

export function initSecretRefresh(): void {
  config = loadConfig();
  const refreshConfig = config.secrets?.refresh;

  if (!refreshConfig?.enabled) {
    console.log('Secret refresh disabled');
    return;
  }

  const intervalSec = refreshConfig.interval_seconds || 300;
  const cronExpr = `*/${Math.ceil(intervalSec / 60)} * * * *`;

  cron.schedule(cronExpr, () => {
    console.log(`[${new Date().toISOString()}] Clearing secret cache...`);
    secretCache.clear();
  });

  console.log(`Secret refresh scheduled every ${intervalSec} seconds`);
}
```

---

## Database Configuration (Knex)

```typescript
// src/database/knex.ts
import Knex from 'knex';
import { getSecretBucket } from '../config/secrets';

let knexInstance: Knex.Knex | null = null;

export async function getKnex(userType: 'app' | 'migration' = 'app'): Promise<Knex.Knex> {
  const db = await getSecretBucket('database');

  const username = userType === 'migration' ? db.migration_username : db.app_username;
  const password = userType === 'migration' ? db.migration_password : db.app_password;

  return Knex({
    client: 'pg',
    connection: {
      host: db.host,
      port: parseInt(db.port),
      user: username,
      password: password,
      database: db.database,
    },
    pool: { min: 2, max: 10 },
  });
}

export async function initDatabase(): Promise<void> {
  knexInstance = await getKnex('app');
}

export function db(): Knex.Knex {
  if (!knexInstance) {
    throw new Error('Database not initialized. Call initDatabase() first.');
  }
  return knexInstance;
}
```

---

## Express App

```typescript
// src/app.ts
import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import { usersRouter } from './routes/users';
import { errorHandler } from './middleware/errorHandler';

const app = express();

app.use(helmet());
app.use(cors());
app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.use('/api/users', usersRouter);

app.use(errorHandler);

export { app };
```

---

## Entry Point

```typescript
// src/index.ts
import { app } from './app';
import { initDatabase } from './database/knex';
import { initSecretRefresh } from './config/secrets';

const PORT = process.env.PORT || 3000;

async function main() {
  // Initialize secret refresh
  initSecretRefresh();

  // Initialize database
  await initDatabase();

  // Start server
  app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
  });
}

main().catch(console.error);
```

---

## Migration Commands (Knex)

```bash
# Create migration
npx knex migrate:make add_users_table

# Run migrations
npx knex migrate:latest

# Rollback
npx knex migrate:rollback

# Run specific migration
npx knex migrate:up 20240101000000_add_users_table.js
```

**knexfile.ts:**
```typescript
import type { Knex } from 'knex';

const config: { [key: string]: Knex.Config } = {
  development: {
    client: 'pg',
    connection: {
      host: process.env.DB_HOST,
      port: parseInt(process.env.DB_PORT || '5432'),
      user: process.env.DB_MIGRATION_USER,  // Migration user
      password: process.env.DB_MIGRATION_PASS,
      database: process.env.DB_NAME,
    },
    migrations: {
      directory: './src/database/migrations',
    },
  },
};

export default config;
```

---

## Dockerfile

```dockerfile
FROM node:24-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:24-alpine

WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./

RUN adduser -D appuser && chown -R appuser:appuser /app
USER appuser

ARG RUN_TESTS=false
RUN if [ "$RUN_TESTS" = "true" ]; then npm test; fi

EXPOSE 3000
CMD ["node", "dist/index.js"]
```

---

## Commands

```bash
# Development
npm run dev

# Build
npm run build

# Start production
npm start

# Testing
npm test
npm run test:cov

# Linting
npm run lint
npx prettier --check .

# Migrations
npx knex migrate:latest
npx knex migrate:rollback
```

---

## Code Examples

Implementation templates in [docs/code/](../code/):

- [Node.js Backend + AWS Secrets Manager](../code/typescript/nodejs-backend/secrets-aws.md)
- [Node.js Backend + Infisical](../code/typescript/nodejs-backend/secrets-infisical.md)
- [Node.js Backend Health Endpoints](../code/typescript/nodejs-backend/health-endpoints.md)
