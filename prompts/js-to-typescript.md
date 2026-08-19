# Convert JavaScript to TypeScript

Migrate a JavaScript project to TypeScript with strict type checking.

---

## Context

This prompt converts JavaScript projects to TypeScript incrementally, ensuring the project remains functional throughout the migration.

---

## Prerequisites

- Node.js project with JavaScript files
- Working test suite (recommended)
- Version control (ability to rollback)

---

## Prompt

```
I want to convert this JavaScript project to TypeScript with strict type checking.

## Analysis Phase

First, analyze the project:

1. **Project structure:**
   - Identify all `.js` files to convert
   - Check for existing type definitions (`@types/*` packages)
   - Identify the build system (webpack, vite, esbuild, etc.)
   - Check for existing JSDoc comments (can inform types)

2. **Dependencies:**
   - List all dependencies
   - Check which have TypeScript support or `@types/*` packages
   - Identify any that will need custom type definitions

3. **Complexity assessment:**
   - Files with heavy dynamic typing
   - Files using `this` in complex ways
   - Files with circular dependencies

## TypeScript Configuration

Create `tsconfig.json` with strict settings:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "strictFunctionTypes": true,
    "strictBindCallApply": true,
    "strictPropertyInitialization": true,
    "noImplicitThis": true,
    "alwaysStrict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

## Migration Strategy

Use incremental migration - don't convert everything at once:

### Phase 1: Setup (keep .js files working)

1. Add TypeScript and type dependencies:
   ```bash
   docker compose run --rm app npm install -D typescript @types/node
   ```

2. Create `tsconfig.json` with `allowJs: true` initially

3. Add `@types/*` packages for all dependencies that need them

4. Verify project still builds and tests pass

### Phase 2: Convert Core Types First

1. Create `src/types/` directory for shared types
2. Define interfaces for:
   - API request/response shapes
   - Database models
   - Configuration objects
   - Domain entities

### Phase 3: Convert Files (leaf nodes first)

Convert in this order:
1. Utility functions (no dependencies on other project files)
2. Type definitions and constants
3. Data layer (models, repositories)
4. Service layer
5. API/route handlers
6. Entry points

For each file:
1. Rename `.js` to `.ts`
2. Add type annotations to function parameters
3. Add return types to functions
4. Fix any type errors
5. Run tests to verify behavior unchanged

### Phase 4: Strict Mode

1. Remove `allowJs: true` from tsconfig
2. Enable all strict options
3. Fix remaining type errors
4. Add explicit types where `any` was inferred

## Type Patterns

### Function parameters and returns
```typescript
// Before (JS)
function processUser(user) {
  return { ...user, processed: true };
}

// After (TS)
interface User {
  id: string;
  name: string;
  email: string;
}

interface ProcessedUser extends User {
  processed: boolean;
}

function processUser(user: User): ProcessedUser {
  return { ...user, processed: true };
}
```

### API responses
```typescript
// Define response types
interface ApiResponse<T> {
  data: T;
  status: number;
  message?: string;
}

interface PaginatedResponse<T> extends ApiResponse<T[]> {
  page: number;
  totalPages: number;
  totalItems: number;
}
```

### Handling unknown data
```typescript
// Use type guards for runtime validation
function isUser(value: unknown): value is User {
  return (
    typeof value === 'object' &&
    value !== null &&
    'id' in value &&
    'name' in value
  );
}
```

## Validation

After each phase:
- All tests pass
- No TypeScript errors (`npx tsc --noEmit`)
- Application runs correctly
- CI pipeline passes

## Files to Update

- `package.json` - Add TypeScript scripts
- `.gitignore` - Add `dist/`
- `Dockerfile` - Update build commands
- CI config - Add typecheck step
- `Makefile` - Add `typecheck` target

Now analyze this project and begin the TypeScript migration.
```

---

## Rollback

If migration causes issues:
1. Revert renamed files: `git checkout -- "*.ts"`
2. Remove TypeScript dependencies
3. Remove `tsconfig.json`
