# Multi-Language Implementation Guide

Standard pattern for implementing multi-language support in web applications with database-driven translations.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Frontend (React)                          │
│  ┌─────────────┐    ┌──────────────┐    ┌───────────────────┐  │
│  │   i18next   │───▶│ /locales/... │◀───│ Generated JSON    │  │
│  │   Backend   │    │ (static)     │    │ Files             │  │
│  └─────────────┘    └──────────────┘    └───────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Served by Express
                              │
┌─────────────────────────────────────────────────────────────────┐
│                        Backend (Node/Express)                    │
│  ┌─────────────────┐    ┌──────────────────┐                   │
│  │ Admin API       │───▶│ Regenerate JSON  │                   │
│  │ /api/admin/     │    │ Files on Change  │                   │
│  │ translations    │    └──────────────────┘                   │
│  └─────────────────┘              │                             │
│          │                        ▼                             │
│          │              ┌──────────────────┐                   │
│          └─────────────▶│ Translations DB  │                   │
│                         │ (MySQL)          │                   │
│  ┌─────────────────┐    └──────────────────┘                   │
│  │ Startup Check   │              │                             │
│  │ ensureTranslat- │──────────────┘                             │
│  │ ionFiles()      │    Regenerate if missing                   │
│  └─────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Docker Volume                                │
│                     /app/dist/locales/                          │
│                     (persists across restarts)                  │
└─────────────────────────────────────────────────────────────────┘
```

## Key Principles

1. **Database is source of truth** - All translations stored in MySQL
2. **JSON files are generated** - Never committed to git, regenerated from DB
3. **Startup validation** - Check for missing files, regenerate if needed
4. **Volume persistence** - Generated files persist across container restarts
5. **Admin API** - CRUD operations with audit logging
6. **Protected terms** - Medication names, brand names not translated

---

## Database Schema

### Translations Table

```sql
CREATE TABLE translations (
  id VARCHAR(36) PRIMARY KEY,
  namespace VARCHAR(50) NOT NULL,        -- e.g., 'common', 'patient', 'hipaa'
  key_path VARCHAR(255) NOT NULL,        -- e.g., 'buttons.submit', 'labels.name'
  language_code VARCHAR(10) NOT NULL,    -- e.g., 'en', 'es'
  translated_text TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY unique_translation (namespace, key_path, language_code)
);

CREATE INDEX idx_translations_namespace ON translations(namespace);
CREATE INDEX idx_translations_language ON translations(language_code);
```

### Translation Audit Table

```sql
CREATE TABLE translation_audit (
  id VARCHAR(36) PRIMARY KEY,
  translation_id VARCHAR(36) NOT NULL,
  change_type ENUM('create', 'update', 'delete', 'regenerate') NOT NULL,
  old_value TEXT,
  new_value TEXT,
  changed_by VARCHAR(100) NOT NULL,
  changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_audit_translation ON translation_audit(translation_id);
CREATE INDEX idx_audit_changed_at ON translation_audit(changed_at);
```

### Protected Medications Table (Optional)

For medical applications where medication names should not be translated:

```sql
CREATE TABLE protected_medications (
  id VARCHAR(36) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  name_normalized VARCHAR(255) NOT NULL,  -- lowercase for matching
  category VARCHAR(100),
  brand_name VARCHAR(255),
  generic_name VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY unique_medication (name_normalized)
);
```

---

## API Endpoints

### Public Endpoints

#### GET /locales/{lang}/{namespace}.json

Serves static translation files. Handled by Express static middleware.

**Response:** JSON translation object

```json
{
  "buttons": {
    "submit": "Submit",
    "cancel": "Cancel"
  },
  "labels": {
    "name": "Name",
    "email": "Email"
  }
}
```

---

### Admin Endpoints

All admin endpoints require authentication via:
- `X-API-Key` header with valid admin API key, OR
- Request from private IP (VPN access)

#### GET /api/admin/translations

List translations with filtering and pagination.

**Query Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| namespace | string | Filter by namespace |
| language | string | Filter by language code |
| search | string | Search in key_path and translated_text |
| limit | number | Results per page (default: 100) |
| offset | number | Pagination offset (default: 0) |

**Response:**
```json
{
  "translations": [
    {
      "id": "uuid",
      "namespace": "common",
      "key_path": "buttons.submit",
      "language_code": "en",
      "translated_text": "Submit",
      "created_at": "2024-01-01T00:00:00Z",
      "updated_at": "2024-01-01T00:00:00Z"
    }
  ],
  "total": 150,
  "limit": 100,
  "offset": 0
}
```

---

#### GET /api/admin/translations/:id

Get a single translation by ID.

**Response:**
```json
{
  "id": "uuid",
  "namespace": "common",
  "key_path": "buttons.submit",
  "language_code": "en",
  "translated_text": "Submit",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-01-01T00:00:00Z"
}
```

---

#### POST /api/admin/translations

Create a new translation. Automatically regenerates JSON files.

**Request Body:**
```json
{
  "namespace": "common",
  "key_path": "buttons.submit",
  "language_code": "es",
  "translated_text": "Enviar"
}
```

**Headers:**
- `X-Admin-User`: Username for audit logging (optional)

**Response:** `201 Created`
```json
{
  "id": "uuid",
  "message": "Translation created"
}
```

**Errors:**
- `400` - Missing required fields
- `409` - Translation already exists (duplicate key)

---

#### PUT /api/admin/translations/:id

Update an existing translation. Automatically regenerates JSON files.

**Request Body:**
```json
{
  "translated_text": "Enviar formulario"
}
```

**Headers:**
- `X-Admin-User`: Username for audit logging (optional)

**Response:**
```json
{
  "message": "Translation updated"
}
```

**Errors:**
- `400` - Missing translated_text
- `404` - Translation not found

---

#### DELETE /api/admin/translations/:id

Delete a translation. Automatically regenerates JSON files.

**Headers:**
- `X-Admin-User`: Username for audit logging (optional)

**Response:**
```json
{
  "message": "Translation deleted"
}
```

**Errors:**
- `404` - Translation not found

---

#### GET /api/admin/translations/namespaces

List all unique namespaces.

**Response:**
```json
{
  "namespaces": ["common", "patient", "hipaa", "validation"]
}
```

---

#### POST /api/admin/translations/regenerate

Force regeneration of all JSON files from database.

**Response:**
```json
{
  "success": true,
  "filesWritten": ["en/common.json", "es/common.json", ...],
  "count": 1250
}
```

---

#### POST /api/admin/translations/import

Bulk import translations from JSON.

**Request Body:**
```json
{
  "translations": [
    {
      "namespace": "common",
      "key_path": "buttons.submit",
      "language_code": "en",
      "translated_text": "Submit"
    },
    {
      "namespace": "common",
      "key_path": "buttons.submit",
      "language_code": "es",
      "translated_text": "Enviar"
    }
  ],
  "mode": "upsert"  // "upsert" or "insert_only"
}
```

**Response:**
```json
{
  "imported": 2,
  "skipped": 0,
  "errors": []
}
```

---

## File Structure

```
project/
├── public/
│   └── locales/           # Development (gitignored)
│       ├── en/
│       │   ├── common.json
│       │   ├── patient.json
│       │   └── ...
│       └── es/
│           └── ...
├── dist/
│   └── locales/           # Production (volume mounted)
│       └── ...
├── server/
│   ├── config/
│   │   └── translationsDb.js
│   ├── routes/
│   │   └── admin/
│   │       └── translations.js
│   └── services/
│       └── translationService.js
├── src/
│   ├── i18n.ts
│   └── utils/
│       └── pdfTranslations.ts  # If generating PDFs
├── scripts/
│   ├── seed-translations.js
│   └── import-translations.js
└── docker-compose.yml
```

---

## Implementation Files

### 1. Database Connection (server/config/translationsDb.js)

```javascript
import mysql from 'mysql2/promise';
import { getSecret } from './secrets.manager.js';

let pool = null;

export async function initTranslationsDb() {
  const dbConfig = await getSecret('database/translations');

  pool = mysql.createPool({
    host: dbConfig.host,
    user: dbConfig.user,
    password: dbConfig.password,
    database: dbConfig.database,
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
  });

  // Test connection
  const conn = await pool.getConnection();
  conn.release();

  return pool;
}

export async function getTranslationsConnection() {
  if (!pool) {
    await initTranslationsDb();
  }
  return pool.getConnection();
}

export function getTranslationsPool() {
  return pool;
}
```

### 2. Frontend i18n Config (src/i18n.ts)

```typescript
import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import LanguageDetector from 'i18next-browser-languagedetector';
import Backend from 'i18next-http-backend';

export const supportedLanguages = ['en', 'es'] as const;
export type SupportedLanguage = (typeof supportedLanguages)[number];

export const namespaces = [
  'common',
  'patient',
  'hipaa',
  'validation',
  // Add more as needed
] as const;

i18n
  .use(Backend)
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    fallbackLng: 'en',
    supportedLngs: [...supportedLanguages],
    ns: [...namespaces],
    defaultNS: 'common',

    detection: {
      order: ['querystring', 'localStorage', 'navigator'],
      lookupQuerystring: 'lang',
      lookupLocalStorage: 'app-language',
      caches: ['localStorage'],
    },

    backend: {
      loadPath: '/locales/{{lng}}/{{ns}}.json',
    },

    interpolation: {
      escapeValue: false,
    },

    react: {
      useSuspense: true,
    },
  });

export default i18n;
```

### 3. Startup Check (in server/index.js)

```javascript
// Ensure translation JSON files exist (regenerate from database if missing)
try {
  const { ensureTranslationFiles } = await import('./routes/admin/translations.js');
  const result = await ensureTranslationFiles();
  if (result.regenerated) {
    log.info('Translation files were regenerated from database');
  } else if (result.error) {
    log.error({ error: result.error }, 'Failed to regenerate translation files - translations will not work');
  }
} catch (error) {
  log.error({ error: error.message }, 'Translation files check failed - translations will not work');
}
```

### 4. LOCALES_DIR Path (server/routes/admin/translations.js)

```javascript
// Path to locales directory (dist in production, public in development)
const LOCALES_DIR = process.env.NODE_ENV === 'production'
  ? path.join(__dirname, '../../../dist/locales')
  : path.join(__dirname, '../../../public/locales');
```

---

## Docker Configuration

### docker-compose.yml

```yaml
volumes:
  app_locales_data:

services:
  app:
    # ... other config ...
    volumes:
      - app_locales_data:/app/dist/locales
```

### .gitignore

```gitignore
# Generated translation files (regenerated from database)
public/locales/**/*.json
dist/locales/
```

---

## Seeding Translations

### Initial Seed Script (scripts/seed-translations.js)

```javascript
#!/usr/bin/env node

import fs from 'fs/promises';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import { initTranslationsDb, getTranslationsConnection } from '../server/config/translationsDb.js';

const LOCALES_DIR = './seed-data/locales';
const SUPPORTED_LANGUAGES = ['en', 'es'];

async function seedTranslations() {
  await initTranslationsDb();
  const connection = await getTranslationsConnection();

  try {
    for (const lang of SUPPORTED_LANGUAGES) {
      const langDir = path.join(LOCALES_DIR, lang);
      const files = await fs.readdir(langDir);

      for (const file of files) {
        if (!file.endsWith('.json')) continue;

        const namespace = file.replace('.json', '');
        const content = JSON.parse(
          await fs.readFile(path.join(langDir, file), 'utf-8')
        );

        const flattenedKeys = flattenObject(content);

        for (const [keyPath, text] of Object.entries(flattenedKeys)) {
          await connection.execute(
            `INSERT INTO translations (id, namespace, key_path, language_code, translated_text)
             VALUES (?, ?, ?, ?, ?)
             ON DUPLICATE KEY UPDATE translated_text = VALUES(translated_text)`,
            [uuidv4(), namespace, keyPath, lang, text]
          );
        }

        console.log(`Seeded ${namespace} for ${lang}`);
      }
    }

    console.log('Seeding complete');
  } finally {
    connection.release();
  }
}

function flattenObject(obj, prefix = '') {
  const result = {};
  for (const [key, value] of Object.entries(obj)) {
    const newKey = prefix ? `${prefix}.${key}` : key;
    if (typeof value === 'object' && value !== null) {
      Object.assign(result, flattenObject(value, newKey));
    } else {
      result[newKey] = value;
    }
  }
  return result;
}

seedTranslations().catch(console.error);
```

---

## Usage in Components

```tsx
import { useTranslation } from 'react-i18next';

function MyComponent() {
  const { t } = useTranslation('common');

  return (
    <div>
      <h1>{t('titles.welcome')}</h1>
      <button>{t('buttons.submit')}</button>
    </div>
  );
}
```

### With Multiple Namespaces

```tsx
const { t } = useTranslation(['common', 'patient']);

// Access different namespaces
t('common:buttons.submit')
t('patient:labels.firstName')
```

---

## Server-Side Translation (Optional)

For translating user-submitted free text (e.g., form submissions):

```javascript
import { translateFormData } from './services/translationService.js';

// In form submission handler
const formLanguage = formData.language || 'en';
if (formLanguage !== 'en') {
  const translatedData = await translateFormData(formData, formLanguage);
  translatedData._translationMeta = {
    originalLanguage: formLanguage,
    translatedAt: new Date().toISOString(),
  };
  // Save translatedData instead of formData
}
```

---

## Checklist for New Projects

- [ ] Create translations database and tables
- [ ] Add `translationsDb.js` config
- [ ] Add `translations.js` admin routes
- [ ] Configure `i18n.ts` for frontend
- [ ] Add volume mount in docker-compose.yml
- [ ] Add gitignore entries for locale files
- [ ] Create seed data in `seed-data/locales/{lang}/*.json`
- [ ] Run seed script to populate database
- [ ] Add startup check in server/index.js
- [ ] Test regeneration by deleting locale files and restarting
