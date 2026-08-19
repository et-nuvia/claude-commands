# Convert CommonJS to ES Modules

Migrate Node.js project from CommonJS (require/module.exports) to ES Modules (import/export).

---

## Context

ES Modules are the standard for JavaScript modules. This prompt converts CommonJS projects to ESM for better tree-shaking, static analysis, and modern tooling support.

---

## Prerequisites

- Node.js 18+ (full ESM support)
- Understanding of the project's module structure
- Working test suite (recommended)

---

## Prompt

```
I want to convert this Node.js project from CommonJS to ES Modules.

## Analysis Phase

1. **Check current module system:**
   - Look for `"type": "module"` or `"type": "commonjs"` in package.json
   - Check file extensions (.js, .cjs, .mjs)
   - Identify require() and module.exports usage

2. **Identify conversion challenges:**
   - Dynamic requires: `require(variable)`
   - `__dirname` and `__filename` usage
   - `require.resolve()` usage
   - Circular dependencies
   - Dependencies that don't support ESM

3. **List all files to convert:**
   - Application code
   - Test files
   - Config files (may need to stay CJS)

## Conversion Steps

### Step 1: Update package.json

```json
{
  "type": "module",
  "engines": {
    "node": ">=18.0.0"
  }
}
```

### Step 2: Convert require/exports syntax

**Basic imports:**
```javascript
// Before (CJS)
const express = require('express');
const { Router } = require('express');
const config = require('./config');

// After (ESM)
import express, { Router } from 'express';
import config from './config.js';  // Note: .js extension required
```

**Named exports:**
```javascript
// Before (CJS)
module.exports = { foo, bar };
// or
exports.foo = foo;
exports.bar = bar;

// After (ESM)
export { foo, bar };
// or
export const foo = ...;
export const bar = ...;
```

**Default exports:**
```javascript
// Before (CJS)
module.exports = MyClass;

// After (ESM)
export default MyClass;
```

**Mixed exports:**
```javascript
// Before (CJS)
module.exports = main;
module.exports.helper = helper;

// After (ESM)
export default main;
export { helper };
```

### Step 3: Fix __dirname and __filename

```javascript
// Before (CJS)
const path = require('path');
const configPath = path.join(__dirname, 'config.json');

// After (ESM)
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const configPath = join(__dirname, 'config.json');
```

Or create a utility:
```javascript
// src/lib/paths.js
import { fileURLToPath } from 'url';
import { dirname } from 'path';

export function getDirname(importMetaUrl) {
  return dirname(fileURLToPath(importMetaUrl));
}

// Usage
import { getDirname } from './lib/paths.js';
const __dirname = getDirname(import.meta.url);
```

### Step 4: Fix dynamic imports

```javascript
// Before (CJS) - dynamic require
const module = require(modulePath);

// After (ESM) - dynamic import (returns Promise)
const module = await import(modulePath);
```

### Step 5: Fix require.resolve

```javascript
// Before (CJS)
const modulePath = require.resolve('some-package');

// After (ESM)
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const modulePath = require.resolve('some-package');
```

### Step 6: Handle JSON imports

```javascript
// Before (CJS)
const pkg = require('./package.json');

// After (ESM) - Option 1: Import assertion
import pkg from './package.json' assert { type: 'json' };

// After (ESM) - Option 2: Read file
import { readFileSync } from 'fs';
const pkg = JSON.parse(readFileSync('./package.json', 'utf-8'));

// After (ESM) - Option 3: createRequire
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const pkg = require('./package.json');
```

### Step 7: Update file extensions in imports

ESM requires explicit file extensions:

```javascript
// Before (CJS) - extension optional
const utils = require('./utils');
const config = require('./config/index');

// After (ESM) - extension required
import utils from './utils.js';
import config from './config/index.js';
```

### Step 8: Handle config files that must stay CJS

Some tools require CJS config files. Rename them:

```bash
# These often need to stay CJS
mv jest.config.js jest.config.cjs
mv .eslintrc.js .eslintrc.cjs
mv prettier.config.js prettier.config.cjs
```

### Step 9: Update test configuration

**Jest:**
```javascript
// jest.config.cjs
module.exports = {
  transform: {},
  moduleNameMapper: {
    '^(\\.{1,2}/.*)\\.js$': '$1',
  },
  testEnvironment: 'node',
};
```

**Or switch to Vitest (native ESM):**
```javascript
// vitest.config.js
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
  },
});
```

## Common Patterns

### Express app:
```javascript
// Before
const express = require('express');
const app = express();
module.exports = app;

// After
import express from 'express';
const app = express();
export default app;
```

### Fastify app:
```javascript
// Before
const fastify = require('fastify');

// After
import Fastify from 'fastify';
const fastify = Fastify({ logger: true });
```

### Class with static methods:
```javascript
// Before
class Service {
  static create() { return new Service(); }
}
module.exports = Service;

// After
export default class Service {
  static create() { return new Service(); }
}
```

## Validation

After conversion:
- `node --version` shows 18+
- `node src/index.js` runs without errors
- All tests pass
- No `require` statements remain (except in .cjs files)
- All imports have .js extensions

## Files to Update

- All `.js` files (convert syntax)
- `package.json` (add type: module)
- Config files (may need .cjs extension)
- Test files
- Documentation

Now analyze this project and convert from CommonJS to ES Modules.
```

---

## Rollback

If migration causes issues:
1. Remove `"type": "module"` from package.json
2. `git checkout -- "*.js"`
3. Rename any .cjs files back to .js
