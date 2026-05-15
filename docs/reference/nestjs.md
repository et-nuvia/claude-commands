# NestJS Framework Guide

## Overview

NestJS backend framework with TypeScript, Prisma ORM, and enterprise patterns.

---

## Default Stack

| Component | Tool | Version |
|-----------|------|---------|
| Runtime | Node.js | 24 LTS |
| Framework | NestJS | Latest |
| ORM | Prisma | Latest |
| Validation | class-validator | Latest |
| Testing | Jest | Latest |

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
  format_command: "npm run format"
  typecheck_command: "npx tsc --noEmit"
```

---

## Project Structure

```
backend/
├── src/
│   ├── main.ts                  # Bootstrap
│   ├── app.module.ts            # Root module
│   ├── config/
│   │   ├── config.module.ts
│   │   └── secrets.service.ts   # Secret fetching
│   ├── database/
│   │   ├── database.module.ts
│   │   └── prisma.service.ts
│   ├── users/                   # Feature module
│   │   ├── users.module.ts
│   │   ├── users.controller.ts
│   │   ├── users.service.ts
│   │   └── dto/
│   └── common/
│       ├── guards/
│       ├── interceptors/
│       └── filters/
├── prisma/
│   ├── schema.prisma
│   └── migrations/
├── test/
├── package.json
├── tsconfig.json
└── Dockerfile
```

---

## Secrets Service

```typescript
// src/config/secrets.service.ts
import { Injectable, OnModuleInit } from '@nestjs/common';
import { readFileSync, existsSync } from 'fs';
import { parse } from 'yaml';
import { platform } from 'os';

interface ProjectConfig {
  name: string;
  secrets?: {
    backend?: 'aws' | 'infisical';
    refresh?: { enabled?: boolean; interval_seconds?: number };
  };
}

@Injectable()
export class SecretsService implements OnModuleInit {
  private config: ProjectConfig;
  private cache = new Map<string, Record<string, string>>();
  private backend: 'aws' | 'infisical';

  onModuleInit() {
    if (!existsSync('PROJECT.yaml')) {
      throw new Error('PROJECT.yaml not found');
    }
    this.config = parse(readFileSync('PROJECT.yaml', 'utf-8'));
    this.backend = this.config.secrets?.backend
      ?? (platform() === 'darwin' ? 'aws' : 'infisical');
  }

  async getSecretBucket(bucket: string): Promise<Record<string, string>> {
    if (this.cache.has(bucket)) {
      return this.cache.get(bucket)!;
    }

    const env = process.env.ENVIRONMENT!;
    const app = this.config.name;

    const secrets = this.backend === 'aws'
      ? await this.fetchFromAws(`${app}/${env}/${bucket}`)
      : await this.fetchFromInfisical(app, env, bucket);

    this.cache.set(bucket, secrets);
    return secrets;
  }

  clearCache() {
    this.cache.clear();
  }

  private async fetchFromAws(secretId: string): Promise<Record<string, string>> {
    const { SecretsManagerClient, GetSecretValueCommand } = await import(
      '@aws-sdk/client-secrets-manager'
    );
    const client = new SecretsManagerClient({ region: process.env.REGION });
    const response = await client.send(new GetSecretValueCommand({ SecretId: secretId }));
    return JSON.parse(response.SecretString!);
  }

  private async fetchFromInfisical(app: string, env: string, bucket: string): Promise<Record<string, string>> {
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
}
```

---

## Secret Refresh (Scheduled Task)

```typescript
// src/config/secret-refresh.service.ts
import { Injectable } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { SecretsService } from './secrets.service';

@Injectable()
export class SecretRefreshService {
  constructor(private secrets: SecretsService) {}

  @Cron(CronExpression.EVERY_5_MINUTES)
  handleSecretRefresh() {
    console.log('Refreshing secret cache...');
    this.secrets.clearCache();
  }
}
```

---

## Prisma Configuration

```prisma
// prisma/schema.prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id        Int      @id @default(autoincrement())
  email     String   @unique
  name      String?
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt
}
```

```typescript
// src/database/prisma.service.ts
import { Injectable, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';
import { SecretsService } from '../config/secrets.service';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  constructor(private secrets: SecretsService) {
    super();
  }

  async onModuleInit() {
    // Get app user credentials
    const db = await this.secrets.getSecretBucket('database');
    const url = `postgresql://${db.app_username}:${db.app_password}@${db.host}:${db.port}/${db.database}`;

    // Reconnect with proper credentials
    this.$connect();
  }

  async onModuleDestroy() {
    await this.$disconnect();
  }
}
```

---

## Migration Commands

```bash
# Create migration
npx prisma migrate dev --name add_users_table

# Apply migrations (production)
npx prisma migrate deploy

# Generate client
npx prisma generate

# Reset database (development only)
npx prisma migrate reset
```

For migrations, set `DATABASE_URL` to migration user credentials.

---

## Dockerfile

```dockerfile
FROM node:24-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
RUN npx prisma generate

FROM node:24-alpine

WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/prisma ./prisma
COPY package*.json ./

RUN adduser -D appuser && chown -R appuser:appuser /app
USER appuser

ARG RUN_TESTS=false
RUN if [ "$RUN_TESTS" = "true" ]; then npm test; fi

CMD ["node", "dist/main"]
```

---

## Commands

```bash
# Development
npm run start:dev

# Testing
npm test
npm run test:cov
npm run test:e2e

# Linting
npm run lint
npm run format

# Build
npm run build

# Migrations
npx prisma migrate dev --name description
npx prisma migrate deploy
```
